# Data Model: Read Another Session's History

Nothing new is stored. A session is the `Agent` the app already has, and a history is text
rendered from the transcript it already writes. This file says which existing fields the tools
read, and which pool fields stop being written.

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
It is not on the agent record and not in `allowances.json`. A restart forgets it. Three
timestamps inside `RateLimitPolicy.standard`'s window (600 seconds, `persistsAfter` 3) end
the retry. The delays stay `[30, 120]` seconds when the runtime gave no time.

## Fields that stop being written

| Field or file | What happens |
|---|---|
| `Agent.allowanceWait` | Decoded if an old record has it. Cleared at launch. No timer, no resume. |
| `Agent.poolEntryID`, `Agent.switchingOff` | Decoded, never set again. |
| `pool.json`, `allowances.json` | Not loaded, not written. Left on disk. |
| `agent.runtime_switched`, `cost.allowance_out`, `cost.allowance_back` | Not raised. Catalogue entries removed. Old log lines stay in the file. |

## Transcript kinds that stay

`poolSwitch`, `handoff` and `settingsChanged` stay on `TranscriptEntry.Kind` so a transcript
written before this feature still decodes and still draws. Nothing in this feature appends
them. `SessionHistory` skips them when it renders.
