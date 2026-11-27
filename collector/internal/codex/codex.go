// Package codex reads usage written by Codex (CLI and Desktop) rollouts. See
// docs/collector-protocol.md and design/data-sources.md 3.4.
//
// Live rollouts (sessions/**/rollout-*.jsonl) are tailed by byte offset; the
// per-file parse state (thread, model, effort, tier, replay boundary, ...) lives
// in the cursor's KV so a scan can resume mid-file. Archives
// (archived_sessions/*.jsonl.zst) are immutable and read once; when an archive is
// the compressed copy of a rollout already read live, reading resumes at the
// live file's offset instead of replaying it.
package codex

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/klauspost/compress/zstd"

	"tach/collector/internal/cursor"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
	"tach/collector/internal/jsonl"
)

const tool = "codex"

func home(e env.Env) string {
	if v := os.Getenv("CODEX_HOME"); v != "" {
		return v
	}
	return filepath.Join(e.Home, ".codex")
}

var markers = [][]byte{
	[]byte(`"type":"session_meta"`),
	[]byte(`"type":"turn_context"`),
	[]byte(`"type":"token_usage_record"`),
	[]byte(`"type":"token_count"`),
	[]byte(`"type":"task_started"`),
	[]byte(`"type":"task_complete"`),
	[]byte(`"type":"thread_settings_applied"`),
	[]byte(`"type":"turn_aborted"`),
}

// ---- narrow record structs ----

type tokens struct {
	Input     int64 `json:"input_tokens"`
	Cached    int64 `json:"cached_input_tokens"`
	CacheW    int64 `json:"cache_write_input_tokens"`
	Output    int64 `json:"output_tokens"`
	Reasoning int64 `json:"reasoning_output_tokens"`
	Total     int64 `json:"total_tokens"`
}

type window struct {
	Used     float64 `json:"used_percent"`
	Minutes  int64   `json:"window_minutes"`
	ResetsAt int64   `json:"resets_at"`
}

type payload struct {
	Type string `json:"type"`

	// session_meta
	ID           string `json:"id"`
	Cwd          string `json:"cwd"`
	ThreadSource string `json:"thread_source"`
	HistoryStart *int64 `json:"subagent_history_start_ordinal"`

	// turn_context
	Model  string `json:"model"`
	Effort string `json:"effort"`

	// thread_settings_applied
	ThreadSettings *struct {
		Model       string `json:"model"`
		Effort      string `json:"reasoning_effort"`
		ServiceTier string `json:"service_tier"`
	} `json:"thread_settings"`

	// token_usage_record
	ThreadID   string  `json:"thread_id"`
	TurnID     string  `json:"turn_id"`
	ResponseID string  `json:"response_id"`
	Usage      *tokens `json:"usage"`
	TurnUsage  *tokens `json:"turn_token_usage"`

	// token_count
	Info *struct {
		Total  *tokens `json:"total_token_usage"`
		Last   *tokens `json:"last_token_usage"`
		Window int64   `json:"model_context_window"`
	} `json:"info"`
	RateLimits *struct {
		LimitID     string  `json:"limit_id"`
		LimitName   *string `json:"limit_name"`
		PlanType    string  `json:"plan_type"`
		Primary     *window `json:"primary"`
		Secondary   *window `json:"secondary"`
		ReachedType *string `json:"rate_limit_reached_type"`
	} `json:"rate_limits"`

	// task_complete
	CompletedAt *int64 `json:"completed_at"`
	DurationMs  *int64 `json:"duration_ms"`
	TTFTMs      *int64 `json:"time_to_first_token_ms"`
}

type record struct {
	Timestamp string   `json:"timestamp"`
	Ordinal   *int64   `json:"ordinal"`
	Type      string   `json:"type"`
	Payload   *payload `json:"payload"`
}

// state is what a scan needs to resume a rollout mid-file. Stored as JSON in the
// cursor KV under "codex:" + path.
type state struct {
	Meta    bool   `json:"meta,omitempty"`   // own session_meta seen
	Thread  string `json:"thread,omitempty"` // own thread id
	Src     string `json:"src,omitempty"`    // thread_source
	Start   int64  `json:"start,omitempty"`  // replayed history ends before this ordinal
	Cwd     string `json:"cwd,omitempty"`
	Model   string `json:"model,omitempty"`
	Effort  string `json:"effort,omitempty"`
	Tier    string `json:"tier,omitempty"`
	TUR     bool   `json:"tur,omitempty"`     // file has token_usage_record (new format)
	Total   int64  `json:"total,omitempty"`   // last cumulative total (old format dedupe)
	Turn    string `json:"turn,omitempty"`    // current turn id
	TurnOut int64  `json:"turnout,omitempty"` // output tokens so far in the current turn
	CtxWin  int64  `json:"ctxwin,omitempty"`
	Lines   int64  `json:"lines,omitempty"` // records seen, fallback ordinal
}

func (s *state) sub() bool { return s.Src == "subagent" || s.Src == "guardian_review" }

type auth struct {
	pool string
	acct string
}

func readAuth(dir string) auth {
	b, err := os.ReadFile(filepath.Join(dir, "auth.json"))
	if err != nil {
		return auth{}
	}
	var v struct {
		AuthMode string `json:"auth_mode"`
		Tokens   struct {
			AccountID string `json:"account_id"`
		} `json:"tokens"`
	}
	if json.Unmarshal(b, &v) != nil {
		return auth{}
	}
	a := auth{acct: jsonl.AcctHash(v.Tokens.AccountID)}
	if v.AuthMode == "chatgpt" {
		a.pool = "openai"
	}
	return a
}

// ---- parsing ----

type result struct {
	reqs   []event.Req
	turns  []event.Turn
	limits []event.Limit
	end    int64
	st     state
	stats  jsonl.Stats
}

// parse consumes records from r (positioned at byte off of the logical stream)
// and appends events to res. since filters by event time.
func parse(r io.Reader, off int64, st state, a auth, since int64, res *result) error {
	end, err := jsonl.Lines(r, off, &res.stats, markers, func(b []byte, at int64) bool {
		st.Lines++
		if !jsonl.ContainsAny(b, markers) {
			return true
		}
		var rec record
		if err := json.Unmarshal(b, &rec); err != nil {
			res.stats.Malformed++
			return true
		}
		res.stats.Parsed++
		p := rec.Payload
		if p == nil {
			return true
		}
		ord := int64(-1)
		if rec.Ordinal != nil {
			ord = *rec.Ordinal
		}
		if rec.Type == "session_meta" {
			if !st.Meta { // the file's own meta comes first; later ones are replayed parents
				st.Meta = true
				st.Thread, st.Src, st.Cwd = p.ID, p.ThreadSource, p.Cwd
				if p.HistoryStart != nil {
					st.Start = *p.HistoryStart
				}
			}
			return true
		}
		if st.Start > 0 && ord >= 0 && ord < st.Start {
			return true // parent history replayed into a forked / subagent thread
		}
		ts := jsonl.ParseTS(rec.Timestamp)
		switch rec.Type {
		case "turn_context":
			if p.TurnID != "" && p.TurnID != st.Turn {
				st.Turn, st.TurnOut = p.TurnID, 0
			}
			if p.Model != "" {
				st.Model = p.Model
			}
			if p.Effort != "" {
				st.Effort = p.Effort
			}
			if p.Cwd != "" {
				st.Cwd = p.Cwd
			}
		case "token_usage_record":
			st.TUR = true
			if p.Usage == nil {
				return true
			}
			key := p.ResponseID
			if key == "" {
				key = fallbackKey(st, p.ThreadID, ord, at)
			}
			if p.TurnID != st.Turn {
				st.Turn, st.TurnOut = p.TurnID, 0
			}
			if p.TurnUsage != nil {
				st.TurnOut = max(st.TurnOut, p.TurnUsage.Output)
			} else {
				st.TurnOut += p.Usage.Output
			}
			if ts >= since {
				res.reqs = append(res.reqs, mkReq(key, ts, *p.Usage, st, a))
			}
		case "event_msg":
			switch p.Type {
			case "thread_settings_applied":
				if s := p.ThreadSettings; s != nil {
					if s.ServiceTier != "" {
						st.Tier = s.ServiceTier
					}
					if s.Model != "" && st.Model == "" {
						st.Model = s.Model
					}
					if s.Effort != "" && st.Effort == "" {
						st.Effort = s.Effort
					}
				}
			case "task_started":
				if p.TurnID != "" && p.TurnID != st.Turn {
					st.Turn, st.TurnOut = p.TurnID, 0
				}
			case "token_count":
				if i := p.Info; i != nil {
					if i.Window > 0 {
						st.CtxWin = i.Window
					}
					// Old rollouts: no token_usage_record. Use last_token_usage of each
					// token_count whose cumulative total moved; never sum totals.
					if !st.TUR && i.Last != nil && i.Total != nil && i.Total.Total != st.Total {
						st.Total = i.Total.Total
						st.TurnOut += i.Last.Output
						if ts >= since && i.Last.Total > 0 {
							res.reqs = append(res.reqs, mkReq(fallbackKey(st, st.Thread, ord, at), ts, *i.Last, st, a))
						}
					}
				}
				if rl := p.RateLimits; rl != nil && ts >= since {
					res.limits = append(res.limits, limitsOf(rl, ts, a)...)
				}
			case "task_complete":
				t := event.Turn{Tool: tool, Key: p.TurnID, TS: ts, Model: st.Model, Dur: p.DurationMs, TTFT: p.TTFTMs, Status: "completed"}
				if p.CompletedAt != nil && *p.CompletedAt > 0 {
					t.TS = *p.CompletedAt * 1000
				}
				if p.TurnID == st.Turn {
					t.Out = st.TurnOut
				}
				if t.Key != "" && ts >= since {
					res.turns = append(res.turns, t)
				}
			}
		}
		return true
	})
	res.end = end
	res.st = st
	return err
}

func fallbackKey(st state, thread string, ord, at int64) string {
	if thread == "" {
		thread = st.Thread
	}
	if ord >= 0 {
		return fmt.Sprintf("%s/%d", thread, ord)
	}
	return fmt.Sprintf("%s/@%d", thread, at)
}

func mkReq(key string, ts int64, u tokens, st state, a auth) event.Req {
	return event.Req{
		Tool: tool, Key: key, TS: ts, Model: st.Model, Provider: "openai", Pool: a.pool, Acct: a.acct,
		Session: st.Thread, Cwd: st.Cwd, Sub: st.sub(),
		In: max(0, u.Input-u.Cached), CR: u.Cached, CW5: u.CacheW, Out: u.Output, Think: u.Reasoning,
		TQ: "none", Tier: st.Tier, Effort: st.Effort,
	}
}

func titleCase(s string) string {
	if s == "" {
		return ""
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

func limitsOf(rl *struct {
	LimitID     string  `json:"limit_id"`
	LimitName   *string `json:"limit_name"`
	PlanType    string  `json:"plan_type"`
	Primary     *window `json:"primary"`
	Secondary   *window `json:"secondary"`
	ReachedType *string `json:"rate_limit_reached_type"`
}, ts int64, a auth) []event.Limit {
	var out []event.Limit
	scoped := rl.LimitID != "" && rl.LimitID != "codex"
	for _, w := range []*window{rl.Primary, rl.Secondary} {
		if w == nil || w.Minutes <= 0 {
			continue
		}
		l := event.Limit{Provider: "openai", Acct: a.acct, Plan: titleCase(rl.PlanType), Len: w.Minutes * 60, TS: ts, Src: "rollout"}
		used := w.Used
		l.Used = &used
		if w.ResetsAt > 0 {
			r := w.ResetsAt * 1000
			l.Resets = &r
		}
		l.Limited = rl.ReachedType != nil && *rl.ReachedType != "" || used >= 100
		switch {
		case scoped:
			l.Window, l.Kind = "weekly:"+rl.LimitID, "weekly_scoped"
			l.Label = rl.LimitID
			if rl.LimitName != nil && *rl.LimitName != "" {
				l.Label = *rl.LimitName
			}
		case w.Minutes <= 360:
			l.Window, l.Kind, l.Label = "five_hour", "session", "5-hour"
		default:
			l.Window, l.Kind, l.Label = "weekly", "weekly", "Week"
		}
		out = append(out, l)
	}
	return out
}

// ---- Scan ----

func loadState(cur *cursor.State, path string) state {
	var s state
	if v := cur.Val("codex:" + path); v != "" {
		json.Unmarshal([]byte(v), &s)
	}
	return s
}

func saveState(cur *cursor.State, path string, s state) {
	b, _ := json.Marshal(s)
	cur.SetVal("codex:"+path, string(b))
}

// liveTwin maps an archive name to where the live rollout lived:
// rollout-2026-11-15T16-13-46-<id>.jsonl.zst -> sessions/2026/11/15/rollout-....jsonl
func liveTwin(dir, archive string) string {
	base := strings.TrimSuffix(filepath.Base(archive), ".zst")
	if len(base) < len("rollout-2026-11-15") || !strings.HasPrefix(base, "rollout-") {
		return ""
	}
	d := base[len("rollout-"):]
	return filepath.Join(dir, "sessions", d[0:4], d[5:7], d[8:10], base)
}

var LastStats jsonl.Stats

// Scan emits req/turn/limit events for everything new since cur, and advances cur.
func Scan(ctx context.Context, e env.Env, cur *cursor.State, out *event.Emitter) error {
	dir := home(e)
	a := readAuth(dir)
	var plans []jsonl.Plan
	filepath.WalkDir(filepath.Join(dir, "sessions"), func(path string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasPrefix(d.Name(), "rollout-") && strings.HasSuffix(d.Name(), ".jsonl") {
			if p, ok := jsonl.PlanFile(cur, path, e.Since, e.Now); ok {
				plans = append(plans, p)
			}
		}
		return nil
	})
	arch, _ := filepath.Glob(filepath.Join(dir, "archived_sessions", "*.jsonl.zst"))
	for _, path := range arch {
		p, ok := jsonl.PlanFile(cur, path, e.Since, e.Now)
		if !ok || !p.Fresh && p.From >= p.Size {
			continue
		}
		p.From = 0 // compressed: offsets in the cursor mean "done", never a resume point
		plans = append(plans, p)
	}
	// Also plain archived .jsonl, if a version writes them uncompressed.
	plain, _ := filepath.Glob(filepath.Join(dir, "archived_sessions", "*.jsonl"))
	for _, path := range plain {
		if p, ok := jsonl.PlanFile(cur, path, e.Since, e.Now); ok {
			plans = append(plans, p)
		}
	}

	var mu sync.Mutex
	var all result
	var errs []string
	since := e.Since.UnixMilli()
	jsonl.Parallel(plans, func(p jsonl.Plan) {
		if ctx.Err() != nil {
			return
		}
		res, err := scanFile(dir, cur, p, a, since)
		mu.Lock()
		defer mu.Unlock()
		all.stats.Lines += res.stats.Lines
		all.stats.Parsed += res.stats.Parsed
		all.stats.Malformed += res.stats.Malformed
		all.stats.Oversized += res.stats.Oversized
		all.stats.Bytes += res.stats.Bytes
		if err != nil {
			errs = append(errs, fmt.Sprintf("%s: %v", filepath.Base(p.Path), err))
			return
		}
		all.reqs = append(all.reqs, res.reqs...)
		all.turns = append(all.turns, res.turns...)
		all.limits = append(all.limits, res.limits...)
	})
	LastStats = all.stats

	// One event per key within the scan (an archive and its live twin, or a
	// re-read tail, can yield the same response twice).
	sort.SliceStable(all.reqs, func(i, j int) bool { return all.reqs[i].TS < all.reqs[j].TS })
	seen := map[string]int{}
	for _, r := range all.reqs {
		if i, ok := seen[r.Key]; ok {
			_ = i
			continue
		}
		seen[r.Key] = 1
		out.Req(r)
	}
	sort.SliceStable(all.turns, func(i, j int) bool { return all.turns[i].TS < all.turns[j].TS })
	seenT := map[string]bool{}
	for _, t := range all.turns {
		if !seenT[t.Key] {
			seenT[t.Key] = true
			out.Turn(t)
		}
	}
	for _, l := range jsonl.Thin(all.limits, func(l event.Limit) string { return l.Window }, func(l event.Limit) int64 { return l.TS }) {
		out.Limit(l)
	}
	if all.stats.Malformed > 0 || all.stats.Oversized > 0 {
		out.Log("info", tool, fmt.Sprintf("skipped %d malformed and %d oversized lines", all.stats.Malformed, all.stats.Oversized))
	}
	if len(errs) > 0 {
		out.Log("warn", tool, fmt.Sprintf("%d files unreadable, first: %s", len(errs), errs[0]))
	}
	if e.Verbose {
		fmt.Fprintf(os.Stderr, "codex: %d files to read, %d MB, %d lines, %d parsed, %d reqs, %d turns, %d limits\n",
			len(plans), all.stats.Bytes>>20, all.stats.Lines, all.stats.Parsed, len(seen), len(seenT), len(all.limits))
	}
	return ctx.Err()
}

func scanFile(dir string, cur *cursor.State, p jsonl.Plan, a auth, since int64) (result, error) {
	var res result
	f, err := os.Open(p.Path)
	if err != nil {
		return res, err
	}
	defer f.Close()
	if strings.HasSuffix(p.Path, ".zst") {
		zr, err := zstd.NewReader(f, zstd.WithDecoderConcurrency(1), zstd.WithDecoderLowmem(true))
		if err != nil {
			return res, err
		}
		defer zr.Close()
		var r io.Reader = zr
		st := state{}
		var skip int64
		if twin := liveTwin(dir, p.Path); twin != "" {
			if tf, ok := cur.Get(twin); ok && tf.Off > 0 {
				if _, err := os.Stat(twin); err != nil { // the live file was archived
					skip = tf.Off
					st = loadState(cur, twin)
				}
			}
		}
		if skip > 0 {
			if n, err := io.CopyN(io.Discard, zr, skip); err != nil || n != skip {
				skip, st = 0, state{} // archive differs from what we read live: start over
				f.Seek(0, 0)
				zr.Reset(f)
			}
		}
		err = parse(r, skip, st, a, since, &res)
		if err != nil {
			return res, err
		}
		jsonl.Commit(cur, p, p.Size)
		return res, nil
	}
	st := state{}
	if !p.Fresh {
		st = loadState(cur, p.Path)
	}
	if _, err := f.Seek(p.From, 0); err != nil {
		return res, err
	}
	if err := parse(f, p.From, st, a, since, &res); err != nil {
		return res, err
	}
	saveState(cur, p.Path, res.st)
	jsonl.Commit(cur, p, res.end)
	return res, nil
}

// ---- Sessions ----

// Sessions infers live Codex threads from rollouts modified in the last 30
// minutes (Codex keeps no session registry). A thread is busy when its last turn
// has started and not completed or been aborted.
func Sessions(ctx context.Context, e env.Env, out *event.Emitter) error {
	dir := home(e)
	recent := e.Now.Add(-30 * time.Minute).UnixMilli()
	filepath.WalkDir(filepath.Join(dir, "sessions"), func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasPrefix(d.Name(), "rollout-") || !strings.HasSuffix(d.Name(), ".jsonl") {
			return nil
		}
		fi, err := d.Info()
		if err != nil || fi.ModTime().UnixMilli() < recent {
			return nil
		}
		if s, ok := session(path, fi.ModTime().UnixMilli()); ok {
			out.Session(s)
		}
		return nil
	})
	return nil
}

func session(path string, mtime int64) (event.Session, bool) {
	s := event.Session{Tool: tool, Updated: mtime, Status: "idle"}
	// Own session_meta is the first line.
	if f, err := os.Open(path); err == nil {
		jsonl.Lines(io.LimitReader(f, 4<<20), 0, nil, nil, func(b []byte, _ int64) bool {
			var rec record
			if json.Unmarshal(b, &rec) == nil && rec.Type == "session_meta" && rec.Payload != nil {
				s.ID, s.Cwd = rec.Payload.ID, rec.Payload.Cwd
				s.Started = jsonl.ParseTS(rec.Timestamp)
			}
			return false
		})
		f.Close()
	}
	if s.ID == "" {
		return s, false
	}
	b, err := jsonl.Tail(path, 4<<20)
	if err != nil {
		return s, false
	}
	var win, last int64
	jsonl.Lines(bytes.NewReader(b), 0, nil, markers, func(ln []byte, _ int64) bool {
		if !jsonl.ContainsAny(ln, markers) {
			return true
		}
		var rec record
		if json.Unmarshal(ln, &rec) != nil || rec.Payload == nil {
			return true
		}
		p := rec.Payload
		switch {
		case rec.Type == "turn_context" && p.Model != "":
			s.Model = p.Model
		case p.Type == "task_started":
			s.Status = "busy"
		case p.Type == "task_complete", p.Type == "turn_aborted":
			s.Status = "idle"
		case p.Type == "token_count" && p.Info != nil:
			if p.Info.Window > 0 {
				win = p.Info.Window
			}
			if p.Info.Last != nil {
				last = p.Info.Last.Total
			}
		}
		return true
	})
	if win > 0 && last > 0 {
		s.Ctx = float64(last) * 100 / float64(win)
		s.Tokens = last
	}
	return s, true
}
