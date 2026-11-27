// Package detect reports which tools are installed and signed in, for first-run setup.
// It is cheap: directory listings, small config files, `--version`; no network.
package detect

import (
	"bytes"
	"context"
	"encoding/json"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"tach/collector/internal/acct"
	"tach/collector/internal/antigravity"
	"tach/collector/internal/env"
	"tach/collector/internal/limits"
)

// Report is printed as one JSON object by `tach-collector detect`.
type Report struct {
	Host  string `json:"host"`
	OS    string `json:"os"`
	Arch  string `json:"arch"`
	Tools []Tool `json:"tools"`
}

type Tool struct {
	Tool     string `json:"tool"` // claude_code | codex | antigravity | gemini_cli
	Found    bool   `json:"found"`
	Version  string `json:"version,omitempty"`
	DataDir  string `json:"data_dir,omitempty"`
	Bytes    int64  `json:"bytes,omitempty"` // size of usage data on disk
	Files    int    `json:"files,omitempty"`
	SignedIn bool   `json:"signed_in"`
	Plan     string `json:"plan,omitempty"`
	Acct     string `json:"acct,omitempty"`   // short hash of the account id
	Limits   string `json:"limits,omitempty"` // ok | stale_token | app_closed | unavailable
	Note     string `json:"note,omitempty"`
}

// walkCap bounds the directory walk per tool; beyond it bytes/files are a lower bound.
const walkCap = 200_000

func Run(ctx context.Context, e env.Env) Report {
	if e.Now.IsZero() {
		e.Now = time.Now()
	}
	host, _ := os.Hostname()
	r := Report{Host: host, OS: runtime.GOOS, Arch: runtime.GOARCH}
	fns := []func(context.Context, env.Env) Tool{claudeCode, codex, antigravityTool, geminiCLI}
	r.Tools = make([]Tool, len(fns))
	var wg sync.WaitGroup
	for i, f := range fns {
		wg.Add(1)
		go func(i int, f func(context.Context, env.Env) Tool) {
			defer wg.Done()
			r.Tools[i] = f(ctx, e)
		}(i, f)
	}
	wg.Wait()
	return r
}

func claudeCode(ctx context.Context, e env.Env) Tool {
	t := Tool{Tool: "claude_code", Limits: "unavailable"}
	cfg := limits.ClaudeConfigDir(e.Home)
	bin := limits.FindClaude(e.Home)
	t.DataDir = filepath.Join(cfg, "projects")
	t.Bytes, t.Files = usage(t.DataDir)
	t.Found = bin != "" || exists(cfg)
	if bin != "" {
		t.Version = claudeVersion(ctx, bin)
	}
	ac := limits.ReadClaudeAccount(e.Home)
	t.SignedIn, t.Plan, t.Acct = ac.SignedIn, ac.Plan, ac.Acct
	switch {
	case !t.Found:
	case bin != "" && ac.SignedIn:
		// get_usage through the CLI does its own auth: a stale stored token does not matter.
		t.Limits = "ok"
	default:
		tok, err := limits.ReadClaudeToken(ctx, e.Home)
		switch {
		case err != nil || !tok.HasToken:
			if hist(e.Home) {
				t.Note = "limits only from Claude Desktop's usage history"
			}
		case tok.Fresh(e.Now):
			t.SignedIn, t.Limits = true, "ok"
		default:
			t.SignedIn, t.Limits = true, "stale_token"
			t.Note = "Claude sign-in on this machine has expired"
		}
		if t.Plan == "" && tok != nil {
			t.Plan = limits.ClaudePlanName("", tok.Tier, tok.SubType)
		}
	}
	return t
}

func hist(home string) bool { return exists(limits.ClaudeHistoryPath(home)) }

var claudeVersionDir = regexp.MustCompile(`/versions/(\d+\.\d+\.\d+[^/]*)$`)

// claudeVersion reads the version from the native installer's symlink
// (~/.local/bin/claude -> .../versions/2.1.330) and only runs --version otherwise.
func claudeVersion(ctx context.Context, bin string) string {
	if p, err := filepath.EvalSymlinks(bin); err == nil {
		if m := claudeVersionDir.FindStringSubmatch(p); m != nil {
			return m[1]
		}
	}
	return runVersion(ctx, bin)
}

func codex(ctx context.Context, e env.Env) Tool {
	t := Tool{Tool: "codex", Limits: "unavailable"}
	home := limits.CodexHome(e.Home)
	bin := find("codex", e.Home)
	t.DataDir = filepath.Join(home, "sessions")
	b1, f1 := usage(t.DataDir)
	b2, f2 := usage(filepath.Join(home, "archived_sessions"))
	t.Bytes, t.Files = b1+b2, f1+f2
	t.Found = bin != "" || exists(home)
	if bin != "" {
		t.Version = runVersion(ctx, bin)
	}
	a, err := limits.ReadCodexAuth(e.Home)
	if err != nil || !a.HasToken() {
		if err == nil && a.Mode != "" && a.Mode != "chatgpt" {
			t.SignedIn, t.Note = true, "API key sign-in: no plan limits"
		}
		return t
	}
	t.SignedIn = true
	t.Plan = limits.OpenAIPlanName(a.Plan)
	t.Acct = acct.Hash(a.AccountID)
	switch {
	case a.Mode != "" && a.Mode != "chatgpt":
		t.Note = "API key sign-in: no plan limits"
	case !a.Expires.IsZero() && !a.Expires.After(e.Now):
		t.Limits, t.Note = "stale_token", "Codex sign-in on this machine has expired; running codex refreshes it"
	default:
		t.Limits = "ok"
	}
	return t
}

func antigravityTool(ctx context.Context, e env.Env) Tool {
	t := Tool{Tool: "antigravity", Limits: "app_closed"}
	root := antigravity.Root(e.Home)
	t.DataDir = antigravity.ConversationsDir(e.Home)
	t.Bytes, t.Files = usage(t.DataDir)
	app := appBundle(e.Home)
	bin := find("antigravity", e.Home)
	t.Found = exists(root) || app != "" || bin != ""
	if !t.Found {
		t.Limits = "unavailable"
		return t
	}
	for _, s := range antigravity.Servers(e.Home) {
		if s.Alive {
			t.Limits, t.Version = "ok", s.Version
			t.SignedIn = true // the language server only runs signed in
			break
		}
	}
	if t.Version == "" && app != "" {
		t.Version = plistVersion(filepath.Join(app, "Contents", "Info.plist"))
	}
	if !t.SignedIn {
		t.SignedIn = hasAntigravityToken(ctx, e.Home)
	}
	if t.Limits == "app_closed" {
		t.Note = "open Antigravity to read its limits"
	} else {
		t.Note = "plan and account come from the limits poll"
	}
	return t
}

func appBundle(home string) string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	for _, p := range []string{"/Applications/Antigravity.app", filepath.Join(home, "Applications", "Antigravity.app")} {
		if exists(p) {
			return p
		}
	}
	return ""
}

var plistShortVersion = regexp.MustCompile(`<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>`)

func plistVersion(p string) string {
	b, err := os.ReadFile(p)
	if err != nil || len(b) > 1<<20 {
		return ""
	}
	if m := plistShortVersion.FindSubmatch(b); m != nil {
		return string(m[1])
	}
	return ""
}

// hasAntigravityToken checks that the editor's state DB holds a sign-in,
// without reading the token's value.
func hasAntigravityToken(ctx context.Context, home string) bool {
	var p string
	if runtime.GOOS == "darwin" {
		p = filepath.Join(home, "Library", "Application Support", "Antigravity", "User", "globalStorage", "state.vscdb")
	} else {
		p = filepath.Join(home, ".config", "Antigravity", "User", "globalStorage", "state.vscdb")
	}
	db, err := antigravity.OpenRO(p)
	if err != nil {
		return false
	}
	defer db.Close()
	var n int
	err = db.QueryRowContext(ctx, `SELECT COUNT(*) FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.oauthToken' AND length(value) > 0`).Scan(&n)
	return err == nil && n > 0
}

func geminiCLI(ctx context.Context, e env.Env) Tool {
	t := Tool{Tool: "gemini_cli", Limits: "unavailable"}
	dir := filepath.Join(e.Home, ".gemini")
	bin := find("gemini", e.Home)
	t.DataDir = filepath.Join(dir, "tmp")
	t.Bytes, t.Files = usage(t.DataDir)
	t.Found = bin != "" || exists(t.DataDir)
	if bin != "" {
		t.Version = runVersion(ctx, bin)
	}
	if b, err := os.ReadFile(filepath.Join(dir, "oauth_creds.json")); err == nil {
		var c struct {
			Expiry int64  `json:"expiry_date"`
			RT     string `json:"refresh_token"`
		}
		if json.Unmarshal(b, &c) == nil {
			t.SignedIn = c.RT != "" || (c.Expiry > 0 && time.UnixMilli(c.Expiry).After(e.Now))
		}
	}
	if b, err := os.ReadFile(filepath.Join(dir, "google_accounts.json")); err == nil {
		var a struct {
			Active string `json:"active"`
		}
		if json.Unmarshal(b, &a) == nil {
			t.Acct = acct.Email(a.Active)
		}
	}
	t.Note = "Gemini CLI reports no plan limits"
	return t
}

// --- helpers ---

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

// find looks a binary up on PATH, then in install dirs a non-login SSH shell
// often leaves off PATH.
func find(name, home string) string {
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	for _, d := range []string{
		filepath.Join(home, ".local", "bin"), filepath.Join(home, ".bun", "bin"),
		filepath.Join(home, ".npm-global", "bin"), filepath.Join(home, ".volta", "bin"),
		"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
	} {
		p := filepath.Join(d, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

var versionRe = regexp.MustCompile(`\d+\.\d+\.\d+(?:[-+.][0-9A-Za-z.-]+)?`)

func runVersion(ctx context.Context, bin string) string {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "--version")
	cmd.Stdin = nil
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.WaitDelay = time.Second
	if cmd.Run() != nil {
		return ""
	}
	line, _, _ := strings.Cut(out.String(), "\n")
	return versionRe.FindString(line)
}

// usage sums regular-file sizes under dir, visiting at most walkCap entries.
func usage(dir string) (int64, int) {
	var n int64
	files, seen := 0, 0
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		seen++
		if seen > walkCap {
			return fs.SkipAll
		}
		if d.Type().IsRegular() {
			if info, err := d.Info(); err == nil {
				n += info.Size()
				files++
			}
		}
		return nil
	})
	return n, files
}
