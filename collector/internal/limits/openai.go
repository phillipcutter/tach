package limits

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"tach/collector/internal/acct"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
)

const openaiUsageURL = "https://chatgpt.com/backend-api/wham/usage"

// CodexAuth is what the collector reads from ~/.codex/auth.json. The token is
// kept unexported so it cannot end up in a JSON report by accident.
type CodexAuth struct {
	Mode      string
	AccountID string
	Plan      string    // chatgpt_plan_type from the id token claims, e.g. "pro"
	Expires   time.Time // access token expiry; zero when unknown
	token     string
}

// CodexHome honours CODEX_HOME.
func CodexHome(home string) string {
	if h := os.Getenv("CODEX_HOME"); h != "" {
		return h
	}
	return filepath.Join(home, ".codex")
}

// ReadCodexAuth reads auth.json. It never writes or refreshes it.
func ReadCodexAuth(home string) (*CodexAuth, error) {
	b, err := os.ReadFile(filepath.Join(CodexHome(home), "auth.json"))
	if err != nil {
		return nil, err
	}
	var f struct {
		AuthMode string `json:"auth_mode"`
		Tokens   *struct {
			AccessToken string `json:"access_token"`
			IDToken     string `json:"id_token"`
			AccountID   string `json:"account_id"`
		} `json:"tokens"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, errors.New("auth.json is not valid JSON")
	}
	a := &CodexAuth{Mode: f.AuthMode}
	if f.Tokens == nil {
		return a, nil
	}
	a.token, a.AccountID = f.Tokens.AccessToken, f.Tokens.AccountID
	if c := jwtClaims(f.Tokens.AccessToken); c != nil {
		if exp, ok := c["exp"].(float64); ok {
			a.Expires = time.Unix(int64(exp), 0)
		}
		a.Plan = authClaim(c, "chatgpt_plan_type")
		if a.AccountID == "" {
			a.AccountID = authClaim(c, "chatgpt_account_id")
		}
	}
	if a.Plan == "" {
		if c := jwtClaims(f.Tokens.IDToken); c != nil {
			a.Plan = authClaim(c, "chatgpt_plan_type")
		}
	}
	return a, nil
}

// HasToken reports whether an access token is present.
func (a *CodexAuth) HasToken() bool { return a != nil && a.token != "" }

// jwtClaims decodes a JWT payload without verifying it (only to read exp and
// plan locally; the server is the authority).
func jwtClaims(tok string) map[string]any {
	p := strings.Split(tok, ".")
	if len(p) != 3 {
		return nil
	}
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(p[1], "="))
	if err != nil {
		return nil
	}
	var c map[string]any
	if json.Unmarshal(b, &c) != nil {
		return nil
	}
	return c
}

func authClaim(c map[string]any, k string) string {
	if a, ok := c["https://api.openai.com/auth"].(map[string]any); ok {
		if s, ok := a[k].(string); ok {
			return s
		}
	}
	return ""
}

// OpenAIPlanName turns plan_type into a display name.
func OpenAIPlanName(pt string) string {
	switch strings.ToLower(pt) {
	case "":
		return ""
	case "pro":
		return "ChatGPT Pro"
	case "plus":
		return "ChatGPT Plus"
	case "team":
		return "ChatGPT Team"
	case "business":
		return "ChatGPT Business"
	case "enterprise":
		return "ChatGPT Enterprise"
	case "edu":
		return "ChatGPT Edu"
	case "free":
		return "ChatGPT Free"
	case "go":
		return "ChatGPT Go"
	}
	return "ChatGPT " + strings.ToUpper(pt[:1]) + pt[1:]
}

func pollOpenAI(ctx context.Context, e env.Env, out *event.Emitter) {
	const src = "limits/openai"
	a, err := ReadCodexAuth(e.Home)
	if err != nil {
		if os.IsNotExist(err) {
			out.Log("warn", src, "Codex is not signed in on this machine")
		} else {
			out.Log("warn", src, "cannot read Codex sign-in: "+err.Error())
		}
		return
	}
	if a.Mode != "" && a.Mode != "chatgpt" {
		out.Log("warn", src, "Codex uses an API key, not a ChatGPT plan: no plan limits")
		return
	}
	if !a.HasToken() {
		out.Log("warn", src, "Codex is not signed in on this machine")
		return
	}
	if !a.Expires.IsZero() && !a.Expires.After(e.Now) {
		out.Log("warn", src, "Codex sign-in on this machine has expired")
		return
	}
	req, _ := http.NewRequestWithContext(ctx, "GET", openaiUsageURL, nil)
	req.Header.Set("Authorization", "Bearer "+a.token)
	if a.AccountID != "" {
		req.Header.Set("ChatGPT-Account-Id", a.AccountID)
	}
	req.Header.Set("Accept", "application/json")
	body, err := do(officialClient, req)
	if err != nil {
		var he httpError
		if errors.As(err, &he) && (he.Code == 401 || he.Code == 403) {
			out.Log("warn", src, "Codex sign-in on this machine was rejected ("+he.Error()+")")
		} else {
			out.Log("warn", src, "usage endpoint failed: "+err.Error())
		}
		return
	}
	ls, err := mapOpenAI(body, a, e.Now.UnixMilli())
	if err != nil {
		out.Log("warn", src, "usage endpoint: "+err.Error())
		return
	}
	for _, l := range ls {
		out.Limit(l)
	}
	out.Log("info", src, fmt.Sprintf("answered by wham/usage endpoint (%d windows)", len(ls)))
}

type openaiWindow struct {
	UsedPercent        *float64 `json:"used_percent"`
	LimitWindowSeconds int64    `json:"limit_window_seconds"`
	ResetAfterSeconds  *int64   `json:"reset_after_seconds"`
	ResetAt            *int64   `json:"reset_at"`
}

type openaiRateLimit struct {
	Allowed         *bool         `json:"allowed"`
	LimitReached    bool          `json:"limit_reached"`
	PrimaryWindow   *openaiWindow `json:"primary_window"`
	SecondaryWindow *openaiWindow `json:"secondary_window"`
}

type openaiUsage struct {
	PlanType             string           `json:"plan_type"`
	AccountID            string           `json:"account_id"`
	RateLimit            *openaiRateLimit `json:"rate_limit"`
	CodeReviewRateLimit  json.RawMessage  `json:"code_review_rate_limit"`
	AdditionalRateLimits json.RawMessage  `json:"additional_rate_limits"`
	Credits              *struct {
		HasCredits bool            `json:"has_credits"`
		Unlimited  bool            `json:"unlimited"`
		Balance    json.RawMessage `json:"balance"`
	} `json:"credits"`
}

func mapOpenAI(body []byte, a *CodexAuth, now int64) ([]event.Limit, error) {
	var u openaiUsage
	if err := json.Unmarshal(body, &u); err != nil {
		return nil, errors.New("unexpected response shape")
	}
	id := a.AccountID
	if id == "" {
		id = u.AccountID
	}
	h := acct.Hash(id)
	pt := u.PlanType
	if pt == "" {
		pt = a.Plan
	}
	plan := OpenAIPlanName(pt)
	resets := func(w *openaiWindow) int64 {
		switch {
		case w.ResetAt != nil && *w.ResetAt > 0:
			return *w.ResetAt * 1000
		case w.ResetAfterSeconds != nil && *w.ResetAfterSeconds > 0:
			return now + *w.ResetAfterSeconds*1000
		}
		return 0
	}
	var out []event.Limit
	seen := map[string]bool{}
	if rl := u.RateLimit; rl != nil {
		for _, w := range []*openaiWindow{rl.PrimaryWindow, rl.SecondaryWindow} {
			if w == nil {
				continue
			}
			wid, kind, label := "weekly", "weekly", "Week"
			if w.LimitWindowSeconds > 0 && w.LimitWindowSeconds <= 6*3600 {
				wid, kind, label = "five_hour", "session", "5-hour"
			}
			if seen[wid] {
				wid = wid + ":" + strconv.FormatInt(w.LimitWindowSeconds, 10)
			}
			seen[wid] = true
			l := window("openai", h, plan, wid, kind, label, w.UsedPercent, resets(w), w.LimitWindowSeconds, now, "endpoint")
			out = append(out, l)
		}
		if rl.LimitReached || (rl.Allowed != nil && !*rl.Allowed) {
			// The response says the account is blocked; flag the fullest window.
			best := -1
			for i := range out {
				if best < 0 || *out[i].Used > *out[best].Used {
					best = i
				}
			}
			if best >= 0 {
				out[best].Limited = true
			}
		}
	}
	// Per-model / per-feature limits. The shape of additional_rate_limits was
	// null in every response seen so far, so accept a few plausible forms.
	extra := parseExtraOpenAI(u.AdditionalRateLimits)
	if len(u.CodeReviewRateLimit) > 0 && string(u.CodeReviewRateLimit) != "null" {
		var rl openaiRateLimit
		if json.Unmarshal(u.CodeReviewRateLimit, &rl) == nil {
			extra = append(extra, namedLimit{"Code review", rl})
		}
	}
	for _, x := range extra {
		w := x.rl.PrimaryWindow
		if s := x.rl.SecondaryWindow; s != nil && (w == nil || s.LimitWindowSeconds > w.LimitWindowSeconds) {
			w = s // the protocol has one weekly_scoped window per name: keep the longest
		}
		sl := slug(x.name)
		if w == nil || sl == "" || seen["weekly:"+sl] {
			continue
		}
		seen["weekly:"+sl] = true
		l := window("openai", h, plan, "weekly:"+sl, "weekly_scoped", x.name, w.UsedPercent, resets(w), w.LimitWindowSeconds, now, "endpoint")
		l.Limited = l.Limited || x.rl.LimitReached
		out = append(out, l)
	}
	if c := u.Credits; c != nil && (c.HasCredits || c.Unlimited) {
		l := event.Limit{Provider: "openai", Acct: h, Plan: plan, Window: "credits", Kind: "credits", Label: "Credits", TS: now, Src: "endpoint", Used: f64(0)}
		if bal, ok := numberish(c.Balance); ok && !c.Unlimited {
			l.Amount = f64(bal)
			l.Limited = bal <= 0
		}
		out = append(out, l)
	}
	return out, nil
}

type namedLimit struct {
	name string
	rl   openaiRateLimit
}

func parseExtraOpenAI(raw json.RawMessage) []namedLimit {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	nameOf := func(m map[string]json.RawMessage) string {
		for _, k := range []string{"display_name", "limit_name", "name", "model", "metered_feature", "feature", "id"} {
			var s string
			if v, ok := m[k]; ok && json.Unmarshal(v, &s) == nil && s != "" {
				return s
			}
		}
		return ""
	}
	one := func(name string, m map[string]json.RawMessage) (namedLimit, bool) {
		if n := nameOf(m); n != "" {
			name = n
		}
		var rl openaiRateLimit
		src := m["rate_limit"]
		if len(src) == 0 || string(src) == "null" {
			b, _ := json.Marshal(m)
			src = b
		}
		if json.Unmarshal(src, &rl) != nil || (rl.PrimaryWindow == nil && rl.SecondaryWindow == nil) || name == "" {
			return namedLimit{}, false
		}
		return namedLimit{name, rl}, true
	}
	var out []namedLimit
	var arr []map[string]json.RawMessage
	if json.Unmarshal(raw, &arr) == nil {
		for _, m := range arr {
			if x, ok := one("", m); ok {
				out = append(out, x)
			}
		}
		return out
	}
	var obj map[string]map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) == nil {
		keys := make([]string, 0, len(obj))
		for k := range obj {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if x, ok := one(k, obj[k]); ok {
				out = append(out, x)
			}
		}
	}
	return out
}

func numberish(raw json.RawMessage) (float64, bool) {
	var f float64
	if json.Unmarshal(raw, &f) == nil {
		return f, true
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		if v, err := strconv.ParseFloat(s, 64); err == nil {
			return v, true
		}
	}
	return 0, false
}
