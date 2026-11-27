package gemini

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
)

func run(t *testing.T, e env.Env, cur *cursor.State) (map[string]event.Req, int) {
	var buf bytes.Buffer
	out := event.NewEmitter(&buf)
	if err := Scan(context.Background(), e, cur, out); err != nil {
		t.Fatal(err)
	}
	out.Flush()
	m := map[string]event.Req{}
	logs := 0
	sc := bufio.NewScanner(&buf)
	for sc.Scan() {
		var r event.Req
		json.Unmarshal(sc.Bytes(), &r)
		switch r.K {
		case "req":
			if _, dup := m[r.Key]; dup {
				t.Errorf("duplicate %s", r.Key)
			}
			m[r.Key] = r
		case "log":
			logs++
		}
	}
	return m, logs
}

func put(t *testing.T, src, dst string) {
	b, _ := os.ReadFile(filepath.Join("testdata", src))
	os.MkdirAll(filepath.Dir(dst), 0o755)
	os.WriteFile(dst, b, 0o644)
}

func TestScan(t *testing.T) {
	home := t.TempDir()
	chats := filepath.Join(home, ".gemini", "tmp", "fakeproj", "chats")
	put(t, "session.jsonl", filepath.Join(chats, "session-2026-11-20T10-00-gem1.jsonl"))
	put(t, "session.json", filepath.Join(chats, "session-2026-11-19T10-00-gem2.json"))
	now, _ := time.Parse(time.RFC3339, "2026-11-20T12:00:00Z")
	e := env.Env{Home: home, Now: now, Since: now.Add(-30 * 24 * time.Hour)}
	cur := cursor.New()
	r, logs := run(t, e, cur)
	g1 := r["gem-sess-0001/g-1"]
	if g1.In != 610 || g1.CR != 400 || g1.Out != 170 || g1.Think != 50 || g1.TQ != "none" || g1.Pool != "" || g1.Provider != "google" || g1.Session != "gem-sess-0001" {
		t.Errorf("g1 = %+v", g1)
	}
	if len(r) != 3 || r["gem-sess-0002/g-9"].Out != 4 || logs != 1 {
		t.Errorf("reqs %v logs %d", r, logs)
	}
	// Resume: append a record; the session id comes from the cursor.
	f, _ := os.OpenFile(filepath.Join(chats, "session-2026-11-20T10-00-gem1.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"id":"g-4","timestamp":"2026-11-20T10:02:00.000Z","type":"gemini","tokens":{"input":5,"output":1,"cached":0,"thoughts":0,"tool":0,"total":6},"model":"gemini-3-pro"}` + "\n")
	f.Close()
	r, _ = run(t, e, cursor.Decode(cur.Encode()))
	if len(r) != 1 || r["gem-sess-0001/g-4"].In != 5 {
		t.Errorf("resume: %v", r)
	}
}
