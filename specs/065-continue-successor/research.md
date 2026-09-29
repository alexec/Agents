# Research: Read Another Session's History

Every decision below was checked against the code on main at `af434dba`.

## R1. Where the tools live

**Decision**: Add `list_sessions` and `read_session` to the MCP server the app already gives
every agent (`AppService`, served by `agentsd mcp`). Each call is relayed to a daemon method,
`agents/listSessions` and `agents/readSession`, the way `agents/listHelpers` is. The caller's
project is `agents[token].projectFolder`. There is no argument for a project.

**Rationale**: Every tool the app gives an agent already works this way. The token is minted
per session. That is the whole basis for "only this project".

**Alternatives considered**:

- *One tool with an action, like `manage_workflows`.* Rejected. Listing takes nothing and
  reading takes a name, and a runtime's permission prompt should say which one ran.
- *Extend `list_my_agents`.* Rejected. That tool lists only the agents this one started, and
  it is withheld from a helper. These two are every session in the project, and a helper has
  them too (FR-007).

The names do not end with another tool's name, which is how `AppService` tells calls apart
(`release_resource` ends with `lease_resource`, and that bug shipped once).

Both names go in `AppTool.all`. A tool missing from that list is not recognised as the app's,
so a runtime that asks before every call would put a permission card up. FR-008 says the
person is not asked. `isAutoAllowable` already treats `AppTool.all` as the app answering.

## R2. Who is offered them

**Decision**: Both tools are in `AppService.tools` for every agent, including one whose
`startedByAgent` is set. The daemon answers them for a helper. `helperCaller`'s refusal stays
on start, stop, archive and `list_my_agents` only.

**Rationale**: FR-007. A helper is the agent most likely to be asked to read the session that
started it. The briefing paragraph is sent to a helper too, unlike the `start_agent` line,
which is omitted where the tools are omitted.

## R3. How a session is named

**Decision**: `read_session` takes one string, `session`. The daemon tries it in this order:

1. A UUID that is an agent in this project, in any state including archived. Read it. This
   includes the caller.
2. A UUID that is a tombstone in this project. Refuse: the conversation is gone.
3. An exact title, after trimming, matching one agent in this project. Read it. A nil title
   is not the word "Untitled".
4. An exact title matching more than one agent here. Refuse, and list each match with its id,
   runtime, status and last activity.
5. An exact title matching no agent here, but matching a tombstone here. Refuse: gone.
6. Anything else, including an id or title that exists only in another project. Refuse: no
   such session in this project. Do not say that it exists somewhere else.

The sentences are fixed in [contracts/session-tools.md](contracts/session-tools.md).

**Rationale**: FR-004 and FR-005, and the edge case that an id from `start_agent` or from the
list is accepted. One argument is what a person types ("Login redirect" or a uuid). Trying the
uuid first means a title that happens to be a uuid still loses to the id, which is the thing
the list printed.

**Alternatives considered**: separate `id` and `title` arguments. Rejected. The agent would
have to know which kind it was given, and the person does not speak in those kinds.

## R4. What the history contains

**Decision**: A new `SessionHistory.document(entries:about:budget:)` in Core, built by moving
the turn loop and the trim out of `Handoff.document`.

A turn starts at each `userMessage`. Inside it: the person's words (or "The app", when
`PromptOrigin` is `.app`), the agent's replies, and each tool call that is not one of the
app's own, with the file path when the call has one. A subagent's call is prefixed so it is
not told as the agent's. The last `planUpdated` in the record is a "The plan, as it stood"
section. Thoughts, usage, permissions, and the pool's own switch lines are left out. They are
either noise or a claim that a switch happened.

The header names the title, the id, the runtime, the status, the folder, and the worktree's
name and branch when there is one. It does not say the conversation was carried over or that
the reader is now that session. Where the other session was working is in that header. Moving
there is `enter_worktree`, which this feature does not call.

The budget is **80,000 characters**. Under it, the whole history is given and nothing is said
about omissions. Over it, the first turn and as many of the latest as fit are kept, and one
line says how many turns were left out. The plan section is kept either way.

**Rationale**: FR-002 and FR-006. `Handoff` already did this trim, with a budget of 400,000
characters, because that document *was* the next runtime's prompt. A tool result sits inside
the caller's own turn, next to the briefing and the work still to do. 80,000 characters is
about twenty thousand tokens: enough of a long session to continue from, and not the caller's
whole window. The first request is the part a continuation otherwise loses.

`Handoff.swift` is deleted once nothing switches. Old transcripts still contain `handoff`
entries; drawing those is `HandoffLine` and does not call `Handoff.document`.

**Alternatives considered**:

- *Keep using `Handoff.document` with a different header argument.* Rejected only as a name.
  The type's comment says it is what a runtime is handed during a switch. After the switch is
  gone, that name would be a lie.
- *Return the transcript JSON.* Rejected. The spec's history is readable text, and a raw
  record includes thoughts and the app's own tool calls, which bury the work.

## R5. A read does not touch the session

**Decision**: `readSession` loads the agent (or refuses), reads `transcript.jsonl` through
`TranscriptReader`, renders, and returns the string. It does not call `record`, does not
change `lastActivityAt`, and does not broadcast. An archived agent's slim in-memory copy has
empty `plans`; the plan is taken from the transcript file, which the slim copy does not
strip. A missing transcript file is refused with the same sentence as a tombstone.

The list does not open transcripts. "What it last said" is `report.message` when the agent
has a report, and is omitted otherwise. Scanning every transcript in the project for a last
line would read tens of megabytes to draw a list.

**Rationale**: FR-001 and FR-003. The report is the sentence the agent recorded about its last
turn, which is the same source `list_my_agents` uses.

## R6. A spent allowance ends that chat only

**Decision**: `LimitRecognition.classify` stays. `applyRecognition` changes as follows.

| Recognition | This chat | Remembered for other chats |
|---|---|---|
| `.spent` | Note from `PoolWords.ranOut` (the "until" time only when the runtime gave one). `endedReason = .allowanceSpent`. No switch. | Nothing. |
| `.creditGone` | Note from `PoolWords.creditGone`. Same ending reason, so an older phone still reads it. | Nothing. |
| `.overage` | Note from `PoolWords.overageBegan`. If the turn itself failed, the same ending reason. A turn that completed stays completed, with the note. | Nothing. |
| `.rateLimited` | The existing per-chat retry: the same prompt again after the runtime's time, or after 30s then 120s. Three refusals inside ten minutes on **this chat** stop it with the still-limited note and `.rateLimited`. | Nothing. The streak is a dictionary on the daemon, keyed by agent id, not saved. |

`setAllowanceState`, `raiseAllowanceOut`, `raiseAllowanceBack`, `pendingCarry`,
`carryOnIfPending`, `switchRuntime`, `startWaiting` and `allowanceWorked`'s ledger go.
`pool.json` and `allowances.json` are not loaded and not written. A successful turn clears
that agent's rate-limit streak and nothing else.

`classify` is called with the default payment, an allowance. Overage is only recognised on an
allowance, which is what that default already expresses. Credit used up is recognised from
the words (`insufficient_quota`, `credit balance is too low`) and does not need a pool entry.

**Rationale**: FR-009, FR-011, FR-012. The note and the status are the useful part of 052.
The shared `AllowanceState` is the memory the spec removes: one chat's refusal currently
marks the credential, and the next chat on that runtime is born out. The rate-limit streak
lives in that same struct today (`AllowanceState.rateLimited`); moving it onto the agent id
is what makes "three within ten minutes" a fact about the chat.

**Alternatives considered**: keep writing `allowances.json` but stop reading it for other
chats. Rejected. A file that says a runtime is out will get read by something. Not writing
it is the requirement.

## R7. Where the chat sits in the list

**Decision**: `endedReason == .allowanceSpent` is grouped with a deliberate stop
(`AgentGroup.stopped`, the heading **Paused**) and drawn with the stop mark, not the
needs-you mark. The status line stays `EndedReason.allowanceSpent.summary`, **Its allowance
ran out**. It is not **Waiting**, and `waitingForAllowance` stops being a reason to group
anything.

`.rateLimited` stays under **Needs you**, as any other unexpected stop. The person can send
on that same chat. A spent allowance will not resume, and the way on is a new chat, so it
does not nag under Needs you.

**Rationale**: The spec's "under Stopped" was written against the heading that group used to
have. The panel's heading for `AgentGroup.stopped` is now **Paused** (the grouping change on
`af434dba`). Adding a heading called Stopped would undo that. The words the row says are the
ones the spec names. The acceptance check is: heading Paused, status line "Its allowance ran
out", absent from Waiting and from Needs you.

## R8. What is deleted, and what is kept so old chats still read

**Decision**: Delete the pool UI and the carry-on. Keep decoding and drawing what old records
already contain.

Deleted:

- `App/Sources/Pool/` (the page, Continue with, Matching models, add-credit)
- `Remote/Sources/Pool/`
- The Settings pane `SettingsPane.pool` and `PoolSettingsView`
- The sidebar row and Option-Command-P
- The "Carry on when ‹runtime› runs out" toggle and the allowance-wait lines on the Mac row
  and the phone card
- Daemon carry, wait, shared-allowance sync, and `PoolStore`

Kept:

- `poolSwitch`, `handoff` and `settingsChanged` on `TranscriptEntry`, and the views that draw
  them. A chat that did switch, before this feature, still shows that it did.
- `poolEntryID`, `switchingOff`, `allowanceWait` on `Agent`, decoded if present, no longer
  written. At launch a set `allowanceWait` is cleared and no turn is started. A stopped agent
  left with no reason gets `.allowanceSpent`.
- `PoolWords`, because the live notes and the old switch rows both speak through it.
- `LimitRecognition` and `RateLimitPolicy`.
- **Carry on** for a blocked chat (`Block.carryOnPrompt`, 039). That button is not Continue
  with.

`agent.runtime_switched`, `cost.allowance_out` and `cost.allowance_back` leave the event
catalogue. Lines already in `events.jsonl` stay in the file. Workflows that named them stop
matching, which is the spec: a runtime-wide "out" is not an event any more.

**Rationale**: FR-010. Hiding the pages and leaving the daemon able to switch would fail the
independent test, which is that no second conversation starts. Deleting the transcript kinds
would make an older chat fail to decode.

## R9. The briefing

**Decision**: One paragraph, in `Briefing.lines`, for every agent:

> To continue another session in this project, list them with `list_sessions` and read one
> with `read_session`, by its id or its exact title. Reading it leaves that session as it was.
> A session in another project is not there to read.

**Rationale**: The same reason the other lines exist. An agent told the act in the briefing
does not have to discover the tool by failing. The restraint is the second and third
sentences: a read is not a takeover, and another project is a refusal.
