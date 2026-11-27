// Package event defines the NDJSON records the collector writes to stdout.
// The contract is documented in docs/collector-protocol.md; keep the two in step.
package event

import (
	"bufio"
	"encoding/json"
	"io"
	"sync"
)

// Req is one model request (kind "req").
type Req struct {
	K        string `json:"k"`
	Tool     string `json:"tool"`           // claude_code | codex | antigravity | gemini_cli
	Key      string `json:"key"`            // dedupe key, unique within tool across machines
	TS       int64  `json:"ts"`             // unix ms, request completion
	Model    string `json:"model"`          // exact model id as logged
	Name     string `json:"name,omitempty"` // the model's display name as the tool shows it, when the log has one
	Provider string `json:"provider"`       // anthropic | openai | google | other
	Pool     string `json:"pool,omitempty"` // subscription pool it counts toward: claude | openai | gemini | gemini_3p; empty = none
	Acct     string `json:"acct,omitempty"` // short hash of the account id, when known
	Session  string `json:"session,omitempty"`
	Cwd      string `json:"cwd,omitempty"`
	Sub      bool   `json:"sub,omitempty"`    // subagent / sidechain request
	Mirror   bool   `json:"mirror,omitempty"` // read from a local mirror of a session that ran on another machine
	In       int64  `json:"in"`               // uncached input tokens
	CR       int64  `json:"cr"`               // cache-read input tokens
	CW5      int64  `json:"cw5"`              // cache-write tokens, 5-minute (or unspecified) TTL
	CW1      int64  `json:"cw1"`              // cache-write tokens, 1-hour TTL
	Out      int64  `json:"out"`              // output tokens, including reasoning
	Think    int64  `json:"think"`            // reasoning / thinking tokens (subset of out)
	Dur      *int64 `json:"dur,omitempty"`    // request duration ms
	TTFT     *int64 `json:"ttft,omitempty"`   // time to first token ms
	TQ       string `json:"tq"`               // timing quality: exact | est | none
	Stop     string `json:"stop,omitempty"`
	Err      string `json:"err,omitempty"`
	Retries  int    `json:"retries,omitempty"`
	Tier     string `json:"tier,omitempty"`
	Speed    string `json:"speed,omitempty"`
	Effort   string `json:"effort,omitempty"`
}

// Turn is one agent turn with exact timing (kind "turn"); Codex only for now.
type Turn struct {
	K      string `json:"k"`
	Tool   string `json:"tool"`
	Key    string `json:"key"`
	TS     int64  `json:"ts"`
	Model  string `json:"model"`
	Dur    *int64 `json:"dur,omitempty"`
	TTFT   *int64 `json:"ttft,omitempty"`
	Out    int64  `json:"out,omitempty"` // output tokens in the turn, for tok/s
	Status string `json:"status,omitempty"`
}

// Limit is one reading of one limit window (kind "limit").
type Limit struct {
	K        string   `json:"k"`
	Provider string   `json:"provider"`        // claude | openai | gemini
	Acct     string   `json:"acct"`            // short hash of the account id
	Plan     string   `json:"plan,omitempty"`  // display name, e.g. "Max 20x"
	Group    string   `json:"group,omitempty"` // budget the window belongs to; empty = the account's only budget
	GroupLbl string   `json:"group_label,omitempty"`
	Window   string   `json:"window"`           // stable id within the account, e.g. five_hour, weekly, weekly:opus, credits
	Kind     string   `json:"kind"`             // session | weekly | weekly_scoped | credits
	Label    string   `json:"label"`            // display label, e.g. "Opus"
	Used     *float64 `json:"used,omitempty"`   // percent used 0-100; a window that has not started reports 0 and no resets
	Resets   *int64   `json:"resets,omitempty"` // unix ms; nil when unknown / not started
	Len      int64    `json:"len,omitempty"`    // window length in seconds
	Limited  bool     `json:"limited,omitempty"`
	Amount   *float64 `json:"amount,omitempty"` // credits: amount left
	Cap      *float64 `json:"cap,omitempty"`    // credits: monthly cap
	Currency string   `json:"currency,omitempty"`
	TS       int64    `json:"ts"`  // when this reading was true, unix ms
	Src      string   `json:"src"` // rollout | endpoint | rpc | cli | history | transcript
}

// Session is a live or recently active agent session (kind "session").
type Session struct {
	K       string  `json:"k"`
	Tool    string  `json:"tool"`
	ID      string  `json:"id"`
	Cwd     string  `json:"cwd,omitempty"`
	Model   string  `json:"model,omitempty"`
	Status  string  `json:"status"` // busy | idle
	Started int64   `json:"started,omitempty"`
	Updated int64   `json:"updated"`
	Ctx     float64 `json:"ctx,omitempty"` // context window fill, percent
	Tokens  int64   `json:"tokens,omitempty"`
}

// Log is a diagnostic line (kind "log").
type Log struct {
	K     string `json:"k"`
	Level string `json:"level"` // info | warn | error
	Src   string `json:"src,omitempty"`
	Msg   string `json:"msg"`
}

// Cursor is always the last line of a scan (kind "cursor").
type Cursor struct {
	K string `json:"k"`
	V string `json:"v"`
}

// Emitter writes records as NDJSON. Safe for concurrent use.
type Emitter struct {
	mu sync.Mutex
	w  *bufio.Writer
	N  map[string]int
}

func NewEmitter(w io.Writer) *Emitter {
	return &Emitter{w: bufio.NewWriterSize(w, 1<<16), N: map[string]int{}}
}

func (e *Emitter) emit(kind string, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	e.mu.Lock()
	e.w.Write(b)
	e.w.WriteByte('\n')
	e.N[kind]++
	e.mu.Unlock()
}

func (e *Emitter) Req(r Req)         { r.K = "req"; e.emit("req", r) }
func (e *Emitter) Turn(t Turn)       { t.K = "turn"; e.emit("turn", t) }
func (e *Emitter) Limit(l Limit)     { l.K = "limit"; e.emit("limit", l) }
func (e *Emitter) Session(s Session) { s.K = "session"; e.emit("session", s) }
func (e *Emitter) Cursor(v string)   { e.emit("cursor", Cursor{K: "cursor", V: v}) }
func (e *Emitter) Log(level, src, msg string) {
	e.emit("log", Log{K: "log", Level: level, Src: src, Msg: msg})
}
func (e *Emitter) Flush() { e.mu.Lock(); e.w.Flush(); e.mu.Unlock() }
