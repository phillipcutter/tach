# Collector protocol

`tach-collector` is a small static binary. The Tach app runs it on this Mac and, over SSH, on each remote machine. It reads the usage logs AI coding tools already write and prints compact events as NDJSON on stdout. The app owns storage, dedupe across machines, aggregation and UI.

The Go types in `collector/internal/event/event.go` are the schema. This file states the rules the types cannot.

## Commands

| Command | Output |
|---|---|
| `scan [--cursor V \| --cursor-file F \| --state DIR --id ID [--commit TOKEN] [--reset]] [--since 720h] [--only a,b] [--home DIR]` | `req`, `turn`, `limit`, `session`, `log` lines, then exactly one `cursor` line, last |
| `limits [--only claude,openai,gemini]` | `limit` and `log` lines: a fresh reading of every limit window |
| `detect` | one JSON object (`detect.Report`) |
| `version` | the version string |

Exit status is 0 unless the command line is wrong. A source that fails logs an `error` line and the others carry on. Nothing but NDJSON goes to stdout; `-v` progress goes to stderr.

`--cursor -` reads the cursor from stdin. With `--state`, the cursor is kept in `DIR/cursor-ID` on the machine being read and the `cursor` line carries a 16-character token instead. The scan writes the next cursor beside the current one; it becomes current when the reader's next call passes that token as `--commit`, confirming the events were stored. An unconfirmed scan is repeated, which is safe because the reader upserts. The app uses this for remote machines, where sending the cursor each way would cost hundreds of kilobytes a minute. `--reset` forgets the stored cursor first, which is how the app reaches further back when the user asks for more history.

## Hard rules

1. **No content.** Never emit prompts, responses, tool input or output, file contents, or credentials. `cwd`, session ids and model ids are the only strings taken from the logs.
2. **Read-only.** Never write to a tool's data directory, config or credential store. Open SQLite read-only with `immutable=1`. Never refresh an OAuth token.
3. **Bounded.** A first scan may face tens of GB. Stream files, cap memory at a few hundred MB, pre-filter lines on cheap substrings before parsing JSON, and parse files in parallel. Target: a first 30-day scan of ~6 GB of Claude transcripts in under 60 s on an M-series Mac; an incremental scan with nothing new in under 300 ms.
4. **Resumable.** The cursor holds a byte offset per file (`cursor.State`). Only consume complete lines. If a file shrank or its inode changed, start it again from 0. Files not modified since `--since` are skipped on a first scan.
5. **Tolerant.** Unknown fields and record types are ignored. A malformed line is skipped and counted, not fatal.

## `req`

One per model request, emitted once its final token usage is known.

- `key` is the dedupe key: Claude `message.id`; Codex `response_id`; Antigravity the `request_id` label; Gemini CLI `sessionId` + `/` + message `id`. The app upserts on `(tool, key)` keeping the per-field maximum of token counts, so emitting a key again with fuller data is safe. Avoid needless repeats within one scan.
- `in` is **uncached** input. Codex logs input including cached tokens: subtract.
- `out` includes reasoning tokens; `think` is the reasoning subset.
- `cw5` / `cw1`: cache writes at 5-minute and 1-hour TTL. Where the split is unknown, put everything in `cw5`.
- `dur`, `ttft` in ms. `tq` says how they were obtained: `exact` (logged by the tool for this request), `est` (derived from log timestamps), `none` (absent; omit both).
- `pool` names the subscription budget the request draws on, or is empty:
  - `claude`: Claude Code / Claude Desktop requests whose model id starts with `claude-`, excluding third-party-provider traffic (`entrypoint` ending in `-3p`) and `<synthetic>` records (do not emit `<synthetic>` at all).
  - `openai`: Codex requests made with ChatGPT sign-in (`auth_mode: chatgpt`).
  - `gemini` / `gemini_3p`: Antigravity requests to Gemini models / to Claude and GPT models.
- `mirror` is true for Claude records read from `~/.claude/projects/ssh-*/` (Claude Desktop's local copy of a session that ran elsewhere). The app prefers a non-mirror copy when it decides which machine a request belongs to.
- `sub` is true for subagent / sidechain / guardian requests.
- `acct` is the first 12 hex chars of SHA-256 of the provider account id, when the tool's local files reveal it.

## `turn`

Codex reports duration and time to first token per turn, not per request. Emit one `turn` per completed turn (`key` = turn id) with `dur`, `ttft` and the turn's output tokens. Codex `req` events then carry `tq: none`.

## `limit`

One reading of one window. `window` ids are stable per account, and `group` ties windows that share a budget:

| Provider | group | window | kind | label |
|---|---|---|---|---|
| claude | `` | `five_hour` | session | 5-hour |
| claude | `` | `weekly` | weekly | Week |
| claude | `` | `weekly:<slug>` | weekly_scoped | the scope's display name, e.g. Opus |
| claude | `` | `credits` | credits | Extra usage credits (`amount` left, `cap`, `currency`; `used` = percent of cap spent) |
| openai | `` | `five_hour` / `weekly` (by window length: up to 6 h is a session) | session / weekly | 5-hour / Week |
| openai | `` | `weekly:<slug>` for any additional per-model limit | weekly_scoped | its name |
| gemini | `gemini`, label "Gemini models" | `gemini:five_hour`, `gemini:weekly` | session / weekly | 5-hour / Week |
| gemini | `3p`, label "Claude and GPT models" | `3p:five_hour`, `3p:weekly` | session / weekly | 5-hour / Week |

- `used` is percent used, 0-100. A window that has not started (no reset time yet) has `used: 0` and no `resets`.
- `ts` is when the reading was true: now for a poll, the event time for a snapshot found in a log.
- `scan` also emits limit readings it finds in logs (`src: rollout` for Codex `token_count.rate_limits`, `src: transcript` for a Claude 429 record, `src: history` for Claude Desktop's `plan-usage-history.json`). Thin them to one per window per 5 minutes of event time, always keeping the newest.
- `limits` tries, per provider, the sources in the order given in `design/data-sources.md` section 4.1 and logs which one answered. If none can, it logs a `warn` with a reason the app can show ("Antigravity is not running", "Claude sign-in on this machine has expired").

## `session`

One per session that is live or was active in the last 30 minutes, emitted on every scan. `status` is `busy` or `idle`. `ctx` is context-window fill in percent where the tool exposes it.

## `detect`

Used by first-run setup, locally and on remotes. Cheap: no full scans. `bytes`/`files` come from directory listings.
