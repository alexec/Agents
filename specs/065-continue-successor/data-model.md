# Data Model: Read Another Session's History

A session is the `Agent` the app already has, and a history is text rendered from the
transcript it already writes. A runtime's state is the `AllowanceState` the pool already kept,
now kept for every runtime. Nothing new is stored. This file says which fields the tools read,
what the runtime state holds, and which pool fields and files stop being written.

## Session (existing `Agent`)

The tools read these. They write none of them.

| Field | Role in this feature |
|---|---|
| `id` | Accepted by `read_session`. Printed by `list_sessions`. |
| `title` | Exact match, after the argument is trimmed. Nil is untitled, and the word "Untitled" does not match it. |
| `runtimeID` | Printed on the list and in the history header. |
| `state`, `endedReason`, `report` | The status words. `report.message` is "what it last said", when there is a report. |
| `lastActivityAt` | Printed so two sessions with one title can be told apart. Not updated by a read. |
| `projectFolder` | The scope. Compared after `Project.standardize`. A worktree's project is the worktree's project, not its `cwd` (030). |
| `cwd` | The folder in the history header: where the files were being written. |
| `worktree` | Name and branch in the header, when set. |
| `archivedAt` | An archived agent is still a session. It is listed and it is readable. |

Not read: `poolEntryID`, `switchingOff`, the runtime's private session id, cost, options.

## History (rendered, not stored)

`SessionHistory.Document`:

| Field | Meaning |
|---|---|
| `markdown` | The text `read_session` returns. |
| `leftOut` | Turns dropped to fit the budget. Nil when the whole record fit. |

A turn is the entries from one `userMessage` up to the next. The budget is 80,000 characters,
`SessionHistory.budget`. The first turn is always kept. Latest turns are added until the next
one would pass the budget. The plan, from the last `planUpdated` in the file, is always kept.

Tool calls whose name the app serves (`AppTool.isServedByTheApp`) are not lines in the history.
The app's own bookkeeping is not what the session did.

## Tombstone (existing, 051)

A retired agent is a `Tombstone`: id, title, project, runtime, dates. No transcript. An id or
an exact title that matches a tombstone in this project and no live agent is the refusal
"that conversation is gone". Tombstones are not listed.

## Allowance ending (existing `EndedReason`)

No new case.

| Ending | `EndedReason` | Note already in `PoolWords` | Group |
|---|---|---|---|
| Allowance spent | `.allowanceSpent` | `ranOut` — "until ‹time›" only when the runtime gave a time | Paused (`AgentGroup.stopped`) |
| Credit used up | `.allowanceSpent` | `creditGone` | Paused |
| Paid extra usage, and the turn failed | `.allowanceSpent` | `overageBegan` | Paused |
| Paid extra usage, and the turn completed | unchanged (`.endTurn`) | `overageBegan` | wherever a completed turn sits |
| Rate limit, retries left | `.rateLimited`, then the same prompt is sent again | `rateLimited` | Working while the retry runs |
| Rate limit, three times in ten minutes on this chat | `.rateLimited` | `stillRateLimited` | Needs you |

The status line for `.allowanceSpent` is already "Its allowance ran out".

## Rate-limit streak (in memory, per chat)

`DaemonCore` holds `[UUID: [Date]]` for the chat, beside the existing `rateLimitAttempts`.
It is not on the agent record. A restart forgets it. Three timestamps inside
`RateLimitPolicy.standard`'s window (600 seconds, `persistsAfter` 3) end the retry and mark
the runtime out with `.rateLimitPersisted`. The delays stay `[30, 120]` seconds when the
runtime gave no time. `AllowanceState.rateLimitStreak` is decoded and no longer written.

## Runtime state (existing `AllowanceState`, `allowances.json`)

One per credential key, `‹runtimeID›:sign-in` or `‹runtimeID›:‹CredentialKind›`. Unchanged in
shape, so a file written by the pool is read as it is.

| Field | Role now |
|---|---|
| `credentialKey` | The identity. The runtime is the part before the colon. |
| `status` | `.available`, `.rateLimited(until:)` or `.out(until:, retryAfter:, why:)`. Shown, never enforced. |
| `since` | When it last changed. The first check is `since + 4h`. |
| `spent` | Decoded, not written: the credit ledger goes. |
| `lastRateLimit`, `reading` | The plan window and what is left of it, for the row's second line. |
| `entryID` | Decoded, not used. |
| `rateLimitStreak` | Decoded, not written (above). |

What changes it:

| Event | New status | Event raised |
|---|---|---|
| A recognised spent allowance, used-up credit, overage, a persisted rate limit, or a crash or unrecognised failure, in any chat | `.out`, with the reason and the provider's time when given | `cost.allowance_out` |
| A turn on it that works, a passing check, **Mark available** | `.available` | `cost.allowance_back`, with `how` |
| A newer state from a server or the Mac (`pool/applyAllowances`), for a shared sign-in | That state | out or back, `how: another host` |

Nothing reads `status` to decide whether a prompt is sent.

The credential key of an agent is `‹runtimeID›:‹CredentialKind›` when its runtime runs on a
key the Mac lends (Gemini's), and `‹runtimeID›:sign-in` otherwise, as `poolEntry(for:)` makes it
today without a pool.

## Fields and files that stop being written

| Field or file | What happens |
|---|---|
| `Agent.allowanceWait` | Decoded if an old record has it. Cleared at launch. No timer, no resume. |
| `Agent.poolEntryID`, `Agent.switchingOff` | Decoded, never set again. |
| `pool.json` | Not read, not written. Left on disk. Its credit amounts and expiries are dropped. |
| `switches.jsonl` | Not written, not read. Left on disk. |
| `agent.runtime_switched` | Not raised. Catalogue entry removed. Old log lines stay in the file. |

`allowances.json` is still read and written.

## Transcript kinds that stay

`poolSwitch`, `handoff` and `settingsChanged` stay on `TranscriptEntry.Kind` so a transcript
written before this feature still decodes and still draws. Nothing in this feature appends
them. `SessionHistory` skips them when it renders.
