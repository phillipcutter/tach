package limits

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"tach/collector/internal/acct"
	"tach/collector/internal/event"
)

var now = time.Date(2026, 11, 25, 12, 0, 0, 0, time.UTC).UnixMilli()

func byWindow(ls []event.Limit) map[string]event.Limit {
	m := map[string]event.Limit{}
	for _, l := range ls {
		if _, dup := m[l.Window]; dup {
			panic("duplicate window " + l.Window)
		}
		m[l.Window] = l
	}
	return m
}

func used(l event.Limit) float64 {
	if l.Used == nil {
		return -1
	}
	return *l.Used
}

func checkNotStarted(t *testing.T, l event.Limit) {
	t.Helper()
	if used(l) != 0 || l.Resets != nil || l.Limited {
		t.Errorf("%s: not-started window must be used 0, no resets: %+v", l.Window, l)
	}
}

// --- OpenAI ---

const openaiFixture = `{
 "user_id": "user-REDACTED", "account_id": "acct-from-response", "email": "redacted@example.com",
 "plan_type": "pro",
 "rate_limit": {"allowed": true, "limit_reached": false,
   "primary_window": {"used_percent": 62, "limit_window_seconds": 604800, "reset_after_seconds": 416474, "reset_at": 1796076526},
   "secondary_window": null},
 "code_review_rate_limit": null, "additional_rate_limits": null,
 "credits": {"has_credits": false, "unlimited": false, "overage_limit_reached": false, "balance": "0"},
 "rate_limit_reached_type": null}`

func TestOpenAIWeeklyOnly(t *testing.T) {
	ls, err := mapOpenAI([]byte(openaiFixture), &CodexAuth{AccountID: "acct-synthetic"}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(ls) != 1 {
		t.Fatalf("want 1 window, got %d: %+v", len(ls), ls)
	}
	w := ls[0]
	if w.Window != "weekly" || w.Kind != "weekly" || w.Label != "Week" || used(w) != 62 || w.Len != 604800 ||
		*w.Resets != 1796076526000 || w.Plan != "ChatGPT Pro" || w.Acct != acct.Hash("acct-synthetic") || w.Src != "endpoint" || w.TS != now {
		t.Fatalf("bad weekly: %+v", w)
	}
}

func TestOpenAIBothWindowsExtraCreditsLimited(t *testing.T) {
	body := `{"plan_type": "plus",
	 "rate_limit": {"allowed": false, "limit_reached": true,
	   "primary_window": {"used_percent": 100, "limit_window_seconds": 18000, "reset_after_seconds": 600},
	   "secondary_window": {"used_percent": 40.5, "limit_window_seconds": 604800, "reset_at": 1796076526}},
	 "additional_rate_limits": [{"limit_name": "GPT-6 Astra", "rate_limit": {"limit_reached": false,
	     "primary_window": {"used_percent": 0, "limit_window_seconds": 604800, "reset_at": null}}}],
	 "code_review_rate_limit": {"primary_window": {"used_percent": 12, "limit_window_seconds": 604800, "reset_at": 1796076526}},
	 "credits": {"has_credits": true, "unlimited": false, "balance": "12.5"}}`
	ls, err := mapOpenAI([]byte(body), &CodexAuth{}, now)
	if err != nil {
		t.Fatal(err)
	}
	m := byWindow(ls)
	fh := m["five_hour"]
	if fh.Kind != "session" || fh.Label != "5-hour" || !fh.Limited || used(fh) != 100 || *fh.Resets != now+600_000 {
		t.Errorf("five_hour: %+v", fh)
	}
	if wk := m["weekly"]; used(wk) != 40.5 || wk.Limited {
		t.Errorf("weekly: %+v", wk)
	}
	astra := m["weekly:gpt_6_astra"]
	if astra.Kind != "weekly_scoped" || astra.Label != "GPT-6 Astra" {
		t.Errorf("additional: %+v", astra)
	}
	checkNotStarted(t, astra)
	if cr := m["weekly:code_review"]; used(cr) != 12 {
		t.Errorf("code review: %+v", cr)
	}
	if c := m["credits"]; c.Kind != "credits" || c.Amount == nil || *c.Amount != 12.5 {
		t.Errorf("credits: %+v", c)
	}
	if ls[0].Plan != "ChatGPT Plus" || ls[0].Acct != acct.Hash("") {
		t.Errorf("plan/acct: %+v", ls[0])
	}
}

func TestOpenAINotStarted(t *testing.T) {
	body := `{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":null,"reset_after_seconds":null}}}`
	ls, err := mapOpenAI([]byte(body), &CodexAuth{AccountID: "a"}, now)
	if err != nil || len(ls) != 1 {
		t.Fatal(err, ls)
	}
	checkNotStarted(t, ls[0])
}

func fakeJWT(claims map[string]any) string {
	b, _ := json.Marshal(claims)
	return "eyJhbGciOiJub25lIn0." + base64.RawURLEncoding.EncodeToString(b) + ".sig"
}

func TestReadCodexAuth(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CODEX_HOME", dir)
	exp := now/1000 - 3600 // expired relative to testEnv's clock, so no request is made
	at := fakeJWT(map[string]any{"exp": exp, "https://api.openai.com/auth": map[string]any{"chatgpt_plan_type": "pro"}})
	auth := `{"auth_mode":"chatgpt","tokens":{"access_token":"` + at + `","id_token":"x","refresh_token":"r","account_id":"acct-1"}}`
	os.WriteFile(filepath.Join(dir, "auth.json"), []byte(auth), 0o600)
	a, err := ReadCodexAuth("/nonexistent")
	if err != nil {
		t.Fatal(err)
	}
	if a.Mode != "chatgpt" || a.AccountID != "acct-1" || a.Plan != "pro" || a.Expires.Unix() != exp || !a.HasToken() {
		t.Fatalf("%+v", a)
	}
	// The stale token must stop the poll before any request is made.
	var buf bytes.Buffer
	out := event.NewEmitter(&buf)
	e := testEnv()
	pollOpenAI(context.Background(), e, out)
	out.Flush()
	if !strings.Contains(buf.String(), "Codex sign-in on this machine has expired") || strings.Contains(buf.String(), at) {
		t.Fatalf("unexpected output: %s", buf.String())
	}
}

// --- Gemini (Antigravity) ---

const agQuotaFixture = `{"response": {"groups": [
  {"displayName": "Gemini Models", "description": "Models within this group: ...",
   "buckets": [
     {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.9289499, "resetTime": "2026-12-03T01:29:16Z"},
     {"bucketId": "gemini-5h", "window": "5h", "resetTime": "2026-11-26T06:29:16Z"}]},
  {"displayName": "Claude and GPT models",
   "buckets": [
     {"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 1},
     {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 1}]}],
 "description": "..."}}`

const agStatusFixture = `{"userStatus": {"name": "Redacted", "email": "Someone@Example.com",
  "planStatus": {"planInfo": {"planName": "Pro"}, "availablePromptCredits": 500},
  "userTier": {"id": "g1-ultra-tier", "name": "Google AI Ultra"}}}`

func TestGeminiMapping(t *testing.T) {
	ls, err := mapGemini([]byte(agQuotaFixture), []byte(agStatusFixture), now)
	if err != nil {
		t.Fatal(err)
	}
	m := byWindow(ls)
	if len(m) != 4 {
		t.Fatalf("want 4 windows: %+v", ls)
	}
	gw := m["gemini:weekly"]
	if gw.Group != "gemini" || gw.GroupLbl != "Gemini models" || gw.Kind != "weekly" || gw.Label != "Week" ||
		used(gw) != 7.11 || gw.Len != 604800 || *gw.Resets != time.Date(2026, 12, 3, 1, 29, 16, 0, time.UTC).UnixMilli() || gw.Src != "rpc" {
		t.Errorf("gemini:weekly %+v", gw)
	}
	// remainingFraction omitted by Connect JSON = 0 left: limited now.
	g5 := m["gemini:five_hour"]
	if g5.Kind != "session" || g5.Label != "5-hour" || used(g5) != 100 || !g5.Limited || g5.Resets == nil {
		t.Errorf("gemini:five_hour limited %+v", g5)
	}
	for _, id := range []string{"3p:weekly", "3p:five_hour"} {
		l := m[id]
		if l.Group != "3p" || l.GroupLbl != "Claude and GPT models" {
			t.Errorf("%s group %+v", id, l)
		}
		checkNotStarted(t, l)
	}
	if gw.Plan != "Google AI Ultra" || gw.Acct != acct.Email("someone@example.com") {
		t.Errorf("plan/acct %+v", gw)
	}
	// Without GetUserStatus the windows still map.
	ls, err = mapGemini([]byte(agQuotaFixture), nil, now)
	if err != nil || len(ls) != 4 || ls[0].Plan != "" {
		t.Errorf("no status: %v %+v", err, ls)
	}
	if _, err := mapGemini([]byte(`{"response":{"groups":[]}}`), nil, now); err == nil {
		t.Error("empty groups must fail")
	}
}

func TestGeminiNotRunning(t *testing.T) {
	var buf bytes.Buffer
	out := event.NewEmitter(&buf)
	e := testEnv()
	e.Home = t.TempDir()
	pollGemini(context.Background(), e, out)
	out.Flush()
	if !strings.Contains(buf.String(), `"level":"warn"`) || !strings.Contains(buf.String(), "Antigravity is not running") || strings.Contains(buf.String(), `"k":"limit"`) {
		t.Fatalf("got %s", buf.String())
	}
}

// --- Claude ---

const claudeFixture = `{
 "five_hour": {"utilization": 0, "resets_at": null},
 "seven_day": {"utilization": 28.0, "resets_at": "2026-11-28T05:59:59.720051+00:00"},
 "seven_day_opus": {"utilization": 100, "resets_at": "2026-11-28T05:59:59+00:00"},
 "seven_day_sonnet": null, "seven_day_oauth_apps": null,
 "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1250, "utilization": 25, "currency": "USD"},
 "limits": [
   {"kind": "weekly_all", "group": "weekly", "percent": 28, "severity": "normal", "resets_at": "2026-11-28T05:59:59.720051+00:00", "scope": null},
   {"kind": "weekly_scoped", "group": "weekly", "percent": 13, "severity": "normal", "resets_at": "2026-11-28T05:59:59+00:00",
    "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}},
   {"kind": "weekly_scoped", "group": "weekly", "percent": 100, "severity": "critical", "resets_at": "2026-11-28T05:59:59+00:00",
    "scope": {"model": null, "surface": {"display_name": "Claude Code"}}},
   {"kind": "something_new", "percent": 50}],
 "model_scoped": [{"display_name": "Fable", "utilization": 13, "resets_at": "2026-11-28T05:59:59+00:00"}]}`

func TestClaudeMapping(t *testing.T) {
	var rl claudeRL
	if err := json.Unmarshal([]byte(claudeFixture), &rl); err != nil {
		t.Fatal(err)
	}
	ls := mapClaude(&rl, "abc123abc123", "Max 20x", now, "endpoint")
	m := byWindow(ls)
	want := []string{"weekly", "weekly:fable", "weekly:claude_code", "five_hour", "weekly:opus", "credits"}
	if len(m) != len(want) {
		t.Fatalf("windows %v", keys(m))
	}
	for _, w := range want {
		if _, ok := m[w]; !ok {
			t.Errorf("missing %s (have %v)", w, keys(m))
		}
	}
	wk := m["weekly"]
	if wk.Kind != "weekly" || wk.Label != "Week" || used(wk) != 28 || wk.Len != 604800 || wk.Resets == nil ||
		*wk.Resets != time.Date(2026, 11, 28, 5, 59, 59, 720051000, time.UTC).UnixMilli() || wk.Plan != "Max 20x" || wk.Acct != "abc123abc123" {
		t.Errorf("weekly %+v", wk)
	}
	if f := m["weekly:fable"]; f.Kind != "weekly_scoped" || f.Label != "Fable" || used(f) != 13 {
		t.Errorf("fable %+v", f)
	}
	if cc := m["weekly:claude_code"]; !cc.Limited || used(cc) != 100 {
		t.Errorf("limited-now surface %+v", cc)
	}
	checkNotStarted(t, m["five_hour"])
	if m["five_hour"].Kind != "session" || m["five_hour"].Label != "5-hour" {
		t.Errorf("five_hour %+v", m["five_hour"])
	}
	if o := m["weekly:opus"]; !o.Limited || o.Label != "Opus" {
		t.Errorf("opus %+v", o)
	}
	c := m["credits"]
	if c.Kind != "credits" || used(c) != 25 || *c.Cap != 50 || *c.Amount != 37.5 || c.Currency != "USD" || c.Label != "Extra usage credits" {
		t.Errorf("credits %+v", c)
	}
}

func TestClaudeLegacyOnlyAndNoExtra(t *testing.T) {
	var rl claudeRL
	json.Unmarshal([]byte(`{"five_hour": {"utilization": 41, "resets_at": "2026-11-25T15:00:00Z"},
	  "seven_day": {"utilization": 10, "resets_at": "2026-11-30T00:00:00Z"},
	  "extra_usage": {"is_enabled": false}}`), &rl)
	m := byWindow(mapClaude(&rl, "h", "", now, "cli"))
	if len(m) != 2 || used(m["five_hour"]) != 41 || used(m["weekly"]) != 10 || m["weekly"].Src != "cli" {
		t.Fatalf("%+v", m)
	}
}

func TestClaudeCredentialParsing(t *testing.T) {
	tok, err := parseClaudeCred([]byte(`{"claudeAiOauth":{"accessToken":"sk-ant-oat-SYNTHETIC","refreshToken":"x","expiresAt":1000,
		"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"mcpOAuth":{}}`), "file")
	if err != nil {
		t.Fatal(err)
	}
	if tok.Fresh(time.UnixMilli(2000)) || !tok.Fresh(time.UnixMilli(500)) || !tok.HasToken {
		t.Fatal("expiry check")
	}
	if ClaudePlanName("", tok.Tier, tok.SubType) != "Max 20x" || ClaudePlanName("Ultra", tok.Tier, "") != "Ultra" || ClaudePlanName("", "", "pro") != "Pro" {
		t.Fatal("plan names")
	}
	b, _ := json.Marshal(tok)
	if strings.Contains(string(b), "SYNTHETIC") {
		t.Fatal("token leaks through JSON")
	}
	tok, _ = parseClaudeCred([]byte(`{"mcpOAuth":{}}`), "keychain")
	if tok.HasToken {
		t.Fatal("mcp-only item has no token")
	}
}

func TestClaudeHistory(t *testing.T) {
	home := t.TempDir()
	p := ClaudeHistoryPath(home)
	os.MkdirAll(filepath.Dir(p), 0o700)
	os.WriteFile(p, []byte(`{"version":1,"samples":[
	  {"t": 1000, "org": "org-a", "u": {"fh": 28, "sd": 29, "xu": 0}},
	  {"t": 3000, "org": "org-b", "u": {"sd": 90}},
	  {"t": 2000, "org": "org-a", "u": {"sd": 31, "xu": 12}}]}`), 0o600)
	ls, err := claudeHistory(home, ClaudeAccount{Acct: "h", OrgUUID: "org-a", Plan: "Max 20x"})
	if err != nil {
		t.Fatal(err)
	}
	m := byWindow(ls)
	if len(m) != 2 || used(m["weekly"]) != 31 || m["weekly"].TS != 2000 || m["weekly"].Src != "history" || used(m["credits"]) != 12 || m["weekly"].Resets != nil {
		t.Fatalf("%+v", ls)
	}
}

// TestClaudeCLI drives claudeCLIUsage against a stand-in binary that checks it
// receives exactly one get_usage control request and no user message.
func TestClaudeCLI(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "claude")
	script := `#!/bin/sh
read line
case "$line" in
  *'"type":"user"'*) echo '{"type":"error","msg":"user message sent"}'; exit 1;;
  *'"subtype":"get_usage"'*'"skip_behaviors":true'*) ;;
  *) echo '{"type":"error","msg":"unexpected"}'; exit 1;;
esac
echo '{"type":"system","subtype":"init"}'
echo '{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}'
echo '{"type":"control_response","response":{"subtype":"success","request_id":"tach-get-usage","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":null,"seven_day":{"utilization":28,"resets_at":"2026-11-28T06:00:00Z"},"limits":[{"kind":"weekly_all","percent":28,"resets_at":"2026-11-28T06:00:00Z"}]}}}}'
cat >/dev/null
`
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	rl, sub, err := claudeCLIUsage(context.Background(), bin)
	if err != nil {
		t.Fatal(err)
	}
	if sub != "max" || rl == nil || len(rl.Limits) != 1 {
		t.Fatalf("%v %+v", sub, rl)
	}
	m := byWindow(mapClaude(rl, "h", "", now, "cli"))
	if len(m) != 1 || used(m["weekly"]) != 28 {
		t.Fatalf("%+v", m)
	}

	// Not on a plan: rate_limits_available false.
	os.WriteFile(bin, []byte("#!/bin/sh\nread line\necho '{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"tach-get-usage\",\"response\":{\"subscription_type\":null,\"rate_limits_available\":false,\"rate_limits\":null}}}'\n"), 0o755)
	rl, _, err = claudeCLIUsage(context.Background(), bin)
	if err != nil || rl != nil {
		t.Fatalf("api-key case: %v %+v", err, rl)
	}
	// A CLI that exits without answering.
	os.WriteFile(bin, []byte("#!/bin/sh\nexit 0\n"), 0o755)
	if _, _, err := claudeCLIUsage(context.Background(), bin); err == nil {
		t.Fatal("want error")
	}
}

func TestSlug(t *testing.T) {
	for in, want := range map[string]string{"Fable": "fable", "GPT-6 Astra": "gpt_6_astra", " Claude Code ": "claude_code", "--": "", "Opus 5.5": "opus_5_5"} {
		if got := slug(in); got != want {
			t.Errorf("slug(%q) = %q, want %q", in, got, want)
		}
	}
}

func keys(m map[string]event.Limit) []string {
	var r []string
	for k := range m {
		r = append(r, k)
	}
	return r
}
