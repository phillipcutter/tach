package antigravity

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"syscall"

	_ "modernc.org/sqlite" // pure-Go driver, registers "sqlite"
)

// Root is Antigravity's data directory under home. The same layout was seen on
// macOS and Linux (~/.gemini/antigravity).
func Root(home string) string { return filepath.Join(home, ".gemini", "antigravity") }

// ConversationsDir holds one SQLite file per conversation, named <cascadeId>.db.
func ConversationsDir(home string) string { return filepath.Join(Root(home), "conversations") }

// OpenRO opens a SQLite file read-only and immutable: SQLite takes no locks and
// writes nothing next to it (no -shm, no -wal). Rows still in an un-checkpointed
// WAL are not visible; they appear on a later scan once Antigravity checkpoints.
func OpenRO(path string) (*sql.DB, error) {
	if _, err := os.Stat(path); err != nil {
		return nil, err
	}
	u := url.URL{Scheme: "file", Path: path, RawQuery: "mode=ro&immutable=1"}
	db, err := sql.Open("sqlite", "file:"+u.EscapedPath()+"?"+u.RawQuery)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	return db, nil
}

// Server is one running Antigravity language server found via daemon/*.json.
// CSRF is a secret: never log or print it.
type Server struct {
	File      string
	PID       int
	HTTPPort  int
	HTTPSPort int
	Version   string
	CSRF      string
	Alive     bool // pid exists (or no pid recorded)
}

// String omits the CSRF token.
func (s Server) String() string {
	return "antigravity ls pid=" + strconv.Itoa(s.PID) + " http=" + strconv.Itoa(s.HTTPPort) + " v" + s.Version
}

// Servers lists language servers announced in daemon/*.json (hub_<port>.json on
// macOS, ls_<hash>.json seen on Linux), live ones first, newest file first.
func Servers(home string) []Server {
	files, _ := filepath.Glob(filepath.Join(Root(home), "daemon", "*.json"))
	type fs struct {
		s  Server
		mt int64
	}
	var out []fs
	for _, f := range files {
		st, err := os.Stat(f)
		if err != nil || st.Size() > 1<<20 {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var m map[string]any
		if json.Unmarshal(b, &m) != nil {
			continue
		}
		s := Server{File: f}
		s.PID = intOf(m, "pid")
		s.HTTPPort = intOf(m, "httpPort", "http_port", "port")
		s.HTTPSPort = intOf(m, "httpsPort", "https_port")
		s.Version = strOf(m, "lsVersion", "ls_version", "version")
		s.CSRF = strOf(m, "csrfToken", "csrf_token", "csrf")
		if s.HTTPPort == 0 && s.HTTPSPort == 0 {
			continue
		}
		s.Alive = s.PID <= 0 || pidAlive(s.PID)
		out = append(out, fs{s, st.ModTime().UnixNano()})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].s.Alive != out[j].s.Alive {
			return out[i].s.Alive
		}
		return out[i].mt > out[j].mt
	})
	r := make([]Server, len(out))
	for i := range out {
		r[i] = out[i].s
	}
	return r
}

func pidAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func intOf(m map[string]any, keys ...string) int {
	for _, k := range keys {
		switch v := m[k].(type) {
		case float64:
			return int(v)
		case string:
			if n, err := strconv.Atoi(v); err == nil {
				return n
			}
		}
	}
	return 0
}

func strOf(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k].(string); ok && v != "" {
			return v
		}
	}
	return ""
}

// summary is one row of conversation_summaries.db, minus title/preview/summary.
type summary struct {
	ID           string
	Updated      int64 // unix ms
	Workspace    string
	Status       string
	Parent       string
	Nesting      int64
	NotFullyIdle bool
	Killed       bool
}

func (s summary) busy() bool {
	return s.NotFullyIdle || (s.Status != "" && s.Status != "CASCADE_RUN_STATUS_IDLE")
}

func loadSummaries(ctx context.Context, home string) (map[string]summary, error) {
	db, err := OpenRO(filepath.Join(Root(home), "conversation_summaries.db"))
	if err != nil {
		return nil, err
	}
	defer db.Close()
	// Only metadata columns: title, preview and raw_summary are content and are never selected.
	rows, err := db.QueryContext(ctx, `SELECT conversation_id, CAST(last_modified_time AS TEXT), workspace_uris,
		status, parent_conversation_id, nesting_depth, not_fully_idle, killed FROM conversation_summaries`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]summary{}
	for rows.Next() {
		var s summary
		var mod, ws sql.NullString
		var nfi, killed any
		if rows.Scan(&s.ID, &mod, &ws, &s.Status, &s.Parent, &s.Nesting, &nfi, &killed) != nil {
			continue
		}
		s.Updated = parseTime(mod.String)
		s.Workspace = firstWorkspace(ws.String)
		s.NotFullyIdle, s.Killed = truthy(nfi), truthy(killed)
		out[s.ID] = s
	}
	return out, rows.Err()
}

func truthy(v any) bool {
	switch x := v.(type) {
	case int64:
		return x != 0
	case float64:
		return x != 0
	case bool:
		return x
	case string:
		return x == "1" || x == "true"
	case []byte:
		return string(x) == "1" || string(x) == "true"
	}
	return false
}

// firstWorkspace turns `["file:///Users/me/proj"]` into /Users/me/proj. Remote
// workspace URIs (vscode-remote:// etc.) give "".
func firstWorkspace(js string) string {
	var uris []string
	if json.Unmarshal([]byte(js), &uris) != nil {
		return ""
	}
	for _, s := range uris {
		u, err := url.Parse(s)
		if err == nil && u.Scheme == "file" && u.Path != "" {
			return u.Path
		}
	}
	return ""
}
