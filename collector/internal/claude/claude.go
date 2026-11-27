// Package claude reads usage written by Claude Code and Claude Desktop
// transcripts. See docs/collector-protocol.md and design/data-sources.md 3.1.
//
// A request (one message.id) is written as one assistant line per content
// block, sometimes with intermediate lines carrying partial usage, and the same
// request can be copied into several files (forks, resumes, subagent files,
// ssh-* mirrors). Lines are aggregated per message.id with the per-field maximum,
// first within a file and then across all files of the scan, and each id is
// emitted once per scan.
//
// Cursor: a file's offset is held back to the first line of any request that
// has not finished (no stop_reason yet) and is younger than jsonl.PendingGrace,
// and to any recent api-request or api_error record nothing has answered yet, so
// the next scan re-reads that request whole, with its timing and retry records.
package claude

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"tach/collector/internal/cursor"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
	"tach/collector/internal/jsonl"
)

const tool = "claude_code"

// Dirs resolves the Claude data locations for a home directory.
type Dirs struct {
	Config  string   // ~/.claude or $CLAUDE_CONFIG_DIR
	Account string   // ~/.claude.json (or $CLAUDE_CONFIG_DIR/.claude.json)
	Roots   []string // transcript roots
}

func dirs(e env.Env) Dirs {
	d := Dirs{Config: filepath.Join(e.Home, ".claude"), Account: filepath.Join(e.Home, ".claude.json")}
	if v := os.Getenv("CLAUDE_CONFIG_DIR"); v != "" {
		d.Config = v
		d.Account = filepath.Join(v, ".claude.json")
		if _, err := os.Stat(d.Account); err != nil {
			d.Account = filepath.Join(e.Home, ".claude.json")
		}
	}
	d.Roots = []string{filepath.Join(d.Config, "projects")}
	if runtime.GOOS == "darwin" {
		d.Roots = append(d.Roots, filepath.Join(e.Home, "Library", "Application Support", "Claude", "local-agent-mode-sessions"))
	}
	return d
}

var markers = [][]byte{
	[]byte(`"type":"assistant"`),
	[]byte(`"type":"api-request"`),
	[]byte(`"subtype":"api_error"`),
}

// ---- line decoding (narrow structs; content is never decoded) ----

type usage struct {
	Input         int64 `json:"input_tokens"`
	CacheCreate   int64 `json:"cache_creation_input_tokens"`
	CacheRead     int64 `json:"cache_read_input_tokens"`
	Output        int64 `json:"output_tokens"`
	OutputDetails struct {
		Thinking int64 `json:"thinking_tokens"`
	} `json:"output_tokens_details"`
	CacheCreation *struct {
		H1 int64 `json:"ephemeral_1h_input_tokens"`
		M5 int64 `json:"ephemeral_5m_input_tokens"`
	} `json:"cache_creation"`
	ServiceTier string `json:"service_tier"`
	Speed       string `json:"speed"`
}

type message struct {
	ID         string  `json:"id"`
	Model      string  `json:"model"`
	StopReason *string `json:"stop_reason"`
	Usage      *usage  `json:"usage"`
}

type line struct {
	Type        string `json:"type"`
	Subtype     string `json:"subtype"`
	Timestamp   string `json:"timestamp"`
	SessionID   string `json:"sessionId"`
	Cwd         string `json:"cwd"`
	IsSidechain bool   `json:"isSidechain"`
	AgentID     string `json:"agentId"`
	Entrypoint  string `json:"entrypoint"`
	Effort      string `json:"effort"`
	UUID        string `json:"uuid"`
	ParentUUID  string `json:"parentUuid"`
	RequestRef  string `json:"requestRef"`
	RequestID   string `json:"requestId"`
	ID          string `json:"id"` // api-request id

	ThinkingDurationMs *int64 `json:"thinkingDurationMs"`
	ToolInputStreamMs  *int64 `json:"toolInputStreamMs"`
	APIBlockIndex      *int   `json:"apiBlockIndex"`

	IsAPIErrorMessage bool `json:"isApiErrorMessage"`
	APIErrorStatus    int  `json:"apiErrorStatus"`
	QuotaLimits       *struct {
		Status        string `json:"status"`
		ResetsAt      int64  `json:"resetsAt"`
		RateLimitType string `json:"rateLimitType"`
	} `json:"quotaLimits"`

	RetryAttempt int `json:"retryAttempt"`

	Params *struct {
		Model        string `json:"model"`
		OutputConfig struct {
			Effort string `json:"effort"`
		} `json:"output_config"`
	} `json:"params"`

	Message *message `json:"message"`
}

// ---- per-request aggregate ----

type agg struct {
	key                         string
	model                       string
	in, cr, cc, cw1, cw5m, out  int64
	think                       int64
	firstTS, lastTS, lastStopTS int64
	stop                        string
	closed                      bool
	blockIdx                    int // lowest apiBlockIndex seen
	blockTS                     int64
	lead                        int64 // thinkingDurationMs / toolInputStreamMs of that block
	hasLead                     bool
	reqRef                      string
	effort, tier, speed, entry  string
	session, cwd                string
	sub, mirror                 bool
	retries                     int
	startTS                     int64 // api-request timestamp, 0 if unknown
	reqEffort                   string
	firstOff                    int64
	order                       int // file order of first sight, for stable output
	file                        string
}

func (a *agg) add(l *line, ts int64) {
	m := l.Message
	if a.model == "" {
		a.model = m.Model
	}
	if u := m.Usage; u != nil {
		a.in = max(a.in, u.Input)
		a.cr = max(a.cr, u.CacheRead)
		a.cc = max(a.cc, u.CacheCreate)
		a.out = max(a.out, u.Output)
		a.think = max(a.think, u.OutputDetails.Thinking)
		if u.CacheCreation != nil {
			a.cw1 = max(a.cw1, u.CacheCreation.H1)
			a.cw5m = max(a.cw5m, u.CacheCreation.M5)
		}
		if u.ServiceTier != "" {
			a.tier = u.ServiceTier
		}
		if u.Speed != "" {
			a.speed = u.Speed
		}
	}
	if a.firstTS == 0 || ts < a.firstTS {
		a.firstTS = ts
	}
	if ts > a.lastTS {
		a.lastTS = ts
	}
	if m.StopReason != nil && *m.StopReason != "" {
		a.closed = true
		a.stop = *m.StopReason
		if ts > a.lastStopTS {
			a.lastStopTS = ts
		}
	}
	idx := 0
	if l.APIBlockIndex != nil {
		idx = *l.APIBlockIndex
	}
	if a.blockTS == 0 || idx < a.blockIdx || idx == a.blockIdx && ts < a.blockTS {
		a.blockIdx, a.blockTS = idx, ts
		a.hasLead, a.lead = false, 0
		if l.ThinkingDurationMs != nil {
			a.hasLead, a.lead = true, *l.ThinkingDurationMs
		} else if l.ToolInputStreamMs != nil {
			a.hasLead, a.lead = true, *l.ToolInputStreamMs
		}
	}
	if l.RequestRef != "" {
		a.reqRef = l.RequestRef
	}
	if l.Effort != "" {
		a.effort = l.Effort
	}
	if l.Entrypoint != "" {
		a.entry = l.Entrypoint
	}
	if a.session == "" {
		a.session = l.SessionID
	}
	if a.cwd == "" {
		a.cwd = l.Cwd
	}
	if l.IsSidechain || l.AgentID != "" {
		a.sub = true
	}
}

// merge folds b (another copy of the same request) into a. Token counts take the
// per-field maximum; attributes come from the preferred copy.
func (a *agg) merge(b *agg) {
	if b.better(a) {
		if b.model != "" {
			a.model = b.model
		}
		a.firstTS, a.lastTS, a.lastStopTS, a.stop, a.closed = b.firstTS, b.lastTS, b.lastStopTS, b.stop, b.closed
		a.blockIdx, a.blockTS, a.lead, a.hasLead = b.blockIdx, b.blockTS, b.lead, b.hasLead
		a.reqRef, a.startTS, a.reqEffort = b.reqRef, b.startTS, b.reqEffort
		a.effort, a.tier, a.speed, a.entry = b.effort, b.tier, b.speed, b.entry
		a.session, a.cwd, a.sub, a.mirror = b.session, b.cwd, b.sub, b.mirror
		a.retries = max(a.retries, b.retries)
		a.order, a.file = b.order, b.file
	}
	a.in, a.cr, a.cc = max(a.in, b.in), max(a.cr, b.cr), max(a.cc, b.cc)
	a.cw1, a.cw5m = max(a.cw1, b.cw1), max(a.cw5m, b.cw5m)
	a.out, a.think = max(a.out, b.out), max(a.think, b.think)
	a.retries = max(a.retries, b.retries)
	if a.model == "" {
		a.model = b.model
	}
}

// better: a non-mirror copy beats a mirror, a copy with request timing beats one
// without, then the earlier copy wins.
func (a *agg) better(b *agg) bool {
	if a.mirror != b.mirror {
		return !a.mirror
	}
	if (a.startTS != 0) != (b.startTS != 0) {
		return a.startTS != 0
	}
	if a.firstTS != b.firstTS {
		return a.firstTS < b.firstTS
	}
	return a.file < b.file
}

func (a *agg) req(acct string) event.Req {
	r := event.Req{
		Tool: tool, Key: a.key, TS: a.lastTS, Model: a.model,
		Session: a.session, Cwd: a.cwd, Sub: a.sub, Mirror: a.mirror,
		In: a.in, CR: a.cr, Out: a.out, Think: a.think,
		Stop: a.stop, Retries: a.retries, Tier: a.tier, Speed: a.speed, Effort: a.effort, TQ: "none",
	}
	if r.Effort == "" {
		r.Effort = a.reqEffort
	}
	// Cache writes: use the TTL split; anything not covered by it counts as 5m.
	r.CW1 = a.cw1
	r.CW5 = max(a.cw5m, a.cc-a.cw1)
	if strings.HasPrefix(a.model, "claude-") {
		r.Provider = "anthropic"
		if !strings.HasSuffix(a.entry, "-3p") {
			r.Pool = "claude"
			r.Acct = acct
		}
	} else {
		r.Provider = "other"
	}
	if a.startTS > 0 {
		end := a.lastTS
		if a.lastStopTS > 0 {
			end = a.lastStopTS
			r.TS = end
		}
		if d := end - a.startTS; d >= 0 {
			r.Dur = &d
			r.TQ = "est"
			if a.hasLead {
				if t := a.blockTS - a.lead - a.startTS; t >= 0 && t <= d {
					r.TTFT = &t
				}
			}
		}
	}
	return r
}

// ---- file parsing ----

type limitRec struct {
	ts    int64
	typ   string
	reset int64
	rej   bool
}

type fileResult struct {
	reqs   []*agg
	limits []limitRec
	end    int64 // cursor offset to commit
	stats  jsonl.Stats
}

type pendingRef struct {
	off int64
	ts  int64
}

// parseFile reads p from p.From and aggregates its requests. now bounds what
// still counts as "in flight".
func parseFile(p jsonl.Plan, mirror, sub bool, now time.Time) (fileResult, error) {
	var res fileResult
	f, err := os.Open(p.Path)
	if err != nil {
		return res, err
	}
	defer f.Close()
	if _, err := f.Seek(p.From, 0); err != nil {
		return res, err
	}
	byID := map[string]*agg{}
	var order []*agg
	apiReq := map[string]pendingRef{} // api-request id -> start
	apiReqEffort := map[string]string{}
	used := map[string]bool{} // api-request ids / api_error uuids answered
	apiErr := map[string]int{}
	apiErrAt := map[string]pendingRef{}
	type pendingAssistant struct {
		a   *agg
		ref string
		par string
	}
	var links []pendingAssistant

	end, err := jsonl.Lines(f, p.From, &res.stats, markers, func(b []byte, at int64) bool {
		if !jsonl.ContainsAny(b, markers) {
			return true
		}
		var l line
		if err := json.Unmarshal(b, &l); err != nil {
			res.stats.Malformed++
			return true
		}
		res.stats.Parsed++
		ts := jsonl.ParseTS(l.Timestamp)
		switch l.Type {
		case "api-request":
			if l.ID != "" {
				apiReq[l.ID] = pendingRef{off: at, ts: ts}
				if l.Params != nil {
					apiReqEffort[l.ID] = l.Params.OutputConfig.Effort
				}
			}
		case "system":
			if l.Subtype == "api_error" && l.UUID != "" {
				apiErr[l.UUID] = l.RetryAttempt
				apiErrAt[l.UUID] = pendingRef{off: at, ts: ts}
				if l.ParentUUID != "" {
					used[l.ParentUUID] = true
				}
			}
		case "assistant":
			if l.Message == nil {
				return true
			}
			if l.RequestRef != "" {
				used[l.RequestRef] = true
			}
			if l.ParentUUID != "" {
				used[l.ParentUUID] = true
			}
			if l.QuotaLimits != nil && l.QuotaLimits.RateLimitType != "" {
				res.limits = append(res.limits, limitRec{ts: ts, typ: l.QuotaLimits.RateLimitType,
					reset: l.QuotaLimits.ResetsAt, rej: l.QuotaLimits.Status == "rejected"})
			}
			m := l.Message
			if m.Model == "<synthetic>" || l.IsAPIErrorMessage || m.ID == "" {
				return true
			}
			a := byID[m.ID]
			if a == nil {
				a = &agg{key: m.ID, firstOff: at, blockIdx: 1 << 30, mirror: mirror, sub: sub, file: p.Path}
				byID[m.ID] = a
				order = append(order, a)
			}
			a.add(&l, ts)
			links = append(links, pendingAssistant{a: a, ref: l.RequestRef, par: l.ParentUUID})
		}
		return true
	})
	res.end = end
	if err != nil {
		return res, err
	}
	for _, k := range links {
		if s, ok := apiReq[k.ref]; ok && k.a.startTS == 0 {
			k.a.startTS = s.ts
			k.a.reqEffort = apiReqEffort[k.ref]
			if s.off < k.a.firstOff {
				k.a.firstOff = s.off
			}
		}
		if n, ok := apiErr[k.par]; ok {
			k.a.retries = max(k.a.retries, n)
			if e := apiErrAt[k.par]; e.off < k.a.firstOff {
				k.a.firstOff = e.off
			}
		}
	}
	// Hold the cursor back for anything still in flight.
	cut := now.Add(-jsonl.PendingGrace).UnixMilli()
	hold := res.end
	for _, a := range order {
		if !a.closed && a.lastTS >= cut {
			hold = min(hold, a.firstOff)
			continue
		}
		res.reqs = append(res.reqs, a)
	}
	for id, s := range apiReq {
		if !used[id] && s.ts >= cut {
			hold = min(hold, s.off)
		}
	}
	for id, s := range apiErrAt {
		if !used[id] && s.ts >= cut {
			hold = min(hold, s.off)
		}
	}
	if hold < res.end {
		// Requests that start at or after the hold point are re-read next time.
		kept := res.reqs[:0]
		for _, a := range res.reqs {
			if a.firstOff < hold {
				kept = append(kept, a)
			}
		}
		res.reqs = kept
	}
	res.end = hold
	return res, nil
}

// ---- Scan ----

func readAcct(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var v struct {
		OAuthAccount struct {
			AccountUUID string `json:"accountUuid"`
		} `json:"oauthAccount"`
	}
	if json.Unmarshal(b, &v) != nil {
		return ""
	}
	return jsonl.AcctHash(v.OAuthAccount.AccountUUID)
}

type fileKind struct{ mirror, sub bool }

func walk(roots []string) map[string]fileKind {
	out := map[string]fileKind{}
	for i, root := range roots {
		filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				return nil
			}
			name := d.Name()
			if !strings.HasSuffix(name, ".jsonl") || name == "audit.jsonl" {
				return nil
			}
			rel, _ := filepath.Rel(root, path)
			k := fileKind{}
			if i == 0 && strings.HasPrefix(rel, "ssh-") {
				k.mirror = true
			}
			if strings.Contains(filepath.ToSlash(rel), "/subagents/") {
				k.sub = true
			}
			out[path] = k
			return nil
		})
	}
	return out
}

// Stats from the last Scan, for diagnostics and tests.
var LastStats jsonl.Stats

// Scan emits req/limit events for everything new since cur, and advances cur.
func Scan(ctx context.Context, e env.Env, cur *cursor.State, out *event.Emitter) error {
	d := dirs(e)
	acct := readAcct(d.Account)
	files := walk(d.Roots)
	var plans []jsonl.Plan
	for path := range files {
		if p, ok := jsonl.PlanFile(cur, path, e.Since, e.Now); ok {
			plans = append(plans, p)
		}
	}
	var mu sync.Mutex
	merged := map[string]*agg{}
	var limits []limitRec
	var stats jsonl.Stats
	var errs []string
	order := 0
	jsonl.Parallel(plans, func(p jsonl.Plan) {
		if ctx.Err() != nil {
			return
		}
		k := files[p.Path]
		res, err := parseFile(p, k.mirror, k.sub, e.Now)
		stats.Add(res.stats)
		if err != nil {
			mu.Lock()
			errs = append(errs, fmt.Sprintf("%s: %v", filepath.Base(p.Path), err))
			mu.Unlock()
			return
		}
		mu.Lock()
		for _, a := range res.reqs {
			if a.lastTS < e.Since.UnixMilli() {
				continue
			}
			if m := merged[a.key]; m != nil {
				m.merge(a)
			} else {
				order++
				a.order = order
				merged[a.key] = a
			}
		}
		limits = append(limits, res.limits...)
		mu.Unlock()
		jsonl.Commit(cur, p, res.end)
	})
	LastStats = stats
	reqs := make([]*agg, 0, len(merged))
	for _, a := range merged {
		reqs = append(reqs, a)
	}
	sort.Slice(reqs, func(i, j int) bool {
		if reqs[i].lastTS != reqs[j].lastTS {
			return reqs[i].lastTS < reqs[j].lastTS
		}
		return reqs[i].key < reqs[j].key
	})
	for _, a := range reqs {
		out.Req(a.req(acct))
	}
	emitLimits(limits, acct, e, out)
	if stats.Malformed > 0 || stats.Oversized > 0 {
		out.Log("info", tool, fmt.Sprintf("skipped %d malformed and %d oversized lines", stats.Malformed, stats.Oversized))
	}
	if len(errs) > 0 {
		out.Log("warn", tool, fmt.Sprintf("%d files unreadable, first: %s", len(errs), errs[0]))
	}
	if e.Verbose {
		fmt.Fprintf(os.Stderr, "claude: %d files, %d to read, %d MB, %d lines, %d parsed, %d reqs\n",
			len(files), len(plans), stats.Bytes>>20, stats.Lines, stats.Parsed, len(reqs))
	}
	return ctx.Err()
}

func window(typ string) (id, kind, label string, length int64) {
	switch {
	case typ == "five_hour":
		return "five_hour", "session", "5-hour", 5 * 3600
	case typ == "seven_day" || strings.HasPrefix(typ, "seven_day_overage"):
		return "weekly", "weekly", "Week", 7 * 86400
	case strings.HasPrefix(typ, "seven_day_"):
		slug := strings.TrimPrefix(typ, "seven_day_")
		return "weekly:" + slug, "weekly_scoped", strings.ToUpper(slug[:1]) + slug[1:], 7 * 86400
	}
	return typ, "session", typ, 0
}

func emitLimits(ls []limitRec, acct string, e env.Env, out *event.Emitter) {
	var evs []event.Limit
	for _, l := range ls {
		if l.ts < e.Since.UnixMilli() {
			continue
		}
		id, kind, label, length := window(l.typ)
		used := 100.0
		ev := event.Limit{Provider: "claude", Acct: acct, Window: id, Kind: kind, Label: label,
			Used: &used, Len: length, Limited: l.rej, TS: l.ts, Src: "transcript"}
		if l.reset > 0 {
			r := l.reset * 1000
			ev.Resets = &r
		}
		evs = append(evs, ev)
	}
	evs = jsonl.Thin(evs, func(l event.Limit) string { return l.Window }, func(l event.Limit) int64 { return l.TS })
	for _, l := range evs {
		out.Limit(l)
	}
}

// ---- Sessions ----

type sessionFile struct {
	PID       int    `json:"pid"`
	SessionID string `json:"sessionId"`
	Cwd       string `json:"cwd"`
	StartedAt int64  `json:"startedAt"`
	UpdatedAt int64  `json:"updatedAt"`
	Status    string `json:"status"`
}

func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// Sessions emits one session event per live Claude Code session, plus sessions
// whose process has gone but which were updated in the last 30 minutes (idle).
func Sessions(ctx context.Context, e env.Env, out *event.Emitter) error {
	d := dirs(e)
	ents, err := os.ReadDir(filepath.Join(d.Config, "sessions"))
	if err != nil {
		return nil
	}
	recent := e.Now.Add(-30 * time.Minute).UnixMilli()
	for _, ent := range ents {
		if !strings.HasSuffix(ent.Name(), ".json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(d.Config, "sessions", ent.Name()))
		if err != nil {
			continue
		}
		var s sessionFile
		if json.Unmarshal(b, &s) != nil || s.SessionID == "" {
			continue
		}
		live := alive(s.PID)
		if !live && s.UpdatedAt < recent {
			continue
		}
		ev := event.Session{Tool: tool, ID: s.SessionID, Cwd: s.Cwd, Status: s.Status,
			Started: s.StartedAt, Updated: s.UpdatedAt}
		if !live || ev.Status != "busy" {
			ev.Status = "idle"
		}
		if m, tok := lastUsage(d.Roots[0], s.SessionID); m != "" {
			ev.Model = m
			ev.Tokens = tok
		}
		out.Session(ev)
	}
	return nil
}

// lastUsage finds the session's transcript and returns the model and context size
// (input incl. cache + output) of its newest request. The context window size is
// not in the logs, so no fill percentage is derived.
func lastUsage(projects, sessionID string) (string, int64) {
	matches, _ := filepath.Glob(filepath.Join(projects, "*", sessionID+".jsonl"))
	if len(matches) == 0 {
		return "", 0
	}
	b, err := jsonl.Tail(matches[0], 2<<20)
	if err != nil {
		return "", 0
	}
	for len(b) > 0 {
		i := bytes.LastIndexByte(b[:len(b)-1], '\n')
		ln := b[i+1:]
		b = b[:i+1]
		if !bytes.Contains(ln, markers[0]) {
			if i < 0 {
				break
			}
			continue
		}
		var l line
		if json.Unmarshal(ln, &l) == nil && l.Type == "assistant" && l.Message != nil && l.Message.Usage != nil && l.Message.Model != "<synthetic>" {
			u := l.Message.Usage
			return l.Message.Model, u.Input + u.CacheRead + u.CacheCreate + u.Output
		}
		if i < 0 {
			break
		}
	}
	return "", 0
}
