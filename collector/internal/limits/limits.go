// Package limits polls each provider for the current state of its limit windows.
// Per provider it tries the sources in the order of design/data-sources.md 4.1
// and logs which one answered. It never refreshes or writes a credential and
// never logs a token.
package limits

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"tach/collector/internal/env"
	"tach/collector/internal/event"
)

const userAgent = "tach-collector"

// Poll emits limit events for the named providers ("claude", "openai", "gemini"); empty means all.
func Poll(ctx context.Context, e env.Env, providers []string, out *event.Emitter) error {
	if e.Now.IsZero() {
		e.Now = time.Now()
	}
	all := map[string]func(context.Context, env.Env, *event.Emitter){
		"claude": pollClaude,
		"openai": pollOpenAI,
		"gemini": pollGemini,
	}
	want := map[string]bool{}
	for _, p := range providers {
		p = strings.TrimSpace(p)
		switch p {
		case "":
			continue
		case "codex":
			p = "openai"
		case "antigravity":
			p = "gemini"
		case "claude_code", "anthropic":
			p = "claude"
		}
		if all[p] == nil {
			return fmt.Errorf("unknown provider %q (want claude, openai, gemini)", p)
		}
		want[p] = true
	}
	var wg sync.WaitGroup
	for name, f := range all {
		if len(want) > 0 && !want[name] {
			continue
		}
		wg.Add(1)
		go func(name string, f func(context.Context, env.Env, *event.Emitter)) {
			defer wg.Done()
			defer func() {
				if r := recover(); r != nil {
					out.Log("error", "limits/"+name, fmt.Sprint("panic: ", r))
				}
			}()
			f(ctx, e, out)
		}(name, f)
	}
	wg.Wait()
	return nil
}

// Window lengths in seconds.
const (
	lenFiveHour = 5 * 3600
	lenWeek     = 7 * 24 * 3600
)

// --- HTTP ---

var errStatus = errors.New("http status")

type httpError struct {
	Code int
}

func (h httpError) Error() string { return fmt.Sprintf("HTTP %d", h.Code) }
func (h httpError) Unwrap() error { return errStatus }

// officialClient refuses redirects, so a token is only ever sent to the host we
// called, and times out after 10 s.
var officialClient = &http.Client{
	Timeout: 10 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

// loopbackClient talks to Antigravity's language server on 127.0.0.1 only. Its
// HTTPS port uses a self-signed certificate, so verification is skipped; the
// dialer refuses anything but loopback.
var loopbackClient = &http.Client{
	Timeout: 5 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	},
	Transport: &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, _, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
				return nil, fmt.Errorf("refusing non-loopback address")
			}
			return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, network, addr)
		},
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // loopback only, self-signed
	},
}

func do(c *http.Client, req *http.Request) ([]byte, error) {
	req.Header.Set("User-Agent", userAgent)
	resp, err := c.Do(req)
	if err != nil {
		return nil, scrubErr(err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, scrubErr(err)
	}
	if resp.StatusCode != 200 {
		return b, httpError{resp.StatusCode}
	}
	return b, nil
}

// scrubErr keeps only the error's outer kind: url.Error messages include the
// URL, which never holds a token here, but be strict anyway.
func scrubErr(err error) error {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return errors.New("timed out")
	}
	s := err.Error()
	if i := strings.LastIndex(s, ": "); i >= 0 {
		s = s[i+2:]
	}
	return errors.New(s)
}

// --- helpers ---

func f64(v float64) *float64 { return &v }
func i64(v int64) *int64     { return &v }

func round2(v float64) float64 { return math.Round(v*100) / 100 }

func clampPct(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return round2(v)
}

func parseISO(s string) (int64, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, false
	}
	for _, l := range []string{time.RFC3339Nano, "2006-01-02T15:04:05.999999999-07:00", "2006-01-02 15:04:05.999999999-07:00"} {
		if t, err := time.Parse(l, s); err == nil {
			return t.UnixMilli(), true
		}
	}
	return 0, false
}

// slug makes a stable window id fragment from a display name: "Claude Opus" -> "claude_opus".
func slug(s string) string {
	var b strings.Builder
	us := false
	for _, r := range strings.ToLower(strings.TrimSpace(s)) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			us = false
		} else if !us && b.Len() > 0 {
			b.WriteByte('_')
			us = true
		}
	}
	return strings.TrimSuffix(b.String(), "_")
}

// window builds a limit reading, applying the protocol's not-started rule: no
// reset time and nothing used means used 0 and no resets.
func window(provider, acctHash, plan, id, kind, label string, used *float64, resets int64, length int64, ts int64, src string) event.Limit {
	l := event.Limit{
		Provider: provider, Acct: acctHash, Plan: plan, Window: id, Kind: kind, Label: label,
		Len: length, TS: ts, Src: src,
	}
	u := 0.0
	if used != nil {
		u = clampPct(*used)
	}
	l.Used = f64(u)
	if resets > 0 {
		l.Resets = i64(resets)
	}
	l.Limited = u >= 100
	return l
}
