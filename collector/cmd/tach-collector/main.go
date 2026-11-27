// tach-collector reads the usage logs AI coding tools already write and prints
// compact NDJSON events. It is run by the Tach app, locally and over SSH.
// It never prints prompts, code or credentials.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tach/collector/internal/antigravity"
	"tach/collector/internal/claude"
	"tach/collector/internal/codex"
	"tach/collector/internal/cursor"
	"tach/collector/internal/detect"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
	"tach/collector/internal/gemini"
	"tach/collector/internal/limits"
)

// Version is the collector protocol and build version. The app redeploys a remote
// collector whose version differs from its own.
const Version = "0.1.2"

type source struct {
	name     string
	scan     func(context.Context, env.Env, *cursor.State, *event.Emitter) error
	sessions func(context.Context, env.Env, *event.Emitter) error
}

var sources = []source{
	{"claude_code", claude.Scan, claude.Sessions},
	{"codex", codex.Scan, codex.Sessions},
	{"antigravity", antigravity.Scan, antigravity.Sessions},
	{"gemini_cli", gemini.Scan, gemini.Sessions},
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	cmd, args := os.Args[1], os.Args[2:]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	home := fs.String("home", "", "home directory to read (default: the current user's)")
	since := fs.Duration("since", 30*24*time.Hour, "on a first scan, ignore events older than this")
	cur := fs.String("cursor", "", "cursor from the previous scan; - reads it from stdin")
	curFile := fs.String("cursor-file", "", "read the cursor from this file and write the new one back")
	stateDir := fs.String("state", "", "keep the cursor in this directory instead of printing it; the cursor line then carries a short token")
	stateID := fs.String("id", "default", "with --state: which reader this cursor belongs to")
	commit := fs.String("commit", "", "with --state: token of the previous scan, confirming its events were stored")
	reset := fs.Bool("reset", false, "with --state: forget the stored cursor and read everything again, e.g. to reach further back")
	only := fs.String("only", "", "comma-separated sources or providers to include")
	verbose := fs.Bool("v", false, "log progress to stderr")
	fs.Parse(args)

	e := env.Env{Home: *home, Now: time.Now(), Verbose: *verbose}
	if e.Home == "" {
		e.Home, _ = os.UserHomeDir()
	}
	e.Since = e.Now.Add(-*since)
	ctx := context.Background()
	out := event.NewEmitter(os.Stdout)
	defer out.Flush()
	want := func(n string) bool { return *only == "" || strings.Contains(","+*only+",", ","+n+",") }

	switch cmd {
	case "version":
		fmt.Println(Version)
	case "scan":
		v := *cur
		if v == "-" { // the app pipes the cursor in, so a large one never hits argv limits
			b, _ := io.ReadAll(io.LimitReader(os.Stdin, 64<<20))
			v = strings.TrimSpace(string(b))
		}
		if *curFile != "" {
			if b, err := os.ReadFile(*curFile); err == nil {
				v = strings.TrimSpace(string(b))
			}
		}
		// With --state the cursor stays here and advances in two steps: this scan writes the next
		// cursor beside the current one, and it becomes current only when the reader's next call
		// confirms, by token, that it stored the events. An unconfirmed scan is simply repeated;
		// the reader upserts, so repeats are harmless.
		var curPath, nextPath string
		if *stateDir != "" {
			dir := expandHome(*stateDir, e.Home)
			os.MkdirAll(dir, 0o700)
			curPath = filepath.Join(dir, "cursor-"+safeName(*stateID))
			nextPath = curPath + ".next"
			if *reset {
				os.Remove(curPath)
				os.Remove(nextPath)
			}
			if b, err := os.ReadFile(nextPath); err == nil && *commit != "" && token(b) == *commit {
				os.Rename(nextPath, curPath)
			} else {
				os.Remove(nextPath)
			}
			if b, err := os.ReadFile(curPath); err == nil {
				v = strings.TrimSpace(string(b))
			} else {
				v = ""
			}
		}
		st := cursor.Decode(v)
		var wg sync.WaitGroup
		for _, s := range sources {
			if !want(s.name) {
				continue
			}
			wg.Add(1)
			go func(s source) {
				defer wg.Done()
				defer func() {
					if r := recover(); r != nil {
						out.Log("error", s.name, fmt.Sprint("panic: ", r))
					}
				}()
				if err := s.scan(ctx, e, st, out); err != nil {
					out.Log("error", s.name, err.Error())
				}
				if err := s.sessions(ctx, e, out); err != nil {
					out.Log("warn", s.name, err.Error())
				}
			}(s)
		}
		wg.Wait()
		enc := st.Encode()
		if *curFile != "" {
			tmp := *curFile + ".tmp"
			if os.WriteFile(tmp, []byte(enc), 0o600) == nil {
				os.Rename(tmp, *curFile)
			}
		}
		if nextPath != "" {
			if err := os.WriteFile(nextPath, []byte(enc), 0o600); err != nil {
				out.Log("error", "cursor", err.Error())
			}
			enc = token([]byte(enc))
		}
		out.Cursor(enc)
	case "limits":
		var ps []string
		if *only != "" {
			ps = strings.Split(*only, ",")
		}
		if err := limits.Poll(ctx, e, ps, out); err != nil {
			out.Log("error", "limits", err.Error())
		}
	case "detect":
		out.Flush()
		json.NewEncoder(os.Stdout).Encode(detect.Run(ctx, e))
	default:
		usage()
	}
}

func token(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:8])
}

func expandHome(p, home string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		return filepath.Join(home, strings.TrimPrefix(p, "~"))
	}
	return p
}

// safeName keeps a reader id usable as a file name.
func safeName(s string) string {
	b := []byte(s)
	for i, c := range b {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			b[i] = '_'
		}
	}
	if len(b) == 0 {
		return "default"
	}
	return string(b)
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: tach-collector <scan|limits|detect|version> [flags]")
	os.Exit(2)
}
