# Data sources

Research for the app (working name "Tach"): where every datum comes from, how sure we are, and what to build on.
Investigated 2026-11-25 on one Mac (Claude Code 2.1.330, Codex CLI 0.171.0 / Desktop 0.172.0, Antigravity 2.35.1, Gemini CLI 0.42.0) and two Linux remotes over SSH. Everything was read-only. Account ids, emails and host names are redacted.

Confidence labels used throughout:

- **V** verified on this machine (real file, real response, or string in the shipped binary)
- **D** documented by the vendor
- **R** community reverse-engineered, not exercised here
- **X** unavailable

## 1. What changes the design

1. **Limit windows are not uniform. Render them from data, never from a fixed "5h + weekly" layout.**
   - Codex (Pro plan) currently has **one** window: weekly (`window_minutes: 10080`). `secondary` is `null`. No 5-hour window exists on this account.
   - Claude's usage endpoint returns a server-driven `limits[]` list (kinds `session`, `weekly_all`, `weekly_scoped` per model or surface) plus `extra_usage` credits. The statusline only carries 5h and 7d.
   - Antigravity has two pools ("Gemini Models", "Claude and GPT models"), each with a 5h and a weekly bucket, reported as *remaining* fraction. `resetTime` is absent while a pool is untouched.
2. **Limits are per account, not per machine.** The Mac and remote A hold the same Claude account and the same Codex account (hash match), and a Codex rate-limit snapshot written on remote A (62%, same `resets_at`) equals what the Mac got from the usage endpoint. Poll once per account. Show per-machine *contribution* from token counts.
3. **Latency is less of a gap than expected.** Antigravity stores exact TTFT and streaming duration per request. Codex stores exact TTFT and duration per turn. Claude Code (2.1.304+) logs enough timestamps to estimate TTFT for about 78% of requests and tok/s for nearly all. OTel is an optional precision upgrade, not a requirement.
4. **The same Claude request can exist in several files and on several machines.** Dedupe on `message.id` globally (section 3.1).
5. **Not everything in a Claude transcript is Claude.** Third-party models run through Claude Desktop (`entrypoint: claude-desktop-3p`, e.g. `deepseek-flash`) and `<synthetic>` error stubs appear in the same files. They must not count toward the Claude subscription.
6. **The Keychain item `Claude Code-credentials` can be stale.** On this Mac its access token had expired 16 hours earlier, because sessions run under Claude Desktop. The Claude limits poll needs a fallback chain (section 4.1).

## 2. Matrix

Freshness: *live* = at write time, *poll* = when we ask, *session* = only while a session is active.

### A. Limits

| Datum | Claude | Codex | Antigravity |
|---|---|---|---|
| Windows that exist | `limits[]` rows + `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `seven_day_oauth_apps`, `seven_day_cowork`. **V** (binary schema), live response not fetched | `rate_limit.primary_window`, `secondary_window`, `additional_rate_limits[]`, `code_review_rate_limit`. **V** (live GET) | `groups[].buckets[]` with `window: "5h" \| "weekly"`. **V** (live local RPC) |
| % used | `utilization` 0-100. **V** schema | `used_percent`. **V** | `1 - remainingFraction`. **V** |
| Reset timestamp | `resets_at` ISO 8601 (endpoint), epoch s (statusline). **V**/**D** | `reset_at` epoch s, `reset_after_seconds`. **V** | `resetTime` ISO 8601, absent if pool unused. **V** |
| Plan tier | `subscriptionType`, `rateLimitTier` in credential blob. **V** | `plan_type`. **V** | `userTier.name`, `planStatus.planInfo.planName`. **V** |
| Currently limited | `quotaLimits.status: rejected` on the 429 transcript record; `anthropic-ratelimit-unified-status` header. **V** | `rate_limit.limit_reached`, `rate_limit_reached_type`. **V** | `remainingFraction == 0`. **V** shape, state not observed |
| Credits / extra usage | `extra_usage {is_enabled, monthly_limit, used_credits, utilization, currency}`. **V** schema | `credits {has_credits, unlimited, balance}`, `rate_limit_reset_credits`. **V** | `availablePromptCredits`, `availableFlowCredits`, `userTier.availableCredits[]`. **V** |
| Passive history (no polling) | **X** in transcripts except on rejection. Sparse samples in Claude Desktop `plan-usage-history.json`. **V** | Every `token_count` event carries a `rate_limits` snapshot. **V** | **X** |
| Freshness | poll | poll + live | poll, app must be running |

### B. Per-request usage

| Datum | Claude Code | Codex | Antigravity | Gemini CLI |
|---|---|---|---|---|
| Timestamp | `timestamp`. **V** | `timestamp`. **V** | `steps.metadata` f1. **V** | `timestamp`. **V** |
| Exact model id | `message.model`. **V** | preceding `turn_context.model`. **V** | `gen_metadata` f1.f19. **V** | `model`. **V** |
| Session, cwd | `sessionId`, `cwd`, `gitBranch`. **V** | `session_meta.id`, `cwd`. **V** | DB filename = cascade id; workspace in `conversation_summaries.db`. **V** | `sessionId`, project dir. **V** |
| Input tokens | `usage.input_tokens`. **V** | `usage.input_tokens` (includes cached). **V** | f2. **V** | `tokens.input`. **V** |
| Cache read | `cache_read_input_tokens`. **V** | `cached_input_tokens`. **V** | f5. **V** | `tokens.cached`. **V** |
| Cache write | `cache_creation_input_tokens` + 5m/1h split. **V** | `cache_write_input_tokens` (0 in all samples). **V** | f4, never populated. **V** | **X** |
| Output tokens | `output_tokens`. **V** | `output_tokens`. **V** | f3. **V** | `tokens.output`. **V** |
| Reasoning tokens | `output_tokens_details.thinking_tokens`. **V** | `reasoning_output_tokens`. **V** | f9. **V** | `tokens.thoughts`. **V** |
| Duration | derived: last block ts minus `api-request` ts. **V** est. | per turn: `task_complete.duration_ms`. **V** | `streaming_duration`. **V** | derived from timestamps |
| TTFT | derived, ~78% coverage. **V** est. | per turn: `time_to_first_token_ms`. **V** | `time_to_first_token`. **V** | **X** |
| Output tok/s | derived. **V** est. | per turn only, est. | exact: f3 / `streaming_duration`. **V** | est. |
| Stop reason | `message.stop_reason`. **V** | `task_complete` / `turn_aborted.reason`. **V** | `steps.status`, `error_details`. **V** shape | **X** |
| Errors, retries | `system/api_error` (`retryAttempt`, `retryInMs`), `isApiErrorMessage`, `apiErrorStatus`. **V** | `error`, `stream_error` events (none in sample). **D** | `retries`, `retry_infos` fields. **V** names | **X** |
| Tier, speed, effort | `usage.service_tier`, `usage.speed`, `effort`. **V** | `thread_settings_applied.service_tier`, `turn_context.effort`. **V** | effort is in the model label. **V** | **X** |
| Subagent vs main | `isSidechain`, `agentId`, `subagents/agent-*.jsonl`. **V** | `session_meta.thread_source`, `source.subagent`. **V** | `conversation_summaries.parent_conversation_id`, `nesting_depth`. **V** | `kind`. **V** |
| Dedupe key | `message.id` | `response_id` | label `request_id` | `sessionId` + `id` |

### C. Fleet

| Datum | Source | Confidence |
|---|---|---|
| Last seen | newest event timestamp per machine; SSH poll success time | **V** |
| Active sessions, Claude | `~/.claude/sessions/<pid>.json` with `status: busy \| idle`, `updatedAt`, `cwd`, `sessionId`. Check the pid is alive: remote A had 68 files, mostly stale. | **V** |
| Active sessions, Codex | no registry found. Infer from rollout mtime and `state_5.sqlite threads.updated_at_ms`. | **V** est. |
| Active sessions, Antigravity | `conversation_summaries.db` `status`, `not_fully_idle`; `daemon/*.json` proves a language server is up. | **V** |
| Tokens/hour | sum of request events | **V** |

## 3. Sources in detail

### 3.1 Claude Code transcripts

Globs:

- `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`
- `~/.claude/projects/<cwd-slug>/<sessionId>/subagents/agent-<id>.jsonl`
- `~/.claude/projects/ssh-<sessionId>/…` (Claude Desktop's local mirror of a session that ran on a remote)
- `~/Library/Application Support/Claude/local-agent-mode-sessions/**/<uuid>.jsonl` (Cowork; 285 files here)
- Honour `CLAUDE_CONFIG_DIR`. Linux is the same layout under `~/.claude`.

One `assistant` record, content redacted:

```json
{
  "type": "assistant",
  "timestamp": "2026-11-26T02:17:58.577Z",
  "sessionId": "<uuid>", "cwd": "/Users/<user>", "gitBranch": "HEAD",
  "isSidechain": false,
  "requestId": "req_011C…", "requestRef": "<uuid of api-request record>",
  "apiBlockIndex": 0,
  "thinkingDurationMs": 66118,
  "effort": "high", "entrypoint": "claude-desktop", "version": "2.1.330",
  "requestedModel": "claude-mythos-5-2",
  "message": {
    "id": "msg_011C…", "model": "claude-mythos-5-2", "stop_reason": "tool_use",
    "content": [{"type": "thinking"}],
    "usage": {
      "input_tokens": 2,
      "cache_creation_input_tokens": 54335,
      "cache_read_input_tokens": 43395,
      "output_tokens": 6240,
      "output_tokens_details": {"thinking_tokens": 5646},
      "cache_creation": {"ephemeral_1h_input_tokens": 54335, "ephemeral_5m_input_tokens": 0},
      "server_tool_use": {"web_search_requests": 0, "web_fetch_requests": 0},
      "service_tier": "standard", "speed": "standard", "inference_geo": "global"
    }
  }
}
```

The request-start record that pairs with it (2.1.304 and later):

```json
{"type": "api-request", "id": "<uuid>", "timestamp": "2026-11-26T02:16:51.053Z",
 "querySource": "sdk", "params": {"model": "claude-mythos-5-2", "max_tokens": 128000,
 "output_config": {"effort": "high"}}}
```

Measured over the last 30 days on this Mac: 1,271 files, 5.96 GB, 1.16 M lines, 361,406 assistant lines, **160,314 unique requests**.

Pitfalls, all observed:

- **One request, many lines.** Each content block is its own `assistant` line with the same `message.id` and the same final `usage`. Counting lines overcounts 2.25x.
- **Same request in several files.** 8,970 of 141,867 message ids appeared in more than one file, 5,992 under more than one `sessionId` (resumed and forked sessions copy history).
- **Zero-usage twins.** 71 ids had one record with real usage and one with all zeros. Take the per-field maximum.
- **Cross-machine copies.** `~/.claude/projects/ssh-<id>/<id>.jsonl` on the Mac was byte-identical in size (13,513,608 bytes) to `~/.claude/projects/-home-<user>/<id>.jsonl` on remote A. Their `cwd` is a Linux path. Attribute these to the remote and drop the mirror when that remote is also collected.
- **Subagents appear twice over time.** Older versions inline them in the parent file (`isSidechain: true` + `agentId`), newer ones write `subagents/agent-*.jsonl`. Both forms exist in the same month.
- **Non-Claude rows.** `<synthetic>` (449), `deepseek-flash`, `moonshotai/…` and similar via `claude-desktop-3p`.
- **`requestId` is not always there.** In a 10-day sample 11,441 assistant lines had none (`deepseek-flash` 6,639, `claude-sonnet-5-5` 4,630, `<synthetic>` 169), so it cannot be the primary key.
- **No cost field.** Cost must come from the price table.
- **Rate-limit state** appears only on rejection:
  ```json
  {"error": "rate_limit", "isApiErrorMessage": true, "apiErrorStatus": 429,
   "quotaLimits": {"status": "rejected", "resetsAt": 1789455600, "rateLimitType": "five_hour",
                   "overageStatus": "rejected", "overageDisabledReason": "out_of_credits",
                   "isUsingOverage": false}}
  ```
- **Other useful system records:** `system/api_error` (`retryAttempt`, `retryInMs`, `maxRetries`), `system/turn_duration` (`durationMs`), `system/model_refusal_fallback`, `system/compact_boundary`.

Timing derivation, validated on 8,669 requests from the last 4 days:

- duration = last block `timestamp` − `api-request.timestamp`
- TTFT ≈ first block `timestamp` − first block's `thinkingDurationMs` (thinking) or `toolInputStreamMs` (tool_use) − `api-request.timestamp`
- tok/s ≈ `output_tokens` / (duration − TTFT)
- Coverage: 6,797 of 8,669 (78%). The rest start with a text block, which has no duration field; for those only an upper bound exists. No negative values occurred.
- Results look sane: Opus 5.5 TTFT p50 1.04 s, p95 3.74 s, 121 tok/s; Fable 5.2 p50 0.66 s, 114 tok/s; Mythos 5.2 p50 0.92 s, 102 tok/s.
- Before 2.1.304 there is no `api-request` record, so no timing at all.

### 3.2 Claude limits

Three mechanisms exist. None was exercised live, because the stored token was expired and refreshing it was out of scope.

**a. OAuth usage endpoint** (**V** in binary, **R** for live shape)

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <claudeAiOauth.accessToken>
anthropic-beta: oauth-2025-04-20
```

The CLI also uses `?skip_spend=1` and `?cedar_ember=1&skip_spend=1`. Needs scope `user:profile`. Response per the CLI's own schema: `five_hour`, `seven_day`, `seven_day_oauth_apps`, `seven_day_opus`, `seven_day_sonnet` (each `{utilization: 0-100, resets_at: ISO}` or null), `limits[]` (rows with a kind of `session`, `weekly_all` or `weekly_scoped`, a group, utilization, reset, a scope naming a model or surface with a display label, a severity of `normal`/`warning`/`critical`, and a headline flag), and `extra_usage {is_enabled, monthly_limit, used_credits, utilization, currency}`.

Credential locations:

- macOS: Keychain generic password, service `Claude Code-credentials`. Shape: `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt" (ms), "scopes": [...], "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}, "mcpOAuth": {...}}`. Reading it with `/usr/bin/security` produced no prompt here.
- Linux: `~/.claude/.credentials.json`, same shape plus `refreshTokenExpiresAt`. On remote A the token was fresh (1.9 h left).
- `~/.claude.json` → `oauthAccount` has `accountUuid`, `organizationUuid`, `planDisplayName`, `hasExtraUsageEnabled`: the account identity for "poll once per account".

**b. SDK control request `get_usage`** (**V** in binary, marked experimental there)

`{"subtype": "get_usage", "skip_behaviors": true}` over the stream-json control channel returns `subscription_type`, `rate_limits_available`, and `rate_limits {five_hour, seven_day, seven_day_opus, seven_day_sonnet, seven_day_oauth_apps, model_scoped[{display_name, utilization, resets_at}], extra_usage}`. The CLI does its own auth and refresh, so the app never touches a token.

**c. Statusline JSON** (**D**)

The statusline command receives `rate_limits.five_hour.{used_percentage, resets_at}` and `rate_limits.seven_day.{…}` (epoch seconds) on stdin, after the first API response of a session, for Pro/Max subscribers. It has no per-model rows and no credits. It is a terminal-UI feature; 94% of requests on this Mac came from `claude-desktop`, where no statusline is configured.

**Response headers** (**V** names in binary): `anthropic-ratelimit-unified-status`, `-5h-reset`, `-7d-reset`, `-representative-claim`, `-overage-status`, `-overage-utilization`, `-fallback`. Only a proxy would see them.

**Bonus:** `~/Library/Application Support/Claude/plan-usage-history.json` holds `{"samples": [{"t": <ms>, "org": "<uuid>", "u": {"fh": 28, "sd": 29, "xu": 0}}]}`. 24 samples in a month: useful for backfill only.

### 3.3 Claude Code OpenTelemetry

Off by default. Enable with (**D**):

```
CLAUDE_CODE_ENABLE_TELEMETRY=1
OTEL_LOGS_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf        # or grpc, http/json
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
OTEL_RESOURCE_INCLUDE_HOST=1                     # 2.1.326+, adds host.name
OTEL_LOGS_EXPORT_INTERVAL=5000                   # default
OTEL_METRIC_EXPORT_INTERVAL=60000                # default
```

Event `claude_code.api_request` attributes (**V** in binary 2.1.330): `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `cache_creation_5m_tokens`, `cache_creation_1h_tokens`, `cost_usd`, `cost_usd_micros`, `duration_ms`, `ttft_ms` (when known), `request_id`, `client_request_id`, `speed`, `query_source`, `effort`, plus `session.id`, `user.account_uuid`, `organization.id`.

The public docs list `ttft_ms` only on the beta trace span `claude_code.llm_request` (needs `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`, `OTEL_TRACES_EXPORTER=otlp`), alongside `first_content_ms`, `stop_reason`, `attempt`. Treat `ttft_ms` on the event as present-but-undocumented.

`claude_code.api_error`: `model`, `error`, `status_code`, `duration_ms`, `attempt`, `request_id`. Metrics: `claude_code.token.usage`, `claude_code.cost.usage`, `claude_code.session.count`, `claude_code.active_time.total`.

Missing from OTel: `cwd`/project, and anything from before it was switched on.

### 3.4 Codex rollouts

Globs:

- `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<threadId>.jsonl` (16 files, 56 MB for the last 10 days here)
- `~/.codex/archived_sessions/rollout-*.jsonl.zst` (**zstd-compressed**; 857 files, 2.1 GB)
- `~/.codex/state_5.sqlite` table `threads` (`id`, `rollout_path`, `model`, `tokens_used`, `cwd`, `thread_source`, `updated_at_ms`, `archived`): a cheap index, 1,199 threads, 41 G tokens
- `~/.codex/thread_history_1.sqlite` (`thread_turns` with `duration_ms`, `status`, `error_json`; `thread_items`)
- Honour `CODEX_HOME`. The Desktop app and the CLI share `~/.codex`; `~/Library/Application Support/Codex` is only the Electron profile.

Per-response usage record (the one to ingest):

```json
{"timestamp": "2026-11-14T23:17:22.677Z", "ordinal": 19, "type": "token_usage_record",
 "payload": {"thread_id": "<uuid>", "turn_id": "<uuid>", "root_turn_id": "<uuid>",
  "response_id": "<55 chars>",
  "usage": {"input_tokens": 20932, "cached_input_tokens": 13056, "cache_write_input_tokens": 0,
            "output_tokens": 146, "reasoning_output_tokens": 31, "total_tokens": 21078},
  "turn_token_usage": {…}, "thread_token_usage": {…}}}
```

Rate-limit snapshot, written after every response:

```json
{"type": "event_msg", "payload": {"type": "token_count",
  "info": {"total_token_usage": {…}, "last_token_usage": {…}, "model_context_window": 475000},
  "rate_limits": {"limit_id": "codex", "plan_type": "pro",
    "primary": {"used_percent": 15.0, "window_minutes": 10080, "resets_at": 1796076526},
    "secondary": null,
    "credits": {"has_credits": false, "unlimited": false, "balance": "0"},
    "rate_limit_reached_type": null}}}
```

Turn timing:

```json
{"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "<uuid>",
  "started_at": 1795488391, "completed_at": 1795488409,
  "duration_ms": 17324, "time_to_first_token_ms": 2499}}
```

Other records: `session_meta` (`originator` "Codex Desktop" / "codex-tui", `cli_version`, `thread_source` user / subagent / guardian_review, `forked_from_id`, `subagent_history_start_ordinal`), `turn_context` (`model`, `effort`, `cwd`), `thread_settings_applied` (`service_tier`: default / priority / ultrafast), `turn_aborted` (`reason`).

Pitfalls:

- **Forked and subagent threads replay the parent's history** at the top of the file, all stamped with the fork time. Skip records with `ordinal < session_meta.subagent_history_start_ordinal`. In the sample, a replayed `task_complete` carried the parent's duration.
- `input_tokens` **includes** cached tokens. Uncached input = `input_tokens − cached_input_tokens`.
- `token_usage_record` is new. Older files have only cumulative `token_count`; use `last_token_usage` there and never sum `total_token_usage`.
- TTFT and duration are per turn (a turn is many responses). Per-response latency is not recorded; it can only be estimated from gaps between events.
- `codex-auto-review` (guardian) threads are a separate model with their own pricing.
- Models seen: `gpt-6.2-sol`, `gpt-6.2-astra`, `gpt-6-astra`, `gpt-6.1-terra`, `codex-auto-review`.

### 3.5 Codex limits

Verified with one live GET:

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <tokens.access_token>
ChatGPT-Account-Id: <tokens.account_id>
```

```json
{"plan_type": "pro",
 "rate_limit": {"allowed": true, "limit_reached": false,
   "primary_window": {"used_percent": 62, "limit_window_seconds": 604800,
                      "reset_after_seconds": 416474, "reset_at": 1796076526},
   "secondary_window": null},
 "code_review_rate_limit": null, "additional_rate_limits": null,
 "model_usage": {"gpt-6-astra": {"available": true, "available_at": null, "credits_would_enable": false}},
 "credits": {"has_credits": false, "unlimited": false, "overage_limit_reached": false, "balance": "0"},
 "spend_control": {"reached": false, "individual_limit": null},
 "rate_limit_reached_type": null,
 "rate_limit_reset_credits": {"available_count": 1, "applicable_available_count": 0}}
```

The response also includes `user_id`, `account_id` and `email`.

Auth: `~/.codex/auth.json` → `{"auth_mode": "chatgpt", "tokens": {"id_token", "access_token" (JWT, about 6 days left here), "refresh_token", "account_id"}, "last_refresh"}`. Same file on Linux.

Alternatives: `codex -s read-only -a never app-server` with JSON-RPC `account/rateLimits/read` (**R**, used by CodexBar; the CLI owns auth). Other endpoints in the binary: `/wham/rate-limit-reset-credits`, `/wham/usage/thread_usage/query`.

Because every rollout carries snapshots, Codex limit history is dense and free from any machine we collect. The endpoint is only needed when nothing has run recently.

### 3.6 Codex OpenTelemetry

Off by default (**D**). In `~/.codex/config.toml`:

```toml
[otel]
exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/logs", protocol = "binary" } }
log_user_prompt = false
```

Events: `codex.api_request` (attempt, status, duration), `codex.sse_event` (token counts on `response.completed`), `codex.websocket_request`, `codex.tool_result`. Metrics: `codex.api_request.duration_ms`, `codex.sse_event.duration_ms`. Names present in the 0.171 binary but not in the docs (**V** names only): `codex.turn.ttft.duration_ms`, `codex.turn.ttfm.duration_ms`, `codex.turn.token_usage.*`, `codex.turn.cost_microusd`, `codex.responses_api_engine_service_ttft.duration_ms`, `…_tbt.duration_ms`.

### 3.7 Antigravity

Three layers, all verified locally.

**Discovery.** `~/.gemini/antigravity/daemon/hub_<port>.json` → `{"pid", "httpsPort", "httpPort", "lsVersion", "csrfToken"}`. On the Linux remote the files are named `daemon/ls_<hash>.json` (seen, contents not inspected). The running `language_server` no longer has `--csrf_token` on its command line (it now reads a token from stdin), so tools that scrape `ps` for the token fail on this version.

**Quota RPC** (Connect protocol, JSON, loopback only):

```
POST http://127.0.0.1:<httpPort>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
Content-Type: application/json
Connect-Protocol-Version: 1
X-Codeium-Csrf-Token: <csrfToken>

{}
```

```json
{"response": {"groups": [
  {"displayName": "Gemini Models",
   "description": "Models within this group: Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Argon, Gemini 4 Hydrogen, Orchestrator (…), Gemini 3.8 Flash",
   "buckets": [
     {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.9289499, "resetTime": "2026-12-03T01:29:16Z"},
     {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.7154262, "resetTime": "2026-11-26T06:29:16Z"}]},
  {"displayName": "Claude and GPT models",
   "description": "Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B",
   "buckets": [
     {"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 1},
     {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 1}]}],
 "description": "Within each group, models share a weekly limit and a 5-hour limit. Quota is consumed proportionally to the cost of the tokens. …"}}
```

`GetUserStatus` on the same service returns `userStatus.userTier` ("Google AI Ultra"), `planStatus` (`availablePromptCredits`, `availableFlowCredits`, monthly allowances) and 27 `clientModelConfigs[]`, each with `label`, `modelId` (e.g. `gemini-4-neon-high`, `claude-opus-5-5-medium`) and `quotaInfo {remainingFraction, resetTime}`. The per-model `quotaInfo` equals the pool's **5h** bucket, so `GetUserStatus` alone hides the weekly limit.

So Antigravity does serve Claude and GPT models, and they draw on a separate pool from Gemini. Neither pool touches the Anthropic or OpenAI subscriptions.

**Per-request usage.** One SQLite file per conversation: `~/.gemini/antigravity/conversations/<cascadeId>.db` (19 files, 94 MB here; 105 on remote A). Open read-only with `immutable=1`. Tables hold protobuf blobs:

- `steps(idx, step_type, status, metadata, …)`. Steps of `step_type = 15` are model responses. `metadata`: f1 = created-at `{seconds, nanos}`, f9 = `ModelUsageStats`, f20.f3 = index into `gen_metadata`.
- `gen_metadata(idx, data)`. `data` f1 = `ChatModelMetadata`: f4 = `ModelUsageStats`, f11 = `time_to_first_token` (Duration), f12 = `streaming_duration` (Duration), f19 = response model (`gemini-4-neon`), f21 = display name, f20 = repeated key/value labels (`request_id`, `cascade_id`, `used_claude`, `used_non_gemini_model`).
- `ModelUsageStats`: f2 `input_tokens`, f3 `output_tokens`, f4 `cache_write_tokens`, f5 `cache_read_tokens`, f6 `api_provider`, f9 `thinking_output_tokens`, f10 `response_output_tokens`, f11 `response_id`.

Field names come from descriptors embedded in the `language_server` binary; field numbers were matched against real rows (`output = thinking + response` held). Decoded sample:

```
response_model: "gemini-4-neon"   display: "Gemini 4 Neon (Medium)"
input_tokens: 4693   cache_read_tokens: 23236
output_tokens: 2753  (thinking 1794 + response 959)
time_to_first_token: 4.375 s      streaming_duration: 21.246 s   → 130 tok/s
labels: request_id=<trajectory>-3, used_claude=false
```

Across 619 generations here: TTFT p50 7.2 s, p95 31.5 s; output p50 200 tok/s. Only Gemini models were used on this Mac.

Other state: `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb` has `antigravityUnifiedStateSync.userStatus` (a cached copy, not decoded) and `…oauthToken` (not read). `conversation_summaries.db` lists conversations with `status`, `workspace_uris`, `parent_conversation_id`.

When the app is closed there is no local RPC. Fallbacks, both **R**: the `agy` CLI (`agy -p /usage --output-format json`; not installed here) and Google's `cloudcode-pa.googleapis.com` internal API with the stored OAuth token.

### 3.8 Gemini CLI

`~/.gemini/tmp/<project>/chats/session-*.jsonl`. Records of `type: "gemini"` carry `tokens {input, output, cached, thoughts, tool, total}`, `model`, `timestamp`. No timing, no limits. One session from May on this Mac, and its OAuth token expired weeks ago. Reports say Gemini CLI was wound down for consumer accounts in mid-2026 in favour of Antigravity (not verified). Lowest priority; ingest if present.

## 4. Recommended collection architecture

### 4.1 Limits: one poller per account

Identify accounts by a hash of `oauthAccount.accountUuid` (Claude), `tokens.account_id` (Codex), Google account (Antigravity). Poll each once, from the Mac.

| Provider | Order of preference | Cadence |
|---|---|---|
| Codex | 1. newest `token_count.rate_limits` from any collected machine. 2. `GET /wham/usage` when the newest snapshot is older than 5 min. | passive + 5 min |
| Antigravity | 1. `RetrieveUserQuotaSummary` on the local language server. 2. the same call run on a remote that has a `daemon/ls_*.json`, via SSH (untested). 3. show "open Antigravity to refresh" with the last value and its age. | 2 min while running |
| Claude | 1. `get_usage` control request through the user's own `claude` binary (needs a spike: confirm it answers without starting a model turn). 2. `GET /api/oauth/usage` with a non-expired stored token. 3. statusline capture file, if the user opted in. 4. last known value with its age. | 5 min; 1 min when above 80% |

Never refresh Claude's OAuth token ourselves: the refresh token rotates and we would race the CLI. Never write to any vendor credential store.

Burn rate, pace and projected exhaustion come from our own `limit_samples` series: fit used% over the last 30-60 minutes, compare to elapsed% of the window, extrapolate to 100%. Between polls, interpolate with local token counts weighted by price (Antigravity states quota is consumed "proportionally to the cost of the tokens").

### 4.2 Usage: tail local files

FSEvents on the globs in section 3, plus a 60 s sweep. Keep `(path, inode, size, byte_offset)` per file and parse only appended bytes. Pre-filter Claude lines on the substrings `"type":"assistant"`, `"type":"api-request"`, `"type":"system"` before JSON parsing: most of the 6 GB is message content we never need, and a full scan is slow even with the filter. Codex archives need zstd and are immutable: read each once.

### 4.3 Remotes: SSH pull with a one-shot collector

Recommendation: **(a) agentless SSH pull**, with a small static collector binary that the app copies to `~/.cache/<app>/collector` on the remote and runs per poll. No daemon, no open port, no config change on the remote.

```
ssh <host> ~/.cache/<app>/collector scan --cursor <base64 cursor>
→ NDJSON of compact events + new cursor on stdout
```

| | (a) SSH pull + one-shot collector | (b) push daemon | (c) OTel over the tailnet |
|---|---|---|---|
| Remote setup | none beyond working `ssh <host>` | install + service unit + auth | env vars / config per tool per host |
| Mac asleep or remote offline | nothing lost; next poll resumes from the cursor | needs a spool | events dropped |
| Backfill of history | yes, full | yes | no |
| Antigravity, limits snapshots, cwd | yes | yes | no |
| Exact Claude TTFT | no (estimate) | no | yes |
| Listener on the Mac | no | yes | yes |
| Zero remotes | no-op | no-op | no-op |

Why not raw `tail` over SSH: transcripts are about 37 KB per request, almost all content. Remote A holds 2.6 GB of Claude data, 2.7 GB of Codex and 4.3 GB of Antigravity. The collector reduces each request to a ~250-byte event on the remote, and Antigravity's SQLite and protobuf cannot be parsed with shell tools anyway. Keep a `grep`/`tail` fallback for hosts where the binary cannot run.

Use the user's own `ssh` and `~/.ssh/config`, so ProxyCommand, jump hosts and tailnets work without the app knowing about them. Poll every 60 s while the remote is active, backing off to 10 min when idle or unreachable.

OTel stays an opt-in extra for users who want exact Claude TTFT: an OTLP/HTTP receiver in the app on `127.0.0.1:4318`, joined to transcript events on `request_id`.

Observed on the remotes: remote A (Linux x86_64) has `claude` 2.1.332 and `codex` 0.171.0, 11,285 Claude files, 229 live Codex rollouts, 105 Antigravity conversations, same accounts as the Mac. Remote B has Codex only (2.3 GB in 43 files) and an empty Claude dir. Remote C refused the connection.

### 4.4 Dedupe and attribution

| Tool | Primary key | Fallback |
|---|---|---|
| Claude Code | `message.id` | `requestId`, then `sessionId` + `uuid` |
| Codex | `response_id` | `thread_id` + `ordinal` |
| Antigravity | label `request_id` | cascade id + `gen_metadata.idx` |
| Gemini CLI | `sessionId` + `id` | |

Upsert on `(tool, key)`, keeping the per-field maximum of token counts. Machine = the host whose disk the canonical file lives on; for Claude `ssh-*` mirrors, the remote. Subscription attribution (our inference, not a vendor statement): Claude records count toward the Claude plan only when `message.model` starts with `claude-` and `entrypoint` is not `claude-desktop-3p`.

### 4.5 Latency options, ranked

1. **Log timestamps** (default). Antigravity: exact per request. Codex: exact per turn. Claude: estimated per request, 78% TTFT coverage, 2.1.304+ only.
2. **OTel into an embedded receiver** (opt-in). Exact `duration_ms` for Claude and Codex requests, `ttft_ms` for Claude. Needs env or config changes on every machine, has no backfill, and loses events while the Mac sleeps.
3. **Logging proxy** via `ANTHROPIC_BASE_URL` (not recommended). It would give exact wire timing and the rate-limit headers, but it puts the app in the request path of every call, changes CLI behaviour that is tied to the default API host (the docs note trace propagation is one such case), handles bearer tokens, and makes an outage of the app an outage of the tools.

UI labels:

| Metric | Claude Code | Codex | Antigravity |
|---|---|---|---|
| TTFT | "est." | "per turn" | exact |
| tok/s | "est." | "est., per turn" | exact |
| Duration | "est." | exact per turn | exact (streaming) |

Show the sample count next to any percentile, and show "n/a" below about 20 samples.

## 5. Pricing

Source: LiteLLM's `model_prices_and_context_window.json` (`https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`, 5.2 MB, 7,179 entries; the repo is MIT outside its enterprise directory, but GitHub reports a mixed licence, so confirm before bundling). Fetched today, it has every target model with cache-read, cache-write (5 min and 1 h), tier variants (`_priority`, `_ultrafast`, `_flex`, `_batches`) and the >272k context step. `https://models.dev/api.json` is a good cross-check but lacks `claude-mythos-5-2`.

USD per million tokens as listed there today (third-party table; confirm against vendor pages before shipping):

| Model | Input | Output | Cache read | Cache write 5m | Cache write 1h |
|---|---|---|---|---|---|
| claude-opus-5-5 | 4 | 20 | 0.20 | 5 | 8 |
| claude-fable-5-2 | 8 | 40 | 0.20 | 10 | 16 |
| claude-mythos-5-2 | 8 | 40 | 0.20 | 10 | 16 |
| gpt-6.2-sol | 2 | 10 | 0.10 | 2.5 | |
| gpt-6.2-astra | 8 | 40 | 0.40 | 10 | |
| gemini-4-neon | 3 | 15 | 0.15 | | |

Updating: bundle a trimmed snapshot (only the providers we track, a few KB) so the app works offline; refresh daily from a JSON file in our own repo that CI regenerates from LiteLLM and opens a PR on change; allow per-model overrides in settings. Store token counts, not dollars, and compute cost at query time so a price fix corrects history. Unknown model → show tokens and "unpriced", never $0.

Details that move cost materially: Claude 1 h cache writes cost more than 5 min (use the `cache_creation` split), Claude `speed: fast` and Codex `service_tier: ultrafast | priority` have their own rates, and GPT prices step up above 272k context. Claude Code's OTel `cost_usd` is a free cross-check where enabled.

## 6. Local store

SQLite in `~/Library/Application Support/<app>/`, WAL mode.

```sql
CREATE TABLE machine (
  id INTEGER PRIMARY KEY, name TEXT UNIQUE, kind TEXT,        -- local | ssh
  ssh_host TEXT, last_seen_ms INTEGER, last_error TEXT);

CREATE TABLE account (
  id INTEGER PRIMARY KEY, provider TEXT, id_hash TEXT, plan TEXT,
  UNIQUE(provider, id_hash));

CREATE TABLE request_event (
  tool TEXT NOT NULL,              -- claude_code | codex | antigravity | gemini_cli
  dedupe_key TEXT NOT NULL,
  ts_ms INTEGER NOT NULL,
  machine_id INTEGER NOT NULL, account_id INTEGER,
  provider TEXT, model TEXT NOT NULL,
  session_id TEXT, cwd TEXT, is_subagent INTEGER,
  input_tok INTEGER, cache_read_tok INTEGER,
  cache_write_5m_tok INTEGER, cache_write_1h_tok INTEGER,
  output_tok INTEGER, reasoning_tok INTEGER,
  duration_ms INTEGER, ttft_ms INTEGER, timing_quality TEXT,   -- exact | estimated | turn | none
  stop_reason TEXT, error TEXT, retries INTEGER,
  service_tier TEXT, speed TEXT, effort TEXT,
  counts_toward TEXT,              -- which subscription pool, or null
  PRIMARY KEY (tool, dedupe_key)) WITHOUT ROWID;
CREATE INDEX request_event_ts ON request_event(ts_ms);

CREATE TABLE turn_event (          -- Codex turns: exact duration and TTFT
  tool TEXT, turn_id TEXT, ts_ms INTEGER, machine_id INTEGER, model TEXT,
  duration_ms INTEGER, ttft_ms INTEGER, status TEXT,
  PRIMARY KEY (tool, turn_id)) WITHOUT ROWID;

CREATE TABLE limit_sample (
  account_id INTEGER, window_id TEXT,     -- five_hour, weekly, weekly:<model>, gemini-5h, 3p-weekly, credits
  ts_ms INTEGER, used_pct REAL, resets_at_ms INTEGER,
  window_seconds INTEGER, label TEXT, limited INTEGER, source TEXT,
  PRIMARY KEY (account_id, window_id, ts_ms)) WITHOUT ROWID;

CREATE TABLE rollup_hour (
  hour_ms INTEGER, machine_id INTEGER, tool TEXT, model TEXT,
  requests INTEGER, errors INTEGER,
  input_tok INTEGER, cache_read_tok INTEGER, cache_write_tok INTEGER,
  output_tok INTEGER, reasoning_tok INTEGER,
  ttft_hist BLOB, tps_hist BLOB,          -- fixed log-scale buckets, so percentiles merge
  PRIMARY KEY (hour_ms, machine_id, tool, model)) WITHOUT ROWID;

CREATE TABLE file_cursor (
  machine_id INTEGER, path TEXT, inode INTEGER, size INTEGER, offset INTEGER, mtime_ms INTEGER,
  PRIMARY KEY (machine_id, path));

CREATE TABLE active_session (
  machine_id INTEGER, tool TEXT, session_id TEXT, cwd TEXT, status TEXT, updated_ms INTEGER,
  PRIMARY KEY (machine_id, tool, session_id));
```

Percentiles: compute p50/p95 straight from `request_event` for windows up to 30 days (at most a few hundred thousand rows), and from the merged histograms beyond that. Averages of hourly percentiles would be wrong.

Volume, from real numbers: this Mac produced about 5,300 Claude requests a day (160 k a month). At roughly 250 bytes a row plus index that is about 60-80 MB a month for a very heavy user, per machine. Keep raw events 90 days and rollups indefinitely (around 15 k rollup rows a month). Limit samples at one per 2-5 minutes per window are negligible. First-run backfill here means scanning about 8 GB locally and about 10 GB on remote A: do it newest-first, in the background, and cap it at 30 days by default.

Cadences:

| What | Cadence |
|---|---|
| Local files | FSEvents + 60 s sweep |
| Remote pull | 60 s active, up to 10 min idle |
| Codex limits | passive; endpoint if stale > 5 min |
| Claude limits | 5 min; 1 min above 80% |
| Antigravity limits | 2 min while running |
| Active sessions | 15 s local, with each remote pull |
| Price table | daily |

## 7. Gaps

| Gap | What the UI should say |
|---|---|
| Claude TTFT for text-first responses (22%) and for versions before 2.1.304 | "est." with sample count; exclude from percentiles |
| Codex per-request latency | show per-turn values, labelled |
| Claude limit % between polls | interpolated; show the age of the last real sample |
| Antigravity limits when the app is closed | last value, greyed, "as of 14:02" |
| Antigravity pool with no `resetTime` | "not started" instead of a countdown |
| Usage on claude.ai, ChatGPT web or mobile | not visible; it still moves the limit bars. Say that limits include usage the app cannot itemise. |
| Machines not configured as remotes | same: limit moves, no events |
| Cost | "API-equivalent", never "spend" |
| Unpriced models | tokens only |
| Remote unreachable | per-machine "last seen" and the error |

## 8. Risks and fallbacks

| Risk | Fallback |
|---|---|
| `/api/oauth/usage` is undocumented and its query flags change by release | `get_usage` through the CLI; statusline capture; last known value |
| Anthropic's policy on third-party use of subscription OAuth tokens (restricted in early 2026; recheck the current terms) | make direct token use opt-in; default to asking the user's own `claude` binary |
| Keychain ACL prompts, or a stale Keychain token | never prompt in the background; fall through the chain in 4.1 |
| `chatgpt.com/backend-api/wham/usage` is undocumented and may hit Cloudflare | passive rollout snapshots cover most cases; `codex app-server` `account/rateLimits/read` |
| Antigravity local RPC and protobuf layout are internal; discovery already changed once (token left the command line) | discover via `daemon/*.json`; decode defensively by field number with sanity checks (`output == thinking + response`); degrade to limits only |
| Transcript format churn (Claude `api-request` records arrived in 2.1.304; Codex `token_usage_record` and zstd archives are recent) | versioned parsers keyed on `version` / `cli_version`; tolerate unknown fields; a "parsed N of M" health line in settings; fixture tests from redacted real lines |
| Codex moving history into SQLite (`history_mode: paginated`, `thread_history_1.sqlite`) | read `state_5.sqlite` `threads` as the index; add a SQLite reader if rollouts stop |
| Double counting across forks, mirrors and machines | global dedupe keys; a self-check comparing our Codex totals to `threads.tokens_used` |
| Price table wrong or late for a new model | per-model override; "unpriced" state; cost computed at query time |
| Privacy: transcripts hold prompts and code | the collector extracts numbers and ids only; never store or transmit content; `cwd` kept local and optional |

## 9. Prior art

| Project | Stars | Licence | Sources it uses | Notes |
|---|---|---|---|---|
| steipete/CodexBar (Swift) | 23 k | MIT | Claude: OAuth usage endpoint → CLI PTY `/usage` → claude.ai cookies. Codex: `wham/usage` → `codex app-server` RPC. Antigravity: `ps` for `--csrf_token`, then `RetrieveUserQuotaSummary` → `GetUserStatus`. Local JSONL cost scan. | Closest neighbour for limits. Its docs record the failure modes we should expect: Keychain ACL resets when Claude Code rewrites its item, token rotation, Keychain items holding only `mcpOAuth`, Cloudflare on web paths, tokenless `agy` 1.2.2+. No latency, no fleet. Parsing logic is borrowable under MIT. |
| ryoppippi/ccusage (now Rust) | not fetched | MIT | Local logs for 20 agents incl. Claude Code, Codex, Antigravity, Gemini CLI. LiteLLM pricing pinned at build, `--offline`. | Cost and tokens only. Good reference for parsers and for the pricing-snapshot workflow. |
| Maciek-roboblog/Claude-Code-Usage-Monitor (Python) | 8.8 k | MIT | Local JSONL, own burn-rate prediction | Predates server-reported limits; estimates limits from tokens. |
| hamed-elfayome/Claude-Usage-Tracker (Swift) | 3.8 k | MIT | claude.ai session cookie / OAuth | Claude only. |
| Henrik-3/AntigravityQuota (TS, VS Code extension) | 240 | MIT | `GetUserStatus` on the local language server | Sees only the 5h figure per model. |
| burakgon/ai-usage-menubar, lbybrilee/ai-pace, iritec/usage-menubar | <100 | MIT | similar | Small; "pace" framing already exists. |

Nobody found combines limits, per-request performance and multiple machines.

### Name check

| Name | Homebrew | GitHub | Mac App Store | Verdict |
|---|---|---|---|---|
| **Tach** | formula `tach` exists (tach-org/tach, Python dependency tool, 2.9 k stars, active). Cask `tach` is free. | no macOS app; `tach-org/tach` owns the bare name | no Mac app named Tach; unrelated iOS apps "Tach" and "TACH: For Truckers" | Usable, with friction: `brew install tach` installs the Python tool, so users need `--cask` or a different token (e.g. `tach-app`). Not searchable as a bare word. |
| Headroom | cask `headroom` exists: "Reduce token usage for Claude Code and Codex" | headroomlabs-ai/headroom (81 k stars), gglucass/headroom-desktop (menu bar, same audience) | "Headroom: AI Usage Meter", "AgentHeadroom: AI Usage Limits" | Taken, in this exact niche. |
| Pitwall | free | several small projects, two of them Claude Code session dashboards | racing telemetry apps | Weak collisions, same space. |
| Sightglass | free | bytecodealliance/sightglass (benchmarks); one tiny Claude statusline project | none | Mostly clear. |
| Redline | free | robb/Redline (SwiftUI library); "RedLine" is also a well-known malware family | "Redline: Minimal Menubar Todo" and others | Crowded, bad association. |
| Brink | free | semihtalii/brink: "Claude Code, Codex & Cursor usage limits" (Swift, MIT, 53 stars) | unrelated | Direct collision in the niche, though small. |
