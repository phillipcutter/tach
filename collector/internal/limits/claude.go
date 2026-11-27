package limits

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"tach/collector/internal/acct"
	"tach/collector/internal/env"
	"tach/collector/internal/event"
)

const claudeUsageURL = "https://api.anthropic.com/api/oauth/usage"

// ClaudeConfigDir honours CLAUDE_CONFIG_DIR.
func ClaudeConfigDir(home string) string {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d
	}
	return filepath.Join(home, ".claude")
}

// ClaudeAccount is the identity part of ~/.claude.json (oauthAccount).
type ClaudeAccount struct {
	Acct     string // hashed accountUuid
	OrgUUID  string // only used to pick history samples; never emitted
	Plan     string
	SignedIn bool
}

func claudeJSONPath(home string) string {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return filepath.Join(d, ".claude.json")
	}
	return filepath.Join(home, ".claude.json")
}

// ReadClaudeAccount reads oauthAccount from ~/.claude.json. The file can be
// several MB (it also holds per-project state), so it is decoded once, lazily.
func ReadClaudeAccount(home string) ClaudeAccount {
	var a ClaudeAccount
	b, err := os.ReadFile(claudeJSONPath(home))
	if err != nil {
		return a
	}
	var f struct {
		OAuth *struct {
			AccountUUID      string `json:"accountUuid"`
			OrganizationUUID string `json:"organizationUuid"`
			PlanDisplayName  string `json:"planDisplayName"`
			OrgRateLimitTier string `json:"organizationRateLimitTier"`
			OrganizationType string `json:"organizationType"`
		} `json:"oauthAccount"`
	}
	if json.Unmarshal(b, &f) != nil || f.OAuth == nil {
		return a
	}
	a.SignedIn = f.OAuth.AccountUUID != ""
	a.Acct = acct.Hash(f.OAuth.AccountUUID)
	a.OrgUUID = f.OAuth.OrganizationUUID
	a.Plan = ClaudePlanName(f.OAuth.PlanDisplayName, f.OAuth.OrgRateLimitTier, f.OAuth.OrganizationType)
	return a
}

var tierRe = regexp.MustCompile(`(?i)(max|pro|team|enterprise)_(\d+)x`)

// ClaudePlanName prefers the server's display name (planDisplayName), then a
// name derived from the rate-limit tier ("default_claude_max_20x" -> "Max 20x"),
// then the subscription type.
func ClaudePlanName(display, tier, subType string) string {
	if display != "" {
		return display
	}
	if m := tierRe.FindStringSubmatch(tier); m != nil {
		return strings.ToUpper(m[1][:1]) + strings.ToLower(m[1][1:]) + " " + m[2] + "x"
	}
	s := strings.TrimPrefix(strings.ToLower(subType), "claude_")
	if s == "" {
		return ""
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

// ClaudeToken is the stored OAuth credential's metadata. The token itself is
// unexported and only ever placed in an Authorization header.
type ClaudeToken struct {
	Source   string // keychain | file
	Expires  time.Time
	SubType  string
	Tier     string
	HasToken bool
	token    string
}

// Fresh reports whether the stored access token has not expired yet.
func (t *ClaudeToken) Fresh(now time.Time) bool {
	return t != nil && t.HasToken && !t.Expires.IsZero() && t.Expires.After(now)
}

// ReadClaudeToken reads the stored credential: macOS Keychain service
// "Claude Code-credentials" (only for the current user's own home), else
// <config>/.credentials.json. It never writes or refreshes anything.
func ReadClaudeToken(ctx context.Context, home string) (*ClaudeToken, error) {
	var blob []byte
	src := ""
	if runtime.GOOS == "darwin" && isOwnHome(home) {
		c, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(c, "/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w")
		cmd.Stderr = nil
		if b, err := cmd.Output(); err == nil && len(b) > 0 {
			blob, src = b, "keychain"
		}
	}
	if blob == nil {
		b, err := os.ReadFile(filepath.Join(ClaudeConfigDir(home), ".credentials.json"))
		if err != nil {
			return nil, err
		}
		blob, src = b, "file"
	}
	return parseClaudeCred(blob, src)
}

func parseClaudeCred(blob []byte, src string) (*ClaudeToken, error) {
	var f struct {
		C *struct {
			AccessToken      string `json:"accessToken"`
			ExpiresAt        int64  `json:"expiresAt"`
			SubscriptionType string `json:"subscriptionType"`
			RateLimitTier    string `json:"rateLimitTier"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(blob, &f) != nil {
		return nil, errors.New("stored Claude credential is not valid JSON")
	}
	t := &ClaudeToken{Source: src}
	if f.C == nil {
		return t, nil // e.g. an item holding only mcpOAuth
	}
	t.token, t.HasToken = f.C.AccessToken, f.C.AccessToken != ""
	if f.C.ExpiresAt > 0 {
		t.Expires = time.UnixMilli(f.C.ExpiresAt)
	}
	t.SubType, t.Tier = f.C.SubscriptionType, f.C.RateLimitTier
	return t, nil
}

func isOwnHome(home string) bool {
	h, err := os.UserHomeDir()
	if err != nil {
		return false
	}
	a, _ := filepath.Abs(home)
	b, _ := filepath.Abs(h)
	return a == b
}

// FindClaude locates the user's claude binary: PATH, then the usual install dirs.
func FindClaude(home string) string {
	if p, err := exec.LookPath("claude"); err == nil {
		return p
	}
	for _, p := range []string{
		filepath.Join(home, ".local", "bin", "claude"),
		filepath.Join(home, ".claude", "local", "claude"),
		filepath.Join(home, ".npm-global", "bin", "claude"),
		filepath.Join(home, ".bun", "bin", "claude"),
		"/opt/homebrew/bin/claude",
		"/usr/local/bin/claude",
	} {
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

func pollClaude(ctx context.Context, e env.Env, out *event.Emitter) {
	const src = "limits/claude"
	ac := ReadClaudeAccount(e.Home)
	var why []string

	// 1. get_usage through the user's own claude binary.
	if bin := FindClaude(e.Home); bin != "" {
		rl, sub, err := claudeCLIUsage(ctx, bin)
		switch {
		case err != nil:
			why = append(why, "claude CLI get_usage: "+err.Error())
		case rl == nil:
			out.Log("warn", src, "Claude plan limits do not apply to this sign-in (API key or third-party provider)")
			return
		default:
			plan := ac.Plan
			if plan == "" {
				plan = ClaudePlanName("", "", sub)
			}
			ls := mapClaude(rl, ac.Acct, plan, e.Now.UnixMilli(), "cli")
			for _, l := range ls {
				out.Limit(l)
			}
			out.Log("info", src, fmt.Sprintf("answered by get_usage through the claude CLI (%d windows)", len(ls)))
			return
		}
	} else {
		why = append(why, "claude CLI not found")
	}

	// 2. The OAuth usage endpoint with a stored, unexpired token.
	tok, err := ReadClaudeToken(ctx, e.Home)
	switch {
	case err != nil:
		why = append(why, "no stored Claude credential")
	case !tok.HasToken:
		why = append(why, "stored Claude credential has no access token")
	case !tok.Fresh(e.Now):
		why = append(why, "Claude sign-in on this machine has expired")
	default:
		body, err := claudeEndpoint(ctx, tok)
		if err == nil {
			var rl claudeRL
			if json.Unmarshal(body, &rl) == nil {
				plan := ac.Plan
				if plan == "" {
					plan = ClaudePlanName("", tok.Tier, tok.SubType)
				}
				ls := mapClaude(&rl, ac.Acct, plan, e.Now.UnixMilli(), "endpoint")
				for _, l := range ls {
					out.Limit(l)
				}
				out.Log("info", src, fmt.Sprintf("answered by /api/oauth/usage (%d windows)", len(ls)))
				return
			}
			err = errors.New("unexpected response shape")
		}
		var he httpError
		if errors.As(err, &he) && he.Code == 401 {
			why = append(why, "Claude sign-in on this machine was rejected")
		} else {
			why = append(why, "usage endpoint: "+err.Error())
		}
	}

	// 3. Claude Desktop's own history samples.
	ls, err := claudeHistory(e.Home, ac)
	if err == nil && len(ls) > 0 {
		for _, l := range ls {
			out.Limit(l)
		}
		age := time.Duration(e.Now.UnixMilli()-ls[0].TS) * time.Millisecond
		out.Log("info", src, fmt.Sprintf("answered by plan-usage-history.json, sample %s old (%s)",
			age.Round(time.Minute), strings.Join(why, "; ")))
		return
	}
	out.Log("warn", src, strings.Join(why, "; "))
}

// claudeCLIUsage sends one get_usage control request to the user's claude
// binary over stream-json and returns the rate_limits section. No user message
// is ever written, so no model turn starts; sessions are not persisted, MCP
// servers, user/local settings (and their hooks) and slash commands are off.
// The CLI does its own auth (and may refresh its own token, as it would when
// the user runs it); the collector never sees the token.
func claudeCLIUsage(ctx context.Context, bin string) (*claudeRL, string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	dir, err := os.MkdirTemp("", "tach-claude-")
	if err != nil {
		return nil, "", err
	}
	defer os.RemoveAll(dir)
	cmd := exec.CommandContext(ctx, bin,
		"-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
		"--no-session-persistence", "--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`,
		"--setting-sources", "project", "--disable-slash-commands")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1")
	cmd.WaitDelay = 2 * time.Second
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, "", err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, "", err
	}
	if err := cmd.Start(); err != nil {
		return nil, "", err
	}
	defer func() {
		stdin.Close()
		done := make(chan struct{})
		go func() { cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			cmd.Process.Kill()
			<-done
		}
	}()
	const reqID = "tach-get-usage"
	if _, err := fmt.Fprintf(stdin, `{"type":"control_request","request_id":%q,"request":{"subtype":"get_usage","skip_behaviors":true}}`+"\n", reqID); err != nil {
		return nil, "", err
	}
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 64<<10), 8<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if !strings.Contains(string(line), `"control_response"`) {
			continue
		}
		var m struct {
			Type     string `json:"type"`
			Response struct {
				Subtype   string `json:"subtype"`
				RequestID string `json:"request_id"`
				Error     string `json:"error"`
				Response  *struct {
					SubscriptionType    string    `json:"subscription_type"`
					RateLimitsAvailable bool      `json:"rate_limits_available"`
					RateLimits          *claudeRL `json:"rate_limits"`
				} `json:"response"`
			} `json:"response"`
		}
		if json.Unmarshal(line, &m) != nil || m.Type != "control_response" || m.Response.RequestID != reqID {
			continue
		}
		if m.Response.Subtype != "success" || m.Response.Response == nil {
			msg := m.Response.Error
			if len(msg) > 120 {
				msg = msg[:120]
			}
			return nil, "", errors.New("error response: " + msg)
		}
		r := m.Response.Response
		if !r.RateLimitsAvailable {
			return nil, r.SubscriptionType, nil
		}
		if r.RateLimits == nil {
			return nil, "", errors.New("no rate_limits in answer")
		}
		return r.RateLimits, r.SubscriptionType, nil
	}
	if ctx.Err() != nil {
		return nil, "", errors.New("timed out")
	}
	return nil, "", errors.New("CLI exited without answering")
}

func claudeEndpoint(ctx context.Context, tok *ClaudeToken) ([]byte, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", claudeUsageURL, nil)
	req.Header.Set("Authorization", "Bearer "+tok.token)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	req.Header.Set("Accept", "application/json")
	return do(officialClient, req)
}

// claudeRL is the shared shape of get_usage's rate_limits and /api/oauth/usage.
type claudeRL struct {
	FiveHour          *claudeWin `json:"five_hour"`
	SevenDay          *claudeWin `json:"seven_day"`
	SevenDayOpus      *claudeWin `json:"seven_day_opus"`
	SevenDaySonnet    *claudeWin `json:"seven_day_sonnet"`
	SevenDayOAuthApps *claudeWin `json:"seven_day_oauth_apps"`
	SevenDayCowork    *claudeWin `json:"seven_day_cowork"`
	ModelScoped       []struct {
		DisplayName string   `json:"display_name"`
		Utilization *float64 `json:"utilization"`
		ResetsAt    *string  `json:"resets_at"`
	} `json:"model_scoped"`
	Limits     []claudeRow `json:"limits"`
	ExtraUsage *struct {
		IsEnabled     bool     `json:"is_enabled"`
		MonthlyLimit  *float64 `json:"monthly_limit"`
		UsedCredits   *float64 `json:"used_credits"`
		Utilization   *float64 `json:"utilization"`
		Currency      *string  `json:"currency"`
		DecimalPlaces *int     `json:"decimal_places"`
	} `json:"extra_usage"`
}

type claudeWin struct {
	Utilization *float64 `json:"utilization"`
	ResetsAt    *string  `json:"resets_at"`
}

type claudeRow struct {
	Kind     string   `json:"kind"`
	Group    string   `json:"group"`
	Percent  *float64 `json:"percent"`
	ResetsAt *string  `json:"resets_at"`
	Severity string   `json:"severity"`
	Scope    *struct {
		Model *struct {
			DisplayName string `json:"display_name"`
		} `json:"model"`
		Surface *struct {
			DisplayName string `json:"display_name"`
		} `json:"surface"`
	} `json:"scope"`
}

func strp(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// mapClaude turns a rate-limit report into the protocol's windows. The
// server-driven limits[] list wins; the fixed fields fill in windows it does
// not list (older servers send only those).
func mapClaude(rl *claudeRL, acctHash, plan string, now int64, src string) []event.Limit {
	var out []event.Limit
	seen := map[string]bool{}
	add := func(id, kind, label string, used *float64, resetsISO string, length int64) {
		if seen[id] {
			return
		}
		seen[id] = true
		r, _ := parseISO(resetsISO)
		out = append(out, window("claude", acctHash, plan, id, kind, label, used, r, length, now, src))
	}
	for _, row := range rl.Limits {
		switch row.Kind {
		case "session":
			add("five_hour", "session", "5-hour", row.Percent, strp(row.ResetsAt), lenFiveHour)
		case "weekly_all":
			add("weekly", "weekly", "Week", row.Percent, strp(row.ResetsAt), lenWeek)
		case "weekly_scoped":
			name := ""
			if row.Scope != nil && row.Scope.Model != nil {
				name = row.Scope.Model.DisplayName
			} else if row.Scope != nil && row.Scope.Surface != nil {
				name = row.Scope.Surface.DisplayName
			}
			if s := slug(name); s != "" {
				add("weekly:"+s, "weekly_scoped", name, row.Percent, strp(row.ResetsAt), lenWeek)
			}
		}
	}
	win := func(id, kind, label string, w *claudeWin, length int64) {
		if w != nil {
			add(id, kind, label, w.Utilization, strp(w.ResetsAt), length)
		}
	}
	win("five_hour", "session", "5-hour", rl.FiveHour, lenFiveHour)
	win("weekly", "weekly", "Week", rl.SevenDay, lenWeek)
	win("weekly:opus", "weekly_scoped", "Opus", rl.SevenDayOpus, lenWeek)
	win("weekly:sonnet", "weekly_scoped", "Sonnet", rl.SevenDaySonnet, lenWeek)
	win("weekly:oauth_apps", "weekly_scoped", "OAuth apps", rl.SevenDayOAuthApps, lenWeek)
	win("weekly:cowork", "weekly_scoped", "Cowork", rl.SevenDayCowork, lenWeek)
	for _, m := range rl.ModelScoped {
		if s := slug(m.DisplayName); s != "" {
			add("weekly:"+s, "weekly_scoped", m.DisplayName, m.Utilization, strp(m.ResetsAt), lenWeek)
		}
	}
	if x := rl.ExtraUsage; x != nil && x.IsEnabled {
		l := event.Limit{Provider: "claude", Acct: acctHash, Plan: plan, Window: "credits", Kind: "credits",
			Label: "Extra usage credits", TS: now, Src: src, Currency: strp(x.Currency)}
		// Amounts are in minor units (cents) unless decimal_places says otherwise.
		dp := 2
		if x.DecimalPlaces != nil {
			dp = *x.DecimalPlaces
		}
		scale := math.Pow10(dp)
		if x.MonthlyLimit != nil {
			l.Cap = f64(round2(*x.MonthlyLimit / scale))
			if x.UsedCredits != nil {
				l.Amount = f64(round2((*x.MonthlyLimit - *x.UsedCredits) / scale))
			}
		}
		used := 0.0
		switch {
		case x.Utilization != nil:
			used = *x.Utilization
		case x.MonthlyLimit != nil && *x.MonthlyLimit > 0 && x.UsedCredits != nil:
			used = *x.UsedCredits / *x.MonthlyLimit * 100
		}
		l.Used = f64(clampPct(used))
		l.Limited = *l.Used >= 100
		out = append(out, l)
	}
	return out
}

// ClaudeHistoryPath is Claude Desktop's plan-usage history.
func ClaudeHistoryPath(home string) string {
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support", "Claude", "plan-usage-history.json")
	}
	return filepath.Join(home, ".config", "Claude", "plan-usage-history.json")
}

// claudeHistory returns the newest sample for this account's organisation as
// limit readings stamped with the sample's own time. Reset times are not in
// the file.
func claudeHistory(home string, ac ClaudeAccount) ([]event.Limit, error) {
	b, err := os.ReadFile(ClaudeHistoryPath(home))
	if err != nil {
		return nil, err
	}
	var f struct {
		Samples []struct {
			T   int64               `json:"t"`
			Org string              `json:"org"`
			U   map[string]*float64 `json:"u"`
		} `json:"samples"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, err
	}
	best := -1
	for i, s := range f.Samples {
		if ac.OrgUUID != "" && s.Org != "" && s.Org != ac.OrgUUID {
			continue
		}
		if best < 0 || s.T > f.Samples[best].T {
			best = i
		}
	}
	if best < 0 {
		return nil, errors.New("no sample")
	}
	s := f.Samples[best]
	var out []event.Limit
	if v := s.U["fh"]; v != nil {
		l := window("claude", ac.Acct, ac.Plan, "five_hour", "session", "5-hour", v, 0, lenFiveHour, s.T, "history")
		out = append(out, l)
	}
	if v := s.U["sd"]; v != nil {
		out = append(out, window("claude", ac.Acct, ac.Plan, "weekly", "weekly", "Week", v, 0, lenWeek, s.T, "history"))
	}
	if v := s.U["xu"]; v != nil && *v > 0 {
		l := event.Limit{Provider: "claude", Acct: ac.Acct, Plan: ac.Plan, Window: "credits", Kind: "credits",
			Label: "Extra usage credits", Used: f64(clampPct(*v)), TS: s.T, Src: "history"}
		l.Limited = *l.Used >= 100
		out = append(out, l)
	}
	return out, nil
}
