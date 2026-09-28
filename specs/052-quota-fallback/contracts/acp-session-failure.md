# Contract: what the app asks of runtimes, and what it reads back

This contract covers the ACP side (research R1–R3). It says what the app sends, and exactly which
fields it reads. Anything not listed is ignored.

## Sent in `initialize`

`clientCapabilities._meta` gains this object. It is merged with any `_meta` the app already
sends:

```json
{ "jetbrains": { "air": { "version": 1, "capabilities": ["sessionFailure"] } } }
```

It is sent to every runtime. A runtime that does not know the extension ignores `_meta`, as the
protocol requires.

## Read from the `session/prompt` result

```text
result.stopReason                                   existing
result._meta.jetbrains.air.sessionFailure           new, optional
  .id            string       the same id across revisions means the same failure
  .revision      int          a higher revision replaces an earlier one with the same id
  .category      string       "limit" | "access" | "service" | "connection" | "request" | "unknown" | …
  .severity      string       "error" | "warning"
  .title         string       shown in the chat, verbatim
  .details       string?      written to daemon.log, not shown
  .reason        string?      logged
  .actions       [string]     "retry" | "login" | "new_session" …
```

How the app classifies it, in `LimitRecognition.classify`:

| category | severity | actions | → |
|---|---|---|---|
| `limit` | `error` | `[]` | `.spent` |
| `limit` | `error` | contains `retry` | `.rateLimited` |
| `limit` | `error` | contains `new_session` | `.otherTyped` (no switch) |
| any other | `error` | any | `.otherTyped` (no switch; title shown) |
| any | `warning` | any | no change to the turn; the title is shown as a note (a retry in progress) |

**Rule.** A turn whose result carries an error-severity failure is **never** recorded as
`finished`, whatever `stopReason` says.

## Read from `session/update`

- **`session_info_update` with `_meta.jetbrains.air.sessionFailure`.** The same payload as above,
  but session-scoped. It is applied to the agent's current turn if one is running, and otherwise
  written to the chat as a note. It no longer counts as "ignored" when it has no `title`.
- **`usage_update._meta["_claude/rateLimit"]`.** This is `SDKRateLimitInfo`:
  `status`, `resetsAt` (Unix seconds), `rateLimitType`, `utilization`, `overageStatus`,
  `overageResetsAt`, `isUsingOverage`, `overageInUse`, and `overageDisabledReason`. The latest one
  is kept on the entry's `AllowanceState.lastRateLimit`.
  - While the entry is an allowance, `isUsingOverage == true` or `overageInUse == true` means
    `.overage` (R3).
- **Codex rate-limit snapshots**, if forwarded: `resetsAt`, `credits` and
  `spendControlReached`. Read on the same terms, and verified by the quickstart's Codex check
  (R2).

## Words (runtimes without the extension)

Each recogniser is a static list in `LimitRecognition`, with a test per entry quoting the
captured text:

| runtime | spent | rate limit |
|---|---|---|
| claude (no extension) | error text starts with any `USAGE_LIMIT_ERROR_PREFIXES` entry (SDK list, copied with its version) | — |
| gemini | 429 and "exhausted your daily quota": out until the entry's reset (free tier: next midnight Pacific) | other 429s; `RESOURCE_EXHAUSTED` with "rate limit" |
| antigravity (049) | chat text starting `Usage Limit Reached` / `You have reached your current quota` (captured 2026-09-27), via `turnError` then `runtimeError` → `.spent` | `Resource has been exhausted` / `check quota` as `runtimeError` → rate-limited first (R7) |
| grok | `data.message` containing `usage balance exhausted` (captured 2026-09-27 from “hi Grok”; top-level JSON-RPC message is only `Internal error`, with `data.http_status` 402) → `.spent` | — |
| keyed OpenAI / Anthropic | `insufficient_quota`; "credit balance is too low" → `.creditGone` | 429 without those |
