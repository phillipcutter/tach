package antigravity

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tach/collector/internal/cursor"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
	"tach/collector/internal/pb"
)

func dur(sec, nanos uint64) *pb.Builder { return (&pb.Builder{}).Uint(1, sec).Uint(2, nanos) }

type genSpec struct {
	model, display, reqID    string
	in, out, cr, think, resp uint64
	usedClaude               bool
	noUsage                  bool
	parent                   string
}

const secretText = "SECRET PROMPT TEXT must never be emitted"

func genBlob(s genSpec) []byte {
	cmm := &pb.Builder{}
	cmm.Str(1, secretText) // content-like fields exist in real rows; they must be ignored
	if !s.noUsage {
		u := (&pb.Builder{}).Uint(1, 1533).Uint(2, s.in).Uint(3, s.out).Uint(6, 24).Str(7, "resp-id")
		if s.cr > 0 {
			u.Uint(5, s.cr)
		}
		u.Uint(9, s.think).Uint(10, s.resp)
		cmm.Msg(4, u)
	}
	cmm.Msg(9, (&pb.Builder{}).Uint(2, 1<<63).Msg(10, (&pb.Builder{}).Uint(1, 21961).Uint(4, 512000)))
	cmm.Msg(11, dur(3, 881103333)) // TTFT 3.881 s
	cmm.Msg(12, dur(7, 592142250)) // streaming 7.592 s
	cmm.Str(19, s.model)
	label := func(k, v string) { cmm.Msg(20, (&pb.Builder{}).Str(1, k).Str(2, v)) }
	label("root_cascade_id", "c1")
	if s.reqID != "" {
		label("request_id", s.reqID)
	}
	label("used_claude", map[bool]string{true: "true", false: "false"}[s.usedClaude])
	label("used_non_gemini_model", "false")
	label("prompt_excerpt", secretText)
	if s.parent != "" {
		label("parent_cascade_id", s.parent)
	}
	cmm.Str(21, s.display)
	return (&pb.Builder{}).Msg(1, cmm).Str(4, "f93b744f").Bytes()
}

func stepBlob(created, completed uint64, genIdx int) []byte {
	ref := (&pb.Builder{}).Str(1, "traj").Uint(2, 1)
	if genIdx > 0 {
		ref.Uint(3, uint64(genIdx))
	}
	return (&pb.Builder{}).
		Msg(1, dur(created, 0)).
		Msg(7, dur(completed, 500_000_000)).
		Msg(20, ref).Bytes()
}

func TestDecodeGen(t *testing.T) {
	g, err := decodeGen(genBlob(genSpec{model: "gemini-4-neon", display: "Gemini 4 Neon (Medium)", reqID: "t-3",
		in: 4693, cr: 23236, out: 2753, think: 1794, resp: 959}))
	if err != nil {
		t.Fatal(err)
	}
	if g.Model != "gemini-4-neon" || g.In != 4693 || g.CR != 23236 || g.Out != 2753 || g.Think != 1794 ||
		g.TTFT != 3881 || g.Stream != 7592 || g.CtxUsed != 21961 || g.CtxMax != 512000 || g.Labels["request_id"] != "t-3" {
		t.Fatalf("%+v", g)
	}
	if _, ok := g.Labels["prompt_excerpt"]; ok {
		t.Fatal("unknown labels must be dropped")
	}
	if effortFromDisplay(g.Display) != "medium" {
		t.Fatal("effort")
	}
	// Sanity check: output must equal thinking + response.
	if _, err := decodeGen(genBlob(genSpec{model: "m", in: 1, out: 100, think: 10, resp: 20})); err != errSanity {
		t.Fatalf("want errSanity, got %v", err)
	}
	if _, err := decodeGen(genBlob(genSpec{model: "m", noUsage: true})); err != errNoUsage {
		t.Fatalf("want errNoUsage, got %v", err)
	}
	if _, err := decodeGen([]byte{0xff}); err == nil {
		t.Fatal("garbage must fail")
	}
	if _, err := decodeGen((&pb.Builder{}).Str(4, "x").Bytes()); err != errNoMeta {
		t.Fatalf("want errNoMeta, got %v", err)
	}
}

func TestStepMeta(t *testing.T) {
	st, ok := decodeStepMeta(15, stepBlob(1795573575, 1795573587, 0))
	if !ok || st.GenIdx != 0 || st.Created != 1795573575000 || st.Completed != 1795573587500 {
		t.Fatalf("%+v", st)
	}
	// A non-response step whose reference omits f3 does not claim generation 0.
	st, _ = decodeStepMeta(14, stepBlob(1, 2, 0))
	if st.GenIdx != -1 {
		t.Fatalf("%+v", st)
	}
	st, _ = decodeStepMeta(132, stepBlob(1, 2, 4))
	if st.GenIdx != 4 {
		t.Fatalf("%+v", st)
	}
}

func TestPoolProvider(t *testing.T) {
	if poolFor("gemini-4-neon", nil) != "gemini" || poolFor("claude-opus-5-5", nil) != "gemini_3p" ||
		poolFor("gemini-4-neon", map[string]string{"used_claude": "true"}) != "gemini_3p" ||
		poolFor("x", map[string]string{"used_non_gemini_model": "true"}) != "gemini_3p" ||
		poolFor("gpt-oss-120b", nil) != "gemini_3p" {
		t.Fatal("pool")
	}
	if providerFor("gemini-4-carbon") != "google" || providerFor("claude-sonnet-5-5") != "anthropic" || providerFor("gpt-oss-120b") != "openai" || providerFor("llama") != "other" {
		t.Fatal("provider")
	}
}

func mkdb(t *testing.T, path string, schema string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(schema); err != nil {
		t.Fatal(err)
	}
	return db
}

const convSchema = "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, status integer NOT NULL DEFAULT 0, metadata blob, step_payload blob);" +
	"CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob, size integer NOT NULL DEFAULT 0);"

const sumSchema = "CREATE TABLE conversation_summaries (conversation_id text PRIMARY KEY, title text NOT NULL DEFAULT '', preview text NOT NULL DEFAULT ''," +
	"step_count integer NOT NULL DEFAULT 0, last_modified_time datetime NOT NULL, workspace_uris text NOT NULL, status text NOT NULL DEFAULT ''," +
	"parent_conversation_id text NOT NULL DEFAULT '', nesting_depth integer NOT NULL DEFAULT 0, not_fully_idle numeric NOT NULL DEFAULT false," +
	"killed numeric NOT NULL DEFAULT false, raw_summary blob);"

func run(t *testing.T, e env.Env, cur *cursor.State) []map[string]any {
	t.Helper()
	var buf bytes.Buffer
	out := event.NewEmitter(&buf)
	if err := Scan(context.Background(), e, cur, out); err != nil {
		t.Fatal(err)
	}
	if err := Sessions(context.Background(), e, out); err != nil {
		t.Fatal(err)
	}
	out.Flush()
	if strings.Contains(buf.String(), "SECRET") {
		t.Fatal("content leaked into output")
	}
	var recs []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if l == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatal(err)
		}
		recs = append(recs, m)
	}
	return recs
}

func kinds(recs []map[string]any, k string) []map[string]any {
	var r []map[string]any
	for _, m := range recs {
		if m["k"] == k {
			r = append(r, m)
		}
	}
	return r
}

func TestScanAndCursor(t *testing.T) {
	home := t.TempDir()
	dir := ConversationsDir(home)
	os.MkdirAll(dir, 0o755)
	now := time.Now()
	base := uint64(now.Add(-10 * time.Minute).Unix())

	main := "11111111-1111-1111-1111-111111111111"
	child := "22222222-2222-2222-2222-222222222222"
	s := mkdb(t, filepath.Join(Root(home), "conversation_summaries.db"), sumSchema)
	ts := now.Add(-5 * time.Minute).UTC().Format("2006-01-02 15:04:05.999999-07:00")
	s.Exec(`INSERT INTO conversation_summaries (conversation_id, title, last_modified_time, workspace_uris, status, parent_conversation_id, nesting_depth)
		VALUES (?, ?, ?, ?, 'CASCADE_RUN_STATUS_IDLE', '', 0), (?, ?, ?, ?, 'CASCADE_RUN_STATUS_IDLE', ?, 1)`,
		main, secretText, ts, `["file:///Users/me/my%20proj"]`, child, secretText, ts, `["file:///Users/me/my%20proj"]`, main)
	s.Close()

	db := mkdb(t, filepath.Join(dir, main+".db"), convSchema)
	db.Exec(`INSERT INTO steps VALUES (0, 14, 3, ?, ?)`, (&pb.Builder{}).Msg(1, dur(base, 0)).Bytes(), []byte(secretText))
	db.Exec(`INSERT INTO steps VALUES (1, 15, 3, ?, ?)`, stepBlob(base+1, base+12, 0), []byte(secretText))
	db.Exec(`INSERT INTO steps VALUES (2, 15, 3, ?, ?)`, stepBlob(base+20, base+30, 1), []byte(secretText))
	db.Exec(`INSERT INTO gen_metadata VALUES (0, ?, 0)`, genBlob(genSpec{model: "gemini-4-neon", display: "Gemini 4 Neon (Medium)", reqID: "traj-0", in: 15171, out: 1090, think: 903, resp: 187}))
	db.Exec(`INSERT INTO gen_metadata VALUES (1, ?, 0)`, genBlob(genSpec{model: "claude-opus-5-5", reqID: "", in: 10, cr: 5, out: 3, think: 1, resp: 2, usedClaude: true}))
	db.Exec(`INSERT INTO gen_metadata VALUES (2, ?, 0)`, genBlob(genSpec{model: "gemini-4-neon", in: 1, out: 9, think: 1, resp: 2})) // fails sanity
	db.Close()

	cdb := mkdb(t, filepath.Join(dir, child+".db"), convSchema)
	cdb.Exec(`INSERT INTO steps VALUES (0, 15, 3, ?, NULL)`, stepBlob(base+40, base+50, 0))
	cdb.Exec(`INSERT INTO gen_metadata VALUES (0, ?, 0)`, genBlob(genSpec{model: "gemini-4-carbon", reqID: "sub-0", in: 7, out: 2, think: 1, resp: 1, parent: main}))
	cdb.Exec(`INSERT INTO gen_metadata VALUES (1, ?, 0)`, genBlob(genSpec{noUsage: true})) // trailing, possibly in progress
	cdb.Close()

	e := env.Env{Home: home, Now: now, Since: now.Add(-720 * time.Hour)}
	cur := cursor.New()
	recs := run(t, e, cur)
	reqs := kinds(recs, "req")
	if len(reqs) != 3 {
		t.Fatalf("want 3 req, got %d: %v", len(reqs), recs)
	}
	by := map[string]map[string]any{}
	for _, r := range reqs {
		by[r["key"].(string)] = r
	}
	r0 := by["traj-0"]
	if r0 == nil || r0["model"] != "gemini-4-neon" || r0["pool"] != "gemini" || r0["provider"] != "google" || r0["in"].(float64) != 15171 ||
		r0["out"].(float64) != 1090 || r0["think"].(float64) != 903 || r0["ttft"].(float64) != 3881 || r0["dur"].(float64) != 3881+7592 ||
		r0["tq"] != "exact" || r0["ts"].(float64) != float64((base+12)*1000+500) || r0["session"] != main || r0["cwd"] != "/Users/me/my proj" ||
		r0["sub"] != nil || r0["effort"] != "medium" || r0["tool"] != "antigravity" {
		t.Errorf("req 0: %v", r0)
	}
	r1 := by[main+":1"]
	if r1 == nil || r1["pool"] != "gemini_3p" || r1["provider"] != "anthropic" || r1["cr"].(float64) != 5 || r1["ts"].(float64) != float64((base+30)*1000+500) {
		t.Errorf("req 1 (fallback key, 3p pool): %v", r1)
	}
	if rs := by["sub-0"]; rs == nil || rs["sub"] != true || rs["session"] != child {
		t.Errorf("subagent req: %v", rs)
	}
	logs := kinds(recs, "log")
	if len(logs) != 1 || !strings.Contains(logs[0]["msg"].(string), "sanity") {
		t.Errorf("want one sanity warning, got %v", logs)
	}
	sess := kinds(recs, "session")
	if len(sess) != 2 || sess[0]["status"] != "idle" {
		t.Errorf("sessions: %v", sess)
	}
	for _, s := range sess {
		// The newest generation fails the sanity check, so the model comes from the one before it.
		if s["id"] == main && (s["model"] != "claude-opus-5-5" || s["ctx"].(float64) != 4.3 || s["started"].(float64) != float64(base*1000)) {
			t.Errorf("session detail: %v", s)
		}
	}
	if f, _ := cur.Get(filepath.Join(dir, main+".db")); f.Off != 3 {
		t.Errorf("cursor main: %+v", f)
	}
	if f, _ := cur.Get(filepath.Join(dir, child+".db")); f.Off != 1 {
		t.Errorf("cursor child must stop before the trailing row without usage: %+v", f)
	}

	// Round-trip the cursor: nothing new.
	cur2 := cursor.Decode(cur.Encode())
	if reqs := kinds(run(t, e, cur2), "req"); len(reqs) != 0 {
		t.Fatalf("second scan emitted %d req", len(reqs))
	}

	// The in-progress row completes and one more generation arrives.
	cdb, _ = sql.Open("sqlite", filepath.Join(dir, child+".db"))
	cdb.Exec(`UPDATE gen_metadata SET data = ? WHERE idx = 1`, genBlob(genSpec{model: "gemini-4-carbon", reqID: "sub-1", in: 1, out: 2, think: 1, resp: 1}))
	cdb.Exec(`INSERT INTO gen_metadata VALUES (2, ?, 0)`, genBlob(genSpec{model: "gemini-4-carbon", reqID: "sub-2", in: 1, out: 2, think: 1, resp: 1}))
	cdb.Close()
	reqs = kinds(run(t, e, cur2), "req")
	if len(reqs) != 2 || reqs[0]["key"] != "sub-1" || reqs[1]["key"] != "sub-2" {
		t.Fatalf("incremental: %v", reqs)
	}
}

func TestSinceOnFirstScan(t *testing.T) {
	home := t.TempDir()
	dir := ConversationsDir(home)
	os.MkdirAll(dir, 0o755)
	p := filepath.Join(dir, "old.db")
	db := mkdb(t, p, convSchema)
	db.Exec(`INSERT INTO steps VALUES (0, 15, 3, ?, NULL)`, stepBlob(1000, 1010, 0))
	db.Exec(`INSERT INTO gen_metadata VALUES (0, ?, 0)`, genBlob(genSpec{model: "gemini-4-neon", reqID: "old", in: 1, out: 2, think: 1, resp: 1}))
	db.Close()
	now := time.Now()
	e := env.Env{Home: home, Now: now, Since: now.Add(-time.Hour)}
	if reqs := kinds(run(t, e, cursor.New()), "req"); len(reqs) != 0 {
		t.Fatalf("generation older than --since emitted: %v", reqs)
	}
}

func TestServers(t *testing.T) {
	home := t.TempDir()
	d := filepath.Join(Root(home), "daemon")
	os.MkdirAll(d, 0o700)
	os.WriteFile(filepath.Join(d, "hub_1.json"), []byte(`{"pid": 0, "httpsPort": 2, "httpPort": 3, "lsVersion": "2.35.1", "csrfToken": "SYNTHETIC-CSRF"}`), 0o600)
	os.WriteFile(filepath.Join(d, "ls_abc.json"), []byte(`{"pid": 999999999, "http_port": "4", "csrf_token": "x"}`), 0o600)
	os.WriteFile(filepath.Join(d, "junk.json"), []byte(`not json`), 0o600)
	ss := Servers(home)
	if len(ss) != 2 || !ss[0].Alive || ss[0].HTTPPort != 3 || ss[0].CSRF != "SYNTHETIC-CSRF" || ss[1].Alive || ss[1].HTTPPort != 4 {
		t.Fatalf("%+v", ss)
	}
	if strings.Contains(ss[0].String(), "SYNTHETIC") {
		t.Fatal("String leaks the CSRF token")
	}
}
