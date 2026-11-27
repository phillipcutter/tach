// Package gemini reads usage written by Gemini CLI chat logs. See
// docs/collector-protocol.md and design/data-sources.md 3.8.
//
// Current Gemini CLI writes ~/.gemini/tmp/<project>/chats/session-*.jsonl: a
// header line with sessionId and kind, then message records, rewritten records
// (the same id again) and {"$set": ...} updates. Older versions wrote one
// session-*.json document with a messages array; both are read.
package gemini

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"tach/collector/internal/cursor"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
	"tach/collector/internal/jsonl"
)

const tool = "gemini_cli"

type toks struct {
	Input    int64 `json:"input"`
	Output   int64 `json:"output"`
	Cached   int64 `json:"cached"`
	Thoughts int64 `json:"thoughts"`
	Tool     int64 `json:"tool"`
}

type msg struct {
	Type      string `json:"type"`
	ID        string `json:"id"`
	Timestamp string `json:"timestamp"`
	Model     string `json:"model"`
	Tokens    *toks  `json:"tokens"`

	// header
	SessionID string `json:"sessionId"`
	Kind      string `json:"kind"`
}

type header struct {
	Session string `json:"s"`
	Kind    string `json:"k,omitempty"`
}

var markers = [][]byte{[]byte(`"sessionId"`), []byte(`"type":"gemini"`)}

func mkReq(h header, m msg) (event.Req, bool) {
	if m.Type != "gemini" || m.Tokens == nil || m.ID == "" || h.Session == "" {
		return event.Req{}, false
	}
	t := m.Tokens
	// Gemini's prompt count includes cached tokens; tool-use prompt tokens are
	// input too. Output excludes thoughts, which the protocol counts in out.
	return event.Req{
		Tool: tool, Key: h.Session + "/" + m.ID, TS: jsonl.ParseTS(m.Timestamp), Model: m.Model,
		Provider: "google", Session: h.Session, Sub: h.Kind != "" && h.Kind != "main",
		In: max(0, t.Input-t.Cached) + t.Tool, CR: t.Cached, Out: t.Output + t.Thoughts, Think: t.Thoughts,
		TQ: "none",
	}, true
}

// Scan emits req events for everything new since cur, and advances cur.
func Scan(ctx context.Context, e env.Env, cur *cursor.State, out *event.Emitter) error {
	root := filepath.Join(e.Home, ".gemini", "tmp")
	var files []string
	for _, pat := range []string{"session-*.jsonl", "session-*.json"} {
		m, _ := filepath.Glob(filepath.Join(root, "*", "chats", pat))
		files = append(files, m...)
	}
	since := e.Since.UnixMilli()
	byKey := map[string]event.Req{}
	malformed := 0
	for _, path := range files {
		if ctx.Err() != nil {
			break
		}
		p, ok := jsonl.PlanFile(cur, path, e.Since, e.Now)
		if !ok {
			continue
		}
		var reqs []event.Req
		var end int64
		var err error
		if strings.HasSuffix(path, ".json") {
			reqs, err = readJSON(path)
			end = p.Size
			if err != nil {
				malformed++
				continue
			}
		} else {
			reqs, end, malformed, err = readJSONL(cur, p, malformed)
			if err != nil {
				continue
			}
		}
		for _, r := range reqs {
			if r.TS < since {
				continue
			}
			if o, ok := byKey[r.Key]; ok {
				r.In, r.CR, r.Out, r.Think = max(r.In, o.In), max(r.CR, o.CR), max(r.Out, o.Out), max(r.Think, o.Think)
			}
			byKey[r.Key] = r
		}
		jsonl.Commit(cur, p, end)
	}
	reqs := make([]event.Req, 0, len(byKey))
	for _, r := range byKey {
		reqs = append(reqs, r)
	}
	sort.Slice(reqs, func(i, j int) bool {
		return reqs[i].TS < reqs[j].TS || reqs[i].TS == reqs[j].TS && reqs[i].Key < reqs[j].Key
	})
	for _, r := range reqs {
		out.Req(r)
	}
	if malformed > 0 {
		out.Log("info", tool, fmt.Sprintf("skipped %d malformed lines", malformed))
	}
	return ctx.Err()
}

func readJSONL(cur *cursor.State, p jsonl.Plan, malformed int) ([]event.Req, int64, int, error) {
	f, err := os.Open(p.Path)
	if err != nil {
		return nil, 0, malformed, err
	}
	defer f.Close()
	var h header
	if !p.Fresh {
		json.Unmarshal([]byte(cur.Val("gemini:"+p.Path)), &h)
	}
	if _, err := f.Seek(p.From, io.SeekStart); err != nil {
		return nil, 0, malformed, err
	}
	var reqs []event.Req
	end, err := jsonl.Lines(f, p.From, nil, markers, func(b []byte, _ int64) bool {
		if !jsonl.ContainsAny(b, markers) {
			return true
		}
		var m msg
		if json.Unmarshal(b, &m) != nil {
			malformed++
			return true
		}
		if m.SessionID != "" && m.Type == "" {
			h = header{Session: m.SessionID, Kind: m.Kind}
			return true
		}
		if r, ok := mkReq(h, m); ok {
			reqs = append(reqs, r)
		}
		return true
	})
	if hb, _ := json.Marshal(h); h.Session != "" {
		cur.SetVal("gemini:"+p.Path, string(hb))
	}
	return reqs, end, malformed, err
}

// readJSON reads the older single-document format.
func readJSON(path string) ([]event.Req, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var doc struct {
		SessionID string `json:"sessionId"`
		Kind      string `json:"kind"`
		Messages  []msg  `json:"messages"`
	}
	if err := json.NewDecoder(io.LimitReader(f, 512<<20)).Decode(&doc); err != nil {
		return nil, err
	}
	h := header{Session: doc.SessionID, Kind: doc.Kind}
	var reqs []event.Req
	for _, m := range doc.Messages {
		if r, ok := mkReq(h, m); ok {
			reqs = append(reqs, r)
		}
	}
	return reqs, nil
}

// Sessions: Gemini CLI keeps no session registry; nothing is emitted.
func Sessions(ctx context.Context, e env.Env, out *event.Emitter) error {
	return nil
}
