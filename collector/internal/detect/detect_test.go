package detect

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"tach/collector/internal/acct"
	"tach/collector/internal/env"
)

func write(t *testing.T, p, s string, mode os.FileMode) {
	t.Helper()
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(s), mode); err != nil {
		t.Fatal(err)
	}
}

func TestRun(t *testing.T) {
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	t.Setenv("PATH", bin)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	t.Setenv("CODEX_HOME", "")

	// Claude Code: native install symlink, signed in.
	ver := filepath.Join(home, ".local", "share", "claude", "versions", "9.9.9")
	write(t, ver, "#!/bin/sh\necho should-not-run; exit 1\n", 0o755)
	os.MkdirAll(filepath.Join(home, ".local", "bin"), 0o755)
	os.Symlink(ver, filepath.Join(home, ".local", "bin", "claude"))
	write(t, filepath.Join(home, ".claude.json"), `{"oauthAccount":{"accountUuid":"uuid-synthetic","planDisplayName":"Max 20x"}}`, 0o600)
	write(t, filepath.Join(home, ".claude", "projects", "p", "s.jsonl"), strings.Repeat("x", 100), 0o600)

	// Codex: binary on PATH, expired token.
	write(t, filepath.Join(bin, "codex"), "#!/bin/sh\necho 'codex-cli 0.171.0'\n", 0o755)
	claims, _ := json.Marshal(map[string]any{"exp": time.Now().Add(-time.Hour).Unix(),
		"https://api.openai.com/auth": map[string]any{"chatgpt_plan_type": "pro"}})
	jwt := "e30." + base64.RawURLEncoding.EncodeToString(claims) + ".sig"
	write(t, filepath.Join(home, ".codex", "auth.json"), `{"auth_mode":"chatgpt","tokens":{"access_token":"`+jwt+`","account_id":"acct-synthetic"}}`, 0o600)
	write(t, filepath.Join(home, ".codex", "sessions", "2026", "11", "25", "r.jsonl"), "12345", 0o600)

	// Antigravity: a live language server (this test process).
	write(t, filepath.Join(home, ".gemini", "antigravity", "daemon", "hub_1.json"),
		`{"pid": `+strconv.Itoa(os.Getpid())+`, "httpPort": 1, "lsVersion": "2.35.1", "csrfToken": "SYNTHETIC"}`, 0o600)
	write(t, filepath.Join(home, ".gemini", "antigravity", "conversations", "c.db"), "1234567890", 0o600)

	r := Run(context.Background(), env.Env{Home: home, Now: time.Now()})
	b, _ := json.Marshal(r)
	if strings.Contains(string(b), "SYNTHETIC") || strings.Contains(string(b), jwt) {
		t.Fatal("secret in report")
	}
	by := map[string]Tool{}
	for _, tl := range r.Tools {
		by[tl.Tool] = tl
	}
	c := by["claude_code"]
	if !c.Found || c.Version != "9.9.9" || !c.SignedIn || c.Plan != "Max 20x" || c.Acct != acct.Hash("uuid-synthetic") || c.Limits != "ok" || c.Bytes != 100 || c.Files != 1 {
		t.Errorf("claude: %+v", c)
	}
	x := by["codex"]
	if !x.Found || x.Version != "0.171.0" || !x.SignedIn || x.Plan != "ChatGPT Pro" || x.Acct != acct.Hash("acct-synthetic") || x.Limits != "stale_token" || x.Files != 1 {
		t.Errorf("codex: %+v", x)
	}
	a := by["antigravity"]
	if !a.Found || a.Limits != "ok" || a.Version != "2.35.1" || a.Files != 1 || a.Bytes != 10 {
		t.Errorf("antigravity: %+v", a)
	}
	g := by["gemini_cli"]
	if g.Found || g.Limits != "unavailable" {
		t.Errorf("gemini: %+v", g)
	}
}

func TestAntigravityClosed(t *testing.T) {
	home := t.TempDir()
	t.Setenv("PATH", t.TempDir())
	write(t, filepath.Join(home, ".gemini", "antigravity", "daemon", "hub_1.json"), `{"pid": 999999999, "httpPort": 1}`, 0o600)
	a := antigravityTool(context.Background(), env.Env{Home: home, Now: time.Now()})
	if !a.Found || a.Limits != "app_closed" {
		t.Fatalf("%+v", a)
	}
}

func TestUsageCap(t *testing.T) {
	d := t.TempDir()
	for i := 0; i < 5; i++ {
		write(t, filepath.Join(d, "a", strconv.Itoa(i)), "xx", 0o600)
	}
	if n, f := usage(d); n != 10 || f != 5 {
		t.Fatalf("%d %d", n, f)
	}
	if n, f := usage(filepath.Join(d, "missing")); n != 0 || f != 0 {
		t.Fatal("missing dir")
	}
}
