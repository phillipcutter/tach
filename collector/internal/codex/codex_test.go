package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"

	"tach/collector/internal/cursor"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
	"tach/collector/internal/jsonl"
)

type outLine struct {
	K string `json:"k"`
	event.Req
	Window string   `json:"window"`
	Kind   string   `json:"kind"`
	Used   *float64 `json:"used"`
	Resets *int64   `json:"resets"`
	Len    int64    `json:"len"`
	Status string   `json:"status"`
	Level  string   `json:"level"`
	Msg    string   `json:"msg"`
}

type output struct {
	reqs   map[string]event.Req
	turns  map[string]outLine
	limits []outLine
	logs   []outLine
}

func run(t *testing.T, e env.Env, cur *cursor.State) output {
	t.Helper()
	var buf bytes.Buffer
	out := event.NewEmitter(&buf)
	if err := Scan(context.Background(), e, cur, out); err != nil {
		t.Fatal(err)
	}
	out.Flush()
	o := output{reqs: map[string]event.Req{}, turns: map[string]outLine{}}
	sc := bufio.NewScanner(&buf)
	for sc.Scan() {
		var l outLine
		if err := json.Unmarshal(sc.Bytes(), &l); err != nil {
			t.Fatal(err)
		}
		switch l.K {
		case "req":
			if _, dup := o.reqs[l.Key]; dup {
				t.Errorf("duplicate key %s", l.Key)
			}
			o.reqs[l.Key] = l.Req
		case "turn":
			o.turns[l.Key] = l
		case "limit":
			o.limits = append(o.limits, l)
		case "log":
			o.logs = append(o.logs, l)
		}
	}
	return o
}

func put(t *testing.T, src, dst string) {
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

func putZst(t *testing.T, b []byte, dst string) {
	t.Helper()
	var buf bytes.Buffer
	w, _ := zstd.NewWriter(&buf)
	w.Write(b)
	w.Close()
	os.MkdirAll(filepath.Dir(dst), 0o755)
	os.WriteFile(dst, buf.Bytes(), 0o644)
}

func ts(s string) time.Time { t, _ := time.Parse(time.RFC3339, s); return t }

func newEnv(t *testing.T) (env.Env, string) {
	home := t.TempDir()
	dir := filepath.Join(home, ".codex")
	t.Setenv("CODEX_HOME", "")
	put(t, "auth.json", filepath.Join(dir, "auth.json"))
	now := ts("2026-11-20T12:00:00Z")
	return env.Env{Home: home, Now: now, Since: now.Add(-30 * 24 * time.Hour)}, dir
}

const newPath = "sessions/2026/11/20/rollout-2026-11-20T10-00-00-thread-new-0001.jsonl"

func TestScan(t *testing.T) {
	e, dir := newEnv(t)
	put(t, "new.jsonl", filepath.Join(dir, newPath))
	put(t, "fork.jsonl", filepath.Join(dir, "sessions/2026/11/20/rollout-2026-11-20T11-00-00-thread-sub-0002.jsonl"))
	old, _ := os.ReadFile("testdata/old.jsonl")
	putZst(t, old, filepath.Join(dir, "archived_sessions/rollout-2026-11-19T09-00-00-thread-old-0003.jsonl.zst"))

	cur := cursor.New()
	o := run(t, e, cur)
	acct := jsonl.AcctHash("fake-account-0001")

	r1 := o.reqs["resp_fake_0001"]
	if r1.In != 400 || r1.CR != 600 || r1.Out != 50 || r1.Think != 20 || r1.Model != "gpt-6.2-sol" ||
		r1.Effort != "high" || r1.Tier != "priority" || r1.Pool != "openai" || r1.Acct != acct || r1.Sub || r1.TQ != "none" || r1.Session != "thread-new-0001" {
		t.Errorf("r1 = %+v", r1)
	}
	// Forked subagent: replayed parent records skipped; own model used.
	r3, ok := o.reqs["resp_fake_0003"]
	if !ok || !r3.Sub || r3.Model != "gpt-6.2-astra" || r3.Session != "thread-sub-0002" {
		t.Errorf("r3 = %+v", r3)
	}
	// Old file: last_token_usage deltas, duplicate token_count ignored.
	a, b := o.reqs["thread-old-0003/2"], o.reqs["thread-old-0003/4"]
	if a.In != 50 || a.CR != 40 || a.Out != 10 || b.In != 30 || b.CR != 100 || b.Out != 20 || a.Model != "gpt-6-astra" {
		t.Errorf("old = %+v %+v", a, b)
	}
	if len(o.reqs) != 5 {
		t.Errorf("got %d reqs: %v", len(o.reqs), o.reqs)
	}
	// Turns: the replayed parent task_complete is not emitted twice / from the fork.
	tn := o.turns["turn-0001"]
	if tn.Dur == nil || *tn.Dur != 9000 || tn.TTFT == nil || *tn.TTFT != 1500 || tn.Out != 120 || tn.Model != "gpt-6.2-sol" {
		t.Errorf("turn = %+v", tn)
	}
	if to := o.turns["turn-old-1"]; to.Out != 30 || to.TS != 1795597210000 {
		t.Errorf("old turn = %+v", to)
	}
	if len(o.turns) != 2 {
		t.Errorf("turns = %v", o.turns)
	}
	// Limits: weekly at 10:00:05 is thinned away by 10:00:09 (< 5 min), 10:20 kept;
	// the 300-minute secondary is a five_hour session window.
	var weekly, five int
	for _, l := range o.limits {
		switch l.Window {
		case "weekly":
			weekly++
		case "five_hour":
			five++
			if l.Kind != "session" || *l.Used != 40 || l.Len != 18000 {
				t.Errorf("five_hour = %+v", l)
			}
		}
	}
	if weekly != 2 || five != 1 {
		t.Errorf("limits weekly %d five %d: %+v", weekly, five, o.limits)
	}
	if len(o.logs) != 1 {
		t.Errorf("malformed line not logged: %v", o.logs)
	}

	// Second scan, nothing changed: nothing emitted; archive not re-read.
	cur = cursor.Decode(cur.Encode())
	o2 := run(t, e, cur)
	if len(o2.reqs)+len(o2.turns)+len(o2.limits) != 0 {
		t.Errorf("second scan emitted %v %v %v", o2.reqs, o2.turns, o2.limits)
	}
}

func TestResumeMidFileAndArchiveTwin(t *testing.T) {
	e, dir := newEnv(t)
	full, _ := os.ReadFile("testdata/new.jsonl")
	// First scan sees only the first 7 lines (through the first token_count).
	cut := 0
	for i, n := 0, 0; i < len(full); i++ {
		if full[i] == '\n' {
			if n++; n == 7 {
				cut = i + 1
				break
			}
		}
	}
	live := filepath.Join(dir, newPath)
	os.MkdirAll(filepath.Dir(live), 0o755)
	os.WriteFile(live, full[:cut+20], 0o644) // plus a partial line
	cur := cursor.New()
	o := run(t, e, cur)
	if _, ok := o.reqs["resp_fake_0001"]; !ok || len(o.reqs) != 1 {
		t.Fatalf("first part: %v", o.reqs)
	}
	if f, _ := cur.Get(live); f.Off != int64(cut) {
		t.Fatalf("offset %d want %d", f.Off, cut)
	}
	// The thread is archived: the live file goes, a .zst with the full content appears.
	os.Remove(live)
	putZst(t, full, filepath.Join(dir, "archived_sessions", filepath.Base(newPath)+".zst"))
	o = run(t, e, cursor.Decode(cur.Encode()))
	r2, ok := o.reqs["resp_fake_0002"]
	if !ok || len(o.reqs) != 1 || r2.Model != "gpt-6.2-sol" || r2.Tier != "priority" || r2.Session != "thread-new-0001" {
		t.Errorf("archive resume: %v", o.reqs)
	}
	if tn := o.turns["turn-0001"]; tn.Out != 120 {
		t.Errorf("turn out across resume = %+v", tn)
	}
}

func TestTruncatedRolloutRereads(t *testing.T) {
	e, dir := newEnv(t)
	live := filepath.Join(dir, newPath)
	put(t, "new.jsonl", live)
	cur := cursor.New()
	run(t, e, cur)
	put(t, "fork.jsonl", live) // replaced by a shorter file
	o := run(t, e, cur)
	if _, ok := o.reqs["resp_fake_0003"]; !ok || len(o.reqs) != 1 {
		t.Errorf("after truncation: %v", o.reqs)
	}
}

func TestNoChatGPTNoPool(t *testing.T) {
	e, dir := newEnv(t)
	os.WriteFile(filepath.Join(dir, "auth.json"), []byte(`{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE"}`), 0o600)
	put(t, "fork.jsonl", filepath.Join(dir, "sessions/2026/11/20/rollout-2026-11-20T11-00-00-thread-sub-0002.jsonl"))
	o := run(t, e, cursor.New())
	if r := o.reqs["resp_fake_0003"]; r.Pool != "" || r.Acct != "" {
		t.Errorf("api-key request got pool: %+v", r)
	}
}

func TestSessions(t *testing.T) {
	e, dir := newEnv(t)
	put(t, "new.jsonl", filepath.Join(dir, newPath))
	e.Now = time.Now()
	var buf bytes.Buffer
	out := event.NewEmitter(&buf)
	Sessions(context.Background(), e, out)
	out.Flush()
	var s event.Session
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &s); err != nil {
		t.Fatalf("%q: %v", buf.String(), err)
	}
	if s.ID != "thread-new-0001" || s.Status != "idle" || s.Model != "gpt-6.2-sol" || s.Tokens != 1270 || s.Ctx < 0.31 || s.Ctx > 0.32 {
		t.Errorf("session = %+v", s)
	}
}
