# Research: Carry On When a Runtime Runs Out

Phase 0 for [plan.md](plan.md). Each entry is a decision, why, and what else was weighed. Where a
finding came from reading a vendor's adapter, the version and the file are named, so the next
person can check it has not moved.

Versions read on 2026-09-25:

- the Claude adapter, `@agentclientprotocol/claude-agent-acp` **0.81.2**, the version pinned in
  `App/Resources/toolsets/claude/package.json`;
- the Codex adapter, `@agentclientprotocol/codex-acp` **1.13.1**, the app's own toolset under
  `~/Library/Application Support/Agents/tools/codex/`.

## R1. Recognising a spent allowance: typed failures first, words second, never a guess

**Decision.** Recognition works in three layers, in this order.

1. **Typed failures.** Both the Claude and the Codex adapters implement one shared ACP extension,
   JetBrains' "AIR" session-failure extension. They send it only to a client that asks for it.
   We ask by adding this to `clientCapabilities._meta` in `initialize`:

   ```json
   { "jetbrains": { "air": { "version": 1, "capabilities": ["sessionFailure"] } } }
   ```

   With that set, a turn the provider refuses comes back in one of two ways:
   - as `stopReason: "end_turn"`, with `_meta.jetbrains.air.sessionFailure` on the
     `session/prompt` result;
   - as a `session_info_update` carrying the same `_meta`, when the failure is not tied to a turn.

   The payload is `{id, revision, category, severity, title, details?, reason?, actions}`. The
   adapter's internal *kind* is not sent, but `category` and `actions` together identify it
   exactly. From the policy table in Claude's `dist/session-failure-extension.js`, which Codex
   copies, the `limit` category has four kinds:

   | `category` | `actions` | kind | what 052 does |
   |---|---|---|---|
   | `limit` | `[]` | `quota_exhausted` | spent allowance: mark out, switch |
   | `limit` | `["retry"]` | `rate_limited` | rate limit: wait, retry on the same runtime (R7) |
   | `limit` | `["new_session"]` | `budget_exhausted` or `context_exhausted` | never switch (FR-006) |
   | anything else | | | never switch; shown as today |

   Claude reports `quota_exhausted` for a plan limit (`isUsageLimit`), `billing_error` and
   `account_on_hold`, and `rate_limited` for `rate_limit`. Codex maps its own error codes:
   `usageLimitExceeded` becomes `quota_exhausted`, and `rateLimitExceeded` becomes `rate_limited`.
2. **Words**, where a runtime has no typed failures, or has not been asked for them. There is
   one recogniser per runtime, each a list of exact prefixes or codes that has been captured
   from real refusals:
   - **Claude without the extension**: the prompt is rejected with an internal error whose text
     starts with one of the Claude SDK's `USAGE_LIMIT_ERROR_PREFIXES`, such as "You've hit your",
     "You're out of usage credits" or "You're out of extra usage".
   - **Gemini (046, on main since 2026-09-25)**: `DaemonCore.usageLimit` in
     `DaemonCore+Commands.swift` is where it is recognised now, and a limit ends the turn as
     `.refusal`. 052 moves that test into `LimitRecognition` and splits it. A 429 saying "You have exhausted your daily quota on this model." is spent.
     Any other 429, or `RESOURCE_EXHAUSTED` with "rate limit", is a rate limit. This splits the
     single thing that the Gemini lane's `usageLimit` detects today.
   - **Keys on OpenAI and Anthropic**: `insufficient_quota`, and "credit balance is too low",
     mean the credit is gone (FR-001c).
3. **Anything else does not switch.** The raw error goes to `daemon.log` under a `052 unrecognised
   refusal:` prefix, so that its wording can be added later (FR-006, spec Edge Cases).

**Rationale.** Typed failures are the vendors' own classification, and they separate a quota from
a rate limit, which words cannot do reliably. Two of the six catalogue runtimes support them
today, and those are the two with the biggest plan allowances.

**Consequence that must ship with it.** Asking for the extension changes what these adapters do
with every other failure, too:

- Claude stops putting the raw detail into internal errors (`internalErrorForClient` drops
  `rawDetail` once the client supports failures).
- Both adapters end a refused turn as `end_turn`.

Today the app reads `end_turn` as **finished**, and it ignores both `_meta` on a prompt result
and a `session_info_update` that has no title. So the same change must also:

- read the failure on every turn result and every session update;
- never let a turn that carries an error-severity failure reach `finished`;
- write the failure's `title` into the chat as a runtime note, for every kind, not only for
  limits.

Without these, turning the extension on would hide failures that the app shows today.

**Alternatives.**

- *Match words for Claude and Codex too.* Rejected, because it cannot tell a rate limit from a
  quota.
- *Parse Claude's synthetic "<synthetic>" assistant message.* Rejected, because that message is
  an adapter-internal detail, and the typed failure exists to replace it.

## R2. When an allowance comes back

**Decision.** The reset time is taken from the runtime whenever it says one, and from rules
otherwise:

- **Claude.** Every `usage_update` carries `_meta["_claude/rateLimit"]`, which is the SDK's
  `SDKRateLimitInfo`: `status` (`allowed`, `allowed_warning` or `rejected`), `resetsAt` (Unix
  seconds), `rateLimitType` (`five_hour`, `seven_day` and so on), and the overage fields. The
  latest one is kept per runtime. When a spent allowance comes with `status: rejected`, its
  `resetsAt` is the return time.
- **Codex.** The adapter tracks `account/rateLimits/updated`, including `resetsAt` per window and
  `credits`. It is not yet certain whether it forwards this over ACP. The implementation checks
  for `_meta` on `usage_update` or `session_info_update` from Codex and reads `resetsAt` if it is
  there. Otherwise it uses the "resets …" text in the failure `title`, if that parses as a time.
  Otherwise it uses the one-hour rule.
- **Words-only runtimes.** They get a time only if their captured wording includes one, and the
  one-hour rule otherwise (FR-008).
- **Credit.** A free-credit or prepaid entry that runs out has no return time (FR-001c).
- **Gemini's free tier.** Its daily quota resets at midnight Pacific time. A free-tier Gemini
  entry whose quota is spent is out until the next midnight in `America/Los_Angeles`. This comes
  from the entry's `ResetRule`, not from the error, which gives no time.

**Checked against the real adapters, 2026-09-26 (T073, quickstart §10).** No prompt was sent.
Claude was run through `npx -y @agentclientprotocol/claude-agent-acp` and Codex from the app's own
copy, `@agentclientprotocol/codex-acp` 1.13.1. Each was given `initialize`, with the AIR
`sessionFailure` capability, then `session/new`, then 15 s of listening. The handshakes are in
`walk/real-runtimes/`, with the e-mail address taken out.

- Both answered `initialize` and `session/new`.
- **Neither sends a `usage_update` before a turn,** so neither sends rate-limit `_meta` then. Claude's
  `_claude/rateLimit` arrives only with a turn's usage, as the SDK documents; that is what the
  implementation reads. Whether Codex forwards `account/rateLimits/updated` as `_meta` on a turn is
  **still open**: it cannot be settled without a prompt, which this check does not send. The
  implementation reads `_meta` from Codex if it comes, then the title's "resets …", then uses the
  one-hour rule. So R13's Codex row stands as written ("if forwarded, else title, else 1 h").
- Both send `_auth/status_update` right away, naming the signed-in plan: Claude says `"label":
  "Claude Max"` and Codex `"label": "ChatGPT Plus"`. Main reads this into the runtime's account
  (a7a9656f). A pool entry's allowance label could be filled from it instead of typed. That is a
  follow-up, not done here.
- Neither lists the AIR extension among its capabilities. The adapters send typed failures only
  when asked, and the app asks. The typed failures themselves are what `SessionFailureDecodingTests`
  fixtures stand for; they need a real refusal to see live.

**Alternatives.** Polling each provider's usage page was rejected: it needs credentials the app
does not hold, and it breaks the rule that the app never polls on a tight cadence.

## R3. Never paying: overage is treated as out

**Decision.** The Claude SDK reports, on the same rate-limit info as R2, whether the account has
started using paid overage: `isUsingOverage`, `overageInUse` or `overageStatus`. If any of these
shows overage in use while the chat is on an allowance entry, the entry is marked out at once, as
`overage` with its `resetsAt`, and the chat moves at the end of that turn. Codex is handled the
same way: `spendControlReached`, or its credits falling while it is on a plan, marks the entry
out.

The app cannot "decline" an offer that a vendor applies on its own servers. What it can do is
stop sending that runtime work the moment the vendor reports that paid use has begun. That is how
FR-007 is met, and the switch note says why it happened: "Claude started using paid extra usage.
Carried on with Codex."

**Alternatives.** Refusing to use Claude whenever overage is merely *allowed* was rejected. It
would rule out every account that has extra usage switched on but unused. The memory note
`claude-fast-mode-needs-extra-usage` shows such accounts exist, including the owner's.

## R4. Handing the conversation over

**Decision.** A switch makes a brand-new session on the new runtime, using the path that `start`
already takes (`freshSession`). It uses the chat's `cwd`, `additionalDirectories`, `mcpServers`
and the new runtime's own `ToolPolicyCatalog` metadata. The first prompt of that session is two
blocks:

1. **The handoff.** This is a Markdown document built from the app's own transcript, by
   `Handoff.document(entries:budget:)` in Core. It has:
   - a header saying it is a conversation carried over from another runtime, and that the files
     are already as described;
   - the person's prompts, verbatim;
   - the agent's replies;
   - one line for each tool call (tool, target path or command, and outcome);
   - edits as `path +a −b`;
   - the latest plan;
   - runtime notes about stops.

   It is sent as an embedded `resource` block (`agents://handoff/<agentID>.md`) when the runtime
   advertises `promptCapabilities.embeddedContext`, and as a text block otherwise.
2. **The prompt that failed**, exactly as it was first sent, including its attachments.

**Budget.** The document is capped at 60% of the new runtime's context size, when a `usage_update`
from it has given one, and at 400,000 characters otherwise. When it has to be cut, the first user
prompt and the most recent turns are kept, and the middle is replaced with one line: "[N earlier
turns left out]". The switch note then says the conversation was shortened (spec Edge Cases).

**Record.** In the transcript, the handoff is written as an entry of its own, `handoff`, which
the chat draws folded under the switch note, the way a wake prompt is drawn under "Agents asked".
It is never drawn as the person's bubble. The re-sent prompt is not written a second time.

**Alternatives.**

- *`session/load` of the old transcript on the new runtime.* Impossible: sessions are per vendor.
- *Ask the old runtime for a summary first.* Rejected, because it is out of allowance, which is
  why the chat is moving.
- *Summarise with a third model.* Rejected: it is a paid call, and one more thing to fail.

## R5. Where the logic lives

**Decision.** The decisions are pure functions in `AgentsKitCore`, so they can be tested without
a daemon. The daemon applies them.

- **`PoolPlan.next(for:pool:states:tried:host:now:)`** returns one of four answers: `.switchTo(entry)`,
  `.everyoneOut(earliest:)`, `.off(reason)` or `.stay`.
- **`SettingsCarry.plan(from:to:grid:poolEntry:remembered:)`** returns the FR-015 mapping, with
  where each value came from and what was dropped. The Continue with sheet and an automatic
  switch share it.
- **`LimitRecognition.classify(turnResult:error:runtimeID:)`** returns one of `.spent(resetsAt?)`,
  `.creditGone`, `.rateLimited(retryAfter?)`, `.overage(resetsAt?)`, `.otherTyped(title)` or
  `.none`.

The daemon side is a new file, `DaemonCore+Pool.swift`, reached from the two places a turn ends
today: the `TurnResult` path, and `turnFailed`.

## R6. Where the pool is stored

**Decision.** The daemon owns everything, because the daemon is what switches, including while
no window is open. It follows the pattern of `limits.json` and `cost/setLimits`:

| file | holds | written |
|---|---|---|
| `pool.json` | on/off, the ordered entries, the Matching models levels | on `pool/set` |
| `allowances.json` | each entry's state, return time, how it was learned, and spending against credit | on every change |
| `switches.jsonl` | one line per switch | appended; lines over 30 days old dropped at start |

The app pushes `pool.json` to each connected server on connect, as it does the cost limits
(037 R7).

Allowance state belongs to the **credential**, not to the host. This matters since 047 merged:
a server's Codex can use the Mac's own ChatGPT plan through the relay, and then it is the same
allowance as the Mac's. So the Mac's daemon holds the single `allowances.json`. A server's daemon
sends what it learns (spent, rate limited, returned) to the Mac over the existing server link,
and gets the current states back with `pool.json`. Two entries on one host that share a
credential share one state. A lent key on a server is its own credential, with its own state.

## R7. Rate limits

**Decision.** A recognised rate limit keeps the chat on its runtime. The turn is sent again after
the runtime's `retryAfter` if it gave one, and otherwise after 30 s and then 120 s. A third
consecutive rate limit within 10 minutes counts as the allowance being spent. The entry is then
marked out under the one-hour rule, and the chat moves. While it waits, the agent shows *Rate
limited · trying again at HH:mm*. These numbers are defaults in `LimitRecognition.RateLimitPolicy`,
not settings (spec Assumptions).

## R8. Everyone out

**Decision.** The chat gets an `AllowanceWait { resumeAt, runtime, prompt }`. It is checked by
the same due-timer loop that resumes blocked agents (039, `resumeDueBlocks`), so no new timer
exists. It is persisted on the record, so it survives a restart. It is cleared by a prompt from
the person, by stop, by park or by archive (FR-017). When there is no known return time at all,
the chat stops and says so, and nothing is scheduled.

## R9. Counting spending against credit

**Decision.** Each turn's `TurnUsage.cost` is already reported by the Claude adapter and by
Copilot. It is added to the ledger of the entry the chat was on, in `allowances.json`, keyed by
entry id. When a runtime reports no cost, the ledger records `unknown` rather than zero, and the
page says "spending not known" (FR-001b). The amount is checked at the end of every turn. It is
not checked mid-turn: the provider's own hard stop is the guard mid-turn, and the ledger is the
second guard.

## R10. Model lists for the grid

**Decision.** The lists come from the option cache the start form already fills
(`OptionCache`, `rememberedOptions`). A runtime nobody has started yet is asked through the same
draft path, which does a handshake and `session/new` without a prompt. It costs no allowance.
Lists are refreshed when the Pool page opens, at most once every 10 minutes per runtime.

## R11. `EndedReason`, and the other lanes changing it

**Decision.** Two cases are added: `allowanceSpent` and `rateLimited`. The second is used only
when retries are exhausted and there is no pool to move to. The other lanes are handled like
this:

- **Gemini (046)** is on main, and ends a limit as `.refusal` through `DaemonCore.usageLimit`. 052
  replaces that with the two cases above, and moves the test into `LimitRecognition`. Its
  `UsageLimitTests` become rows of `LimitRecognitionTests`.
- **Antigravity (049)** is on main since 2026-09-26, as one commit (`819ff22`), not as a merge of
  its branch. It adds `EndedReason.runtimeError`, `RuntimeLaunch.turnErrorPrefix` and
  `TurnResult.runtimeError`. Antigravity ends a failed turn normally, having said "Agent execution
  error: …" in its own text, and the daemon turns that into `.runtimeError` in the turn-result
  path of `DaemonCore+Commands.swift`. That branch is exactly where 052's "a refused turn is never
  finished" hooks in, beside it. A `runtimeError` stays separate, and never switches by itself.
  `LimitRecognition` looks at its `sentence` with Antigravity's word list. Its quota wording is
  still "to measure" in 049's research (not provoked on the free tier). Until it is captured,
  Antigravity is listed as not yet recognised.
- **Order.** Whichever lane merges second takes in the other's cases. `EndedReasonTests` walks
  `allCases`, so a missing summary line fails the suite.
- **Checks before building.** At task time, check `git grep -n 'runtimeError\|usageLimit' main`
  first. As of 2026-09-26 both are on main: `usageLimit` (046) and `runtimeError` (049).

## R12. Events

**Decision.** Three names are added to the catalogue:

- `agent.runtime_switched` carries `{agent, from, to, reason, entry}`;
- `cost.allowance_out` carries `{entry, runtime, until?, reason}`;
- `cost.allowance_back` carries `{entry, runtime, how}`.

They sit in the existing `agent` and `cost` families, so workflows can already filter on them
(FR-014).

## R13. What is recognised at release (SC-005)

| runtime | spent allowance | rate limit | return time | pay-as-you-go guard |
|---|---|---|---|---|
| Claude | typed | typed | `_claude/rateLimit.resetsAt` | overage fields (R3) |
| Codex | typed | typed | if forwarded (R2), else title, else 1 h | `spendControlReached` |
| Gemini (046, on main) | words, daily quota | words, 429 | free tier: next midnight Pacific; credit: none | always a key: free tier, free credit or prepaid only (FR-001a) |
| Codex on a server, relayed (047) | typed, as on the Mac | typed | as on the Mac; one state with the Mac's plan (R6) | as on the Mac |
| Codex on a server, lent key (047) | `insufficient_quota` → credit gone | 429 | credit: none | key: free tier, free or prepaid credit only |
| Antigravity (049) | via the rate-limit rule: its 429, "Resource has been exhausted (e.g. check quota).", captured in 049's `AntigravityTurnTests`, is retried and counts as spent after three in ten minutes (Google uses the same words for both) | "Resource has been exhausted" inside "Agent execution error: …" | 1 h | Google account = allowance |
| Copilot, Cursor, Grok | **not yet**, and the docs say so | not yet | — | — |

Copilot, Cursor and Grok are listed in `docs/reference/runtimes.md` as "not yet recognised". A
refusal from any of them stops the chat, as today. Their wording is added when a real refusal is
captured from `daemon.log` (R1, layer 3).
