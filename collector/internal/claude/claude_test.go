package claude

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"tach/collector/internal/cursor"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
	"tach/collector/internal/jsonl"
)

type outLine struct {
	K string `json:"k"`
	event.Req
	Window  string   `json:"window"`
	Used    *float64 `json:"used"`
	Resets  *int64   `json:"resets"`
	Limited bool     `json:"limited"`
	Src     string   `json:"src"`
	Level   string   `json:"level"`
	Msg     string   `json:"msg"`
}

func run(t *testing.T, e env.Env, cur *cursor.State) []outLine {
	t.Helper()
	var buf bytes.Buffer
	out := event.NewEmitter(&buf)
	if err := Scan(context.Background(), e, cur, out); err != nil {
		t.Fatal(err)
	}
	out.Flush()
	var res []outLine
	sc := bufio.NewScanner(&buf)
	for sc.Scan() {
		var l outLine
		if err := json.Unmarshal(sc.Bytes(), &l); err != nil {
			t.Fatalf("bad output %q: %v", sc.Text(), err)
		}
		res = append(res, l)
	}
	return res
}

func reqs(ls []outLine) map[string]event.Req {
	m := map[string]event.Req{}
	for _, l := range ls {
		if l.K == "req" {
			if _, dup := m[l.Key]; dup {
				panic("duplicate key in one scan: " + l.Key)
			}
			m[l.Key] = l.Req
		}
	}
	return m
}

func copyFile(t *testing.T, src, dst string) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", src))
	if err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Dir(dst), 0o755)
	if err := os.WriteFile(dst, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func appendFile(t *testing.T, src, dst string) {
	t.Helper()
	b, _ := os.ReadFile(filepath.Join("testdata", src))
	f, err := os.OpenFile(dst, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	f.Write(b)
	f.Close()
}

func ts(s string) time.Time { t, _ := time.Parse(time.RFC3339, s); return t }

func setup(t *testing.T) (env.Env, string) {
	home := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	p := filepath.Join(home, ".claude", "projects")
	copyFile(t, "session.jsonl", filepath.Join(p, "-fake-project", "sess-main-0001.jsonl"))
	copyFile(t, "fork.jsonl", filepath.Join(p, "-fake-project", "sess-fork-0002.jsonl"))
	copyFile(t, "subagent.jsonl", filepath.Join(p, "-fake-project", "sess-main-0001", "subagents", "agent-fake.jsonl"))
	copyFile(t, "mirror.jsonl", filepath.Join(p, "ssh-sess-remote-0003", "sess-remote-0003.jsonl"))
	copyFile(t, "claude.json", filepath.Join(home, ".claude.json"))
	now := ts("2026-11-20T12:00:00Z")
	return env.Env{Home: home, Now: now, Since: now.Add(-30 * 24 * time.Hour)}, p
}

func TestScan(t *testing.T) {
	e, _ := setup(t)
	out := run(t, e, cursor.New())
	r := reqs(out)
	acct := jsonl.AcctHash("00000000-fake-acct-0000-000000000001")

	if _, ok := r["msg_fake_synth"]; ok {
		t.Error("<synthetic> must not be emitted")
	}
	if _, ok := r["msg_fake_old"]; ok {
		t.Error("record older than --since emitted")
	}
	if len(r) != 6 {
		t.Errorf("got %d reqs, want 6: %v", len(r), r)
	}

	// One request over many lines, a zero-usage twin, copies in a fork and a mirror.
	a := r["msg_fake_A"]
	if a.In != 2 || a.CR != 1000 || a.CW1 != 200 || a.CW5 != 100 || a.Out != 400 || a.Think != 150 {
		t.Errorf("A usage = %+v", a)
	}
	if a.Session != "sess-main-0001" || a.Mirror || a.Sub || a.Cwd != "/fake/project" {
		t.Errorf("A attribution from wrong copy: %+v", a)
	}
	if a.TQ != "est" || a.Dur == nil || *a.Dur != 5000 || a.TTFT == nil || *a.TTFT != 1000 {
		t.Errorf("A timing = tq %s dur %v ttft %v", a.TQ, a.Dur, a.TTFT)
	}
	if a.Pool != "claude" || a.Provider != "anthropic" || a.Acct != acct || a.Effort != "high" || a.Tier != "standard" || a.Stop != "tool_use" {
		t.Errorf("A attrs = %+v", a)
	}

	// Text-first request: duration but no TTFT; retries from api_error chain.
	b := r["msg_fake_B"]
	if b.Retries != 2 || b.TQ != "est" || b.Dur == nil || *b.Dur != 4000 || b.TTFT != nil || b.Speed != "fast" {
		t.Errorf("B = %+v dur %v ttft %v", b, b.Dur, b.TTFT)
	}
	// Third-party model via Claude Desktop: no pool.
	if c := r["msg_fake_C"]; c.Pool != "" || c.Provider != "other" || c.Acct != "" {
		t.Errorf("C = %+v", c)
	}
	// No api-request record: no timing; cache write without split goes to cw5.
	if d := r["msg_fake_D"]; d.TQ != "none" || d.Dur != nil || d.CW5 != 40 || d.Pool != "claude" {
		t.Errorf("D = %+v", d)
	}
	if s := r["msg_fake_E"]; !s.Sub {
		t.Errorf("subagent file not sub: %+v", s)
	}
	if m := r["msg_fake_F"]; !m.Mirror || m.Cwd != "/home/fake" {
		t.Errorf("mirror = %+v", m)
	}

	var limits, logs int
	for _, l := range out {
		switch l.K {
		case "limit":
			limits++
			if l.Window != "five_hour" || !l.Limited || l.Used == nil || *l.Used != 100 || l.Resets == nil || *l.Resets != 1795658400000 || l.Src != "transcript" {
				t.Errorf("limit = %+v", l)
			}
		case "log":
			logs++ // malformed line counted
		}
	}
	if limits != 1 || logs != 1 {
		t.Errorf("limits %d logs %d", limits, logs)
	}

	// Nothing changed: zero reqs.
	cur := cursor.New()
	run(t, e, cur)
	if n := len(reqs(run(t, e, cur))); n != 0 {
		t.Errorf("second scan emitted %d reqs", n)
	}
}

func TestCursorRoundTripAndSplitRequest(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	path := filepath.Join(home, ".claude", "projects", "-fake-split", "sess-split-0009.jsonl")
	copyFile(t, "split_a.jsonl", path)
	now := ts("2026-11-20T11:00:03Z")
	e := env.Env{Home: home, Now: now, Since: now.Add(-24 * time.Hour)}

	cur := cursor.New()
	if r := reqs(run(t, e, cur)); len(r) != 0 {
		t.Fatalf("in-flight request emitted with partial usage: %+v", r)
	}
	if f, _ := cur.Get(path); f.Off != 0 {
		t.Errorf("cursor not held at the api-request line: %+v", f)
	}
	// The cursor survives encoding; the rest of the request arrives.
	cur = cursor.Decode(cur.Encode())
	appendFile(t, "split_b.jsonl", path)
	e.Now = ts("2026-11-20T11:00:07Z")
	s, ok := reqs(run(t, e, cur))["msg_fake_S"]
	if !ok || s.Out != 300 || s.CR != 500 || s.Dur == nil || *s.Dur != 6000 || s.TTFT == nil || *s.TTFT != 500 {
		t.Fatalf("split request = %+v (ok %v)", s, ok)
	}
	if f, _ := cur.Get(path); f.Off != f.Size {
		t.Errorf("cursor not advanced: %+v", f)
	}
	if n := len(reqs(run(t, e, cur))); n != 0 {
		t.Errorf("unchanged file re-emitted %d", n)
	}
}

func TestStaleInFlightIsEmitted(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	path := filepath.Join(home, ".claude", "projects", "-fake-split", "s.jsonl")
	copyFile(t, "split_a.jsonl", path)
	old := ts("2026-11-20T11:00:02Z")
	os.Chtimes(path, old, old)
	e := env.Env{Home: home, Now: ts("2026-11-20T13:00:00Z"), Since: old.Add(-time.Hour)}
	if s := reqs(run(t, e, cursor.New()))["msg_fake_S"]; s.Out != 5 {
		t.Errorf("abandoned request not emitted: %+v", s)
	}
}

func TestTruncation(t *testing.T) {
	e, p := setup(t)
	cur := cursor.New()
	run(t, e, cur)
	path := filepath.Join(p, "-fake-project", "sess-main-0001.jsonl")
	// Replace with a shorter file: must be read again from 0.
	copyFile(t, "subagent.jsonl", path)
	r := reqs(run(t, e, cur))
	if _, ok := r["msg_fake_E"]; !ok || len(r) != 1 {
		t.Errorf("after truncation got %v", r)
	}
}

func TestConfigDir(t *testing.T) {
	home := t.TempDir()
	cfg := filepath.Join(home, "alt")
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	copyFile(t, "subagent.jsonl", filepath.Join(cfg, "projects", "-x", "a.jsonl"))
	now := ts("2026-11-20T12:00:00Z")
	e := env.Env{Home: home, Now: now, Since: now.Add(-time.Hour * 24)}
	if r := reqs(run(t, e, cursor.New())); len(r) != 1 {
		t.Errorf("CLAUDE_CONFIG_DIR not honoured: %v", r)
	}
}

func TestSessions(t *testing.T) {
	e, p := setup(t)
	dir := filepath.Join(e.Home, ".claude", "sessions")
	os.MkdirAll(dir, 0o755)
	live := map[string]any{"pid": os.Getpid(), "sessionId": "sess-main-0001", "cwd": "/fake/project", "status": "busy", "updatedAt": e.Now.UnixMilli(), "startedAt": e.Now.UnixMilli() - 1000}
	dead := map[string]any{"pid": 999999, "sessionId": "sess-dead", "status": "busy", "updatedAt": e.Now.Add(-48 * time.Hour).UnixMilli()}
	for n, v := range map[string]any{"1.json": live, "2.json": dead} {
		b, _ := json.Marshal(v)
		os.WriteFile(filepath.Join(dir, n), b, 0o644)
	}
	_ = p
	var buf bytes.Buffer
	out := event.NewEmitter(&buf)
	Sessions(context.Background(), e, out)
	out.Flush()
	var got []event.Session
	sc := bufio.NewScanner(&buf)
	for sc.Scan() {
		var s event.Session
		json.Unmarshal(sc.Bytes(), &s)
		got = append(got, s)
	}
	if len(got) != 1 || got[0].ID != "sess-main-0001" || got[0].Status != "busy" || got[0].Model != "claude-sonnet-5-5" {
		t.Errorf("sessions = %+v", got)
	}
}
