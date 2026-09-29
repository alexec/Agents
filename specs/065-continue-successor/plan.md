# Implementation Plan: Read Another Session's History

**Branch**: `agents/065-continue-successor` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/065-continue-successor/spec.md`

## Summary

Two changes, and they are one feature.

An agent can **list** the sessions in its own project and **read** one's history, by id or by
exact title. The history is the app's own transcript, rendered as text: what was asked, what
was said, the tools that ran, and the plan as it stood. A long one keeps the first request and
the latest turns and says how many were left out. The session that was read is not written to.
The person starts the new chat themselves and asks it to continue that work.

A **spent allowance** still ends the chat that was refused, on that runtime, with the note it
already writes and the status **Its allowance ran out**. Nothing else happens. The pool, Continue
with, Matching models, and the memory that a runtime is out for every other chat all go. A rate
limit is still retried on that same chat, and that wait is not remembered for anyone else.

The rendering already exists. `Handoff.document` in
`Packages/AgentsKit/Sources/AgentsKitCore/Pool/Handoff.swift` turns a transcript into that text
for a runtime switch. This feature keeps the turn-building and the trim, gives them a header
that does not claim the chat was carried over, and deletes the switch. See [research.md](research.md)
for the decisions, [data-model.md](data-model.md) for what is stored (nothing new), and
[contracts/](contracts/) for the tool sentences and the ending.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), SwiftUI

**Primary Dependencies**:

- AgentsKit and AgentsKitCore, the in-repo package
- The app's MCP server (`AppService`), relayed by `agentsd mcp` to `DaemonCore`
- The transcript record (`transcript.jsonl`) and `TranscriptReader`
- `LimitRecognition`, which already tells a spent allowance from a rate limit

**Storage**: No new file and no new field. A list and a read are derived from the agent records,
the retired tombstones, and `transcript.jsonl`. `pool.json` and `allowances.json` stop being
read or written. They are left on disk. Old agent records keep decoding `poolEntryID`,
`switchingOff` and `allowanceWait`, and a wait found at launch is cleared without a turn being
started. Old transcripts keep their `poolSwitch`, `handoff` and `settingsChanged` lines, which
still draw.

**Testing**:

- swift-testing in `Packages/AgentsKit`
- Unit tests for the history text, the trim, and the lookup sentences (none, several, retired,
  another project, the caller's own session)
- Integration tests on a daemon with fake runtimes: a spent allowance records the note and
  starts nothing; a second chat on the same runtime is not treated as out; a rate limit is
  retried on the same chat; list and read return the sentences in the contract and do not
  write the session that was read
- The pool's switch, wait, continue-with and shared-allowance tests are rewritten or removed
  with the behaviour they lock

**Target Platform**: The macOS app, `agentsd` (including a Linux server, which serves the same
tools), and the iPhone and iPad, which lose the Pool page and Continue with and keep showing
the ran-out status from the record.

**Project Type**: A desktop app with a daemon, and a companion iOS app

**Performance Goals**:

- A list is a walk of the project's agent records. It does not open transcripts.
- A read indexes the transcript the way the window already does (`TranscriptReader`) and
  renders once. A session of tens of megabytes is not held as one string before the trim.

**Constraints**:

- A read never writes the other session: no transcript line, no `lastActivityAt`, no broadcast
  (FR-003).
- Only the caller's project. The project is `agent.projectFolder`, taken from the caller's
  token. There is no parameter for another one (FR-007).
- The person is not asked before a list or a read (FR-008). Both tools go in `AppTool.all`,
  which is what makes the app answer the runtime's permission question itself.
- A spent allowance is a fact about that turn. Nothing is written that would make another chat
  on the same runtime look spent (FR-012).
- Older phones must still decode agent records. No new required field, and no new
  `EndedReason`: credit used up and paid extra usage keep ending as `.allowanceSpent`, with
  the note saying which.

**Scale/Scope**:

- 2 agent tools, `list_sessions` and `read_session`, offered to every agent, including one
  another agent started
- 2 daemon methods
- 1 briefing paragraph
- The pool UI on the Mac, iPhone and iPad removed: the page, the Settings pane, Continue with,
  Matching models, the allowance-wait row
- The carry-on, the wait, and the shared allowance memory removed from the daemon
- The docs listed in the spec

## Constitution Check

The constitution (`.specify/memory/constitution.md`) is still the unfilled template, so there
are no gates to check. The plan follows the repo's own working rules:

- **One path, not two.** History text is one function. The pool's handoff and the new read do
  not each grow a copy. The handoff goes away with the switch, and the function stays.
- **Decide in one place.** Whether a title matches, and what a refusal says, live in one
  function the tool and the tests both call. The daemon does not re-decide in the view.
- **The record stays honest.** A chat that ran out says so, on that chat. Another chat is not
  marked out because this one was. Old switch notes already in a transcript still draw as what
  happened then.
- **Prove it without the pool.** The integration test that used to expect a second runtime
  expects no second conversation, the note, and the status.

Re-checked after design: still no violations.

## Project Structure

### Documentation (this feature)

```text
specs/065-continue-successor/
├── spec.md
├── plan.md              # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── session-tools.md
│   └── allowance-ending.md
└── tasks.md             # /speckit-tasks, not this command
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/AppTool.swift                 # list_sessions, read_session
├── Model/SessionHistory.swift          # the text, moved out of Pool/Handoff.swift
├── Pool/LimitRecognition.swift         # kept; payment defaults to an allowance
├── Pool/PoolWords.swift                # the note sentences, and the old switch drawing
├── Pool/Handoff.swift                  # removed once SessionHistory has its tests
├── Model/EventCatalogue.swift          # drop the three pool events
└── Daemon/DaemonAPI.swift              # agents/listSessions, agents/readSession

Packages/AgentsKit/Sources/AgentsKit/
├── ACP/Serve/AppService.swift          # the two tools, offered to every agent
├── ACP/Serve/Briefing.swift            # one paragraph, including for a helper
├── Daemon/DaemonCore+Sessions.swift    # list and read
├── Daemon/DaemonCore+Pool.swift        # recognition and the per-chat retry stay;
│                                       # carry, wait, and allowance files go
├── Daemon/DaemonCore+Dispatch.swift
└── Store/PoolStore.swift               # removed when nothing loads it

Daemon/Sources/main.swift               # relay the two calls

App/Sources/Pool/                       # removed
App/Sources/Settings/PoolSettingsView.swift
App/Sources/Settings/SettingsWindow.swift
App/Sources/Projects/SidebarItem.swift
App/Sources/Projects/ProjectListView.swift
App/Sources/AgentList/AgentRow.swift    # the allowance-wait lines only
Remote/Sources/Pool/                    # removed
Remote/Sources/Projects/ProjectListView.swift
Remote/Sources/Projects/AgentCard.swift
Remote/Sources/Chat/RemoteChatView.swift

docs/how-to/keep-going-when-a-runtime-runs-out.md
docs/how-to/index.md
docs/explanation/runtime-pool.md        # removed
docs/explanation/index.md
docs/reference/settings.md
docs/reference/statuses.md
docs/reference/events.md
docs/reference/agent-tools.md
docs/reference/runtimes.md
docs/reference/keyboard-shortcuts.md
docs/how-to/limit-spending.md           # the pool cross-link only
```

**Structure Decision**: The tools follow `list_my_agents`: a schema in `AppService`, a relay in
`agentsd mcp`, a daemon method keyed by the caller's token. The text of a history is pure and
lives in Core, so it is tested without a daemon. The pool's UI is deleted rather than hidden.
`LimitRecognition` stays, because the note on the chat that was refused is still a recognised
ending and not a generic failure.

## Complexity Tracking

None. The constitution has no gates, and this feature removes a path rather than adding one
beside it.

## Implementation notes

These are for `/speckit-tasks`. They are not a second design.

1. **History text first**, with its unit tests, taken from `Handoff.document`. Nothing calls
   the new tools yet, and the pool still builds, so this step is safe to land alone.
2. **The two tools**, wired as `list_my_agents` is, and offered whether or not
   `startedByAgent` is set. A helper's daemon check allows them. `start_agent`'s check does
   not grow a hole.
3. **The ending, before the deletion.** `applyRecognition` records the note and sets
   `.allowanceSpent` or `.rateLimited`, and does not mark a shared allowance or set
   `pendingCarry`. Every `carryOnIfPending` call site goes. The app still builds with the
   pool pages present and doing nothing, which keeps the deletion reviewable on its own.
4. **The pool UI and the dead daemon code**, then the docs. Old transcript kinds stay
   decodable and drawable. `Carry on` for a blocked chat (039) is a different button and stays.

A chat found at launch with `allowanceWait` set has that wait cleared and is not resumed. If
it is stopped with no reason, the reason becomes `.allowanceSpent`. The note already in its
transcript is left as it was.
