---

description: "Task list for 001-agent-daemon-ui"
---

# Tasks: Agent daemon and basic UI

**Input**: Design documents from `specs/001-agent-daemon-ui/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: Included. The spec's success criteria are behavioural and [quickstart.md](./quickstart.md)
makes `swift test` with no network the gate for the whole feature, so tests are part of the work
rather than an option.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to
- Paths follow the structure in plan.md: `Packages/AgentsKit/` for anything that decides anything,
  `App/Sources/` for the window, `Daemon/Sources/` for the helper's twenty lines.

---

## Phase 1: Setup

**Purpose**: Make the bundle the design assumes buildable before any of it is written

- [X] T001 Add the `agentsd` target to `project.yml`: type `tool`, macOS, depends on the `AgentsKit` package, sources `Daemon/Sources`
- [X] T002 Add a copy-files build phase to the `Agents` target in `project.yml` putting the built `agentsd` into `Contents/Helpers`, and confirm with `xcodegen generate && xcodebuild -scheme Agents build` that the helper lands in the bundle
- [X] T003 [P] Create `Daemon/Sources/main.swift` as a placeholder that prints its version and exits, so the copy phase has something real to carry
- [X] T004 [P] Delete the scaffold placeholder `Packages/AgentsKit/Sources/AgentsKit/Agents.swift` and `Packages/AgentsKit/Tests/AgentsKitTests/AgentsTests.swift`
- [X] T005 [P] Confirm `App/Agents.entitlements` has no `com.apple.security.app-sandbox` key and that `ENABLE_HARDENED_RUNTIME: YES` is set in `project.yml`, per the plan's Constraints

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The parts every story needs. Nothing user-visible happens until these exist.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

### The wire

- [X] T006 Implement line-delimited JSON-RPC 2.0 framing in `Packages/AgentsKit/Sources/AgentsKit/JSONRPC/JSONRPCCodec.swift`: one object per line, no headers, requests, responses, notifications and errors
- [X] T007 Implement `JSONRPCConnection` as an actor in `Packages/AgentsKit/Sources/AgentsKit/JSONRPC/JSONRPCConnection.swift` over any pair of byte streams: request/response correlation by id, an `AsyncStream` of incoming notifications, and an incoming-request handler the owner supplies
- [X] T008 [P] Map JSON-RPC errors to a Swift error type in `Packages/AgentsKit/Sources/AgentsKit/JSONRPC/JSONRPCError.swift`, keeping `code`, `message` and `data`, with `-32601 Method not found` distinguishable because resume-versus-load depends on recognising it
- [X] T009 [P] Unit-test the codec and the connection in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/JSONRPCTests.swift`: split lines, concatenated lines, a reply arriving out of order, an unknown incoming method, a malformed line not killing the connection

### The types

- [X] T010 [P] Create `Agent` in `Packages/AgentsKit/Sources/AgentsKit/Model/Agent.swift` with the fields and invariants in data-model.md: `id` UUID ours and never changing, `runtimeId`, `cwd` absolute URL, `title` optional, `state`, `runtimeSessionId` optional in any state, `startOptions`, `createdAt`, `lastActivityAt`, `endedReason` optional, `archivedReason` optional
- [X] T011 [P] Create `AgentState` and its transition function in `Packages/AgentsKit/Sources/AgentsKit/Model/AgentState.swift`: exactly one of `running`, `waitingOnUser`, `finished`, `stopped`, `archived`; `finished` reachable only by `endTurn`; nothing reaching `archived` without the user; a prompt from any non-running state starting a turn
- [X] T012 [P] Create `EndedReason` in `Packages/AgentsKit/Sources/AgentsKit/Model/EndedReason.swift` with exactly `endTurn`, `maxTokens`, `maxTurnRequests`, `refusal`, `cancelled`, `processDied`, `daemonGone`
- [X] T013 [P] Create `TranscriptEntry` in `Packages/AgentsKit/Sources/AgentsKit/Model/TranscriptEntry.swift`: `id`, `at`, `kind`, payload, with the eleven kinds in data-model.md including `runtimeNote`
- [X] T014 [P] Create `ConfigOption`, `StartOptions` and `PermissionRequest` in `Packages/AgentsKit/Sources/AgentsKit/Model/Options.swift` and `.../Model/PermissionRequest.swift`, keeping `configOptions` exactly as advertised and never interpreting a field beyond `id`, `name`, `description`, `category`, `type`, `currentValue`, `options`
- [X] T015 [P] Unit-test the state machine in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentStateTests.swift`, including the transitions that must be refused

### The record

- [X] T016 Implement `AgentStore` in `Packages/AgentsKit/Sources/AgentsKit/Store/AgentStore.swift`: the layout in data-model.md under `~/Library/Application Support/Agents/`, `agent.json` written whole and atomically on every change, `transcript.jsonl` appended and never rewritten, a single writer, and a root that is injectable so tests use a temporary directory
- [X] T017 Implement recovery in `Packages/AgentsKit/Sources/AgentsKit/Store/AgentStore+Recovery.swift`: read every agent record on start, tolerate a half-written last line in a transcript, and return the agents whose processes must be checked
- [X] T018 [P] Implement paged transcript reads in `Packages/AgentsKit/Sources/AgentsKit/Store/TranscriptReader.swift`, newest last, by range, so nothing ever loads a whole transcript
- [X] T019 [P] Unit-test the store in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentStoreTests.swift`: append, reread in order, a truncated final line, an atomic record write surviving a simulated crash mid-write

### Talking to a runtime

- [X] T020 Create the ACP wire types in `Packages/AgentsKit/Sources/AgentsKit/ACP/ACPTypes.swift` for the calls in `contracts/acp-client.md`, with `_meta` decoded but never read
- [X] T021 Implement `ACPSession` as an actor in `Packages/AgentsKit/Sources/AgentsKit/ACP/ACPSession.swift`: spawn the runtime, `initialize` advertising `fs.readTextFile false`, `fs.writeTextFile false` and `terminal false`, `session/new` with `cwd` and `mcpServers: []` and no `sessionId`, `session/prompt`, `session/cancel`, `session/close`, and the set-option call
- [X] T022 Implement the incoming-request side in `Packages/AgentsKit/Sources/AgentsKit/ACP/ACPSession+Server.swift`: `session/request_permission` surfaced to the owner and held until answered, everything else answered `-32601`
- [X] T023 Implement `session/update` decoding in `Packages/AgentsKit/Sources/AgentsKit/ACP/SessionUpdate.swift` mapping each update to a `TranscriptEntry`, joining message chunks by the runtime's message id, updating a tool call already recorded, and logging-then-skipping an unknown update type
- [X] T024 Implement ending an agent in `Packages/AgentsKit/Sources/AgentsKit/ACP/ACPSession+End.swift` in the order FR-011b requires: cancel a running turn, wait for the `cancelled` reply, `session/close`, terminate, and `SIGKILL` only after a few seconds

### A runtime to talk to, in tests

- [X] T025 Build `FakeACPAgent` in `Packages/AgentsKit/Tests/AgentsKitTests/Fake/FakeACPAgent.swift`: an in-process ACP agent that is deterministic and scriptable — advertises chosen `sessionCapabilities` and `configOptions`, emits chosen updates, ends a turn with a chosen stop reason, can ask a permission, and can be told to die mid-turn
- [X] T026 [P] Test `ACPSession` against the fake in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ACPSessionTests.swift`: a whole turn, an unknown update, an unknown incoming method answered `-32601`, and a process that dies mid-turn becoming `processDied`

### Finding the runtimes

- [X] T027 Implement the runtime catalogue in `Packages/AgentsKit/Sources/AgentsKit/Runtimes/RuntimeCatalog.swift` with exactly the three recipes from data-model.md: `claude` → `npx -y @agentclientprotocol/claude-agent-acp`, `grok` → `grok agent stdio`, `copilot` → `copilot --acp`
- [X] T028 Implement PATH resolution in `Packages/AgentsKit/Sources/AgentsKit/Runtimes/LoginShellPath.swift`: read the user's login-shell PATH once, cache it, and fall back to a short list of usual places. This is the plan's first-thing-that-breaks risk and none of the three is on a GUI app's inherited PATH
- [X] T029 Implement discovery in `Packages/AgentsKit/Sources/AgentsKit/Runtimes/RuntimeDiscovery.swift` returning `available(URL)`, `missing(lookedIn:)` or `needsSignIn(authMethods:fixCommand:)`, reading `sessionCapabilities.resume` from `initialize` rather than assuming it, and never treating the presence of `authMethods` as proof of being signed out
- [X] T030 [P] Test discovery in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/RuntimeDiscoveryTests.swift` with a stubbed PATH: found, missing with where it looked, and a runtime whose `initialize` fails

### The daemon, and the app's way in

- [X] T031 Implement single-instance and paths in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonLock.swift`: an exclusive `flock` on `daemon.lock`, a daemon that loses it exiting silently and touching nothing
- [X] T032 Implement the Unix socket server in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonServer.swift` at `~/Library/Application Support/Agents/daemon.sock`, serving several connections at once over the same `JSONRPCConnection` code, with every notification going to all of them
- [X] T033 Implement the app-facing method and notification types in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonAPI.swift`, matching `contracts/daemon-api.md` exactly
- [X] T034 Implement `DaemonCore` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`: owns an `AgentSession` per live agent, writes through `AgentStore`, and fans changes out as `agent/changed`, `agent/entry`, `agent/permission` and `runtime/changed`
- [X] T035 Implement the exit rule in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Lifetime.swift`: exit when holding no agents and no client is connected after a short grace period, where running, waiting on a permission, and finished-with-a-live-process all count as holding
- [X] T036 Replace `Daemon/Sources/main.swift` with the real twenty lines: take the lock, start `DaemonCore`, serve, exit when it says to
- [X] T037 Implement `DaemonClient` in `Packages/AgentsKit/Sources/AgentsKit/Client/DaemonClient.swift`: connect to the socket, and when nothing answers spawn `Contents/Helpers/agentsd` with `posix_spawn` and `POSIX_SPAWN_SETSID` so it is not in the app's process group, then retry with backoff for a few seconds
- [X] T038 [P] Test the daemon end to end against fake agents in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: two clients seeing the same state, a second daemon losing the lock and exiting, and the exit rule firing and not firing

**Checkpoint**: A daemon that runs agents and an API to drive it, all of it testable with `swift test`

---

## Phase 3: User Story 1 - Start an agent and watch it work (Priority: P1) 🎯 MVP

**Goal**: Choose a folder, a runtime and an instruction, and watch the work appear in the window
without opening a terminal.

**Independent Test**: Start an agent in a scratch folder with an instruction that changes a file, and
watch the work appear in the window and the change appear on disk.

### Tests for User Story 1

- [X] T039 [P] [US1] Integration test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/StartAgentTests.swift`: `agents/options` then `agents/start` against the fake creates one session, applies the chosen options, sends the prompt, and the agent is `running` with entries arriving
- [X] T040 [P] [US1] Test the two-step start in the same file: options are advertised by `session/new`, so the session exists before the user has chosen, and `agents/start` reuses the session `agents/options` created rather than making a second one

### Implementation for User Story 1

- [X] T041 [US1] Implement `runtimes/list` and `agents/options` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Start.swift`
- [X] T042 [US1] Implement `agents/start` in the same file: create the agent record with our UUID, create the session, record the runtime's `sessionId` against it, apply `startOptions` with the set-option call, then send the first prompt
- [X] T043 [US1] Take the agent's title from the runtime's own session title where there is one, and the first line of the instruction where there is not, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Start.swift` (FR-007a)
- [X] T044 [P] [US1] Build the agent list in `App/Sources/AgentList/AgentListView.swift`: every agent with its state, title, folder and runtime, grouped so running is not mixed with finished, and an empty state that says how to start the first one rather than showing an error
- [X] T045 [P] [US1] Build the transcript view in `App/Sources/Transcript/TranscriptView.swift`, rendering each entry kind, appending live from `agent/entry`, windowed so a long transcript never loads whole
- [X] T046 [US1] Build the start sheet in `App/Sources/StartAgent/StartAgentView.swift`: folder picker, runtime picker listing what was found and saying where we looked for what was not, instruction field, and a start button that does nothing while the instruction is empty
- [X] T047 [US1] Build the options form in `App/Sources/StartAgent/OptionsForm.swift` generated from the advertised `configOptions`: render by `type`, order by `category`, skip an unrecognised `type` rather than guessing, still start when a runtime advertises none, plus the free-text extra-arguments field split as a shell would
- [X] T048 [US1] Wire the app to the daemon in `App/Sources/AppModel.swift`: connect on launch through `DaemonClient`, list, subscribe, and hold no agent state of its own
- [X] T049 [US1] Show a runtime that is starting as a state rather than a freeze in `App/Sources/AgentList/AgentRow.swift`, since a first Claude start waits on npm

**Checkpoint**: The app starts a real agent and shows its work. This is the MVP.

---

## Phase 4: User Story 2 - The work survives the window (Priority: P1)

**Goal**: Quit or crash the app and the agents keep working, with everything they said while the
window was shut.

**Independent Test**: Start a long-running agent, force quit the app, see the process alive and the
folder still changing, reopen and see everything produced while the app was gone.

### Tests for User Story 2

- [X] T050 [P] [US2] Integration test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonSurvivalTests.swift`: kill the client connection mid-turn, the agent keeps running and keeps recording, a new client sees everything produced while nothing was connected
- [X] T051 [P] [US2] Test recovery in the same file: agent records left as `running` with no live process become `stopped` with `daemonGone`, before the daemon accepts a connection

### Implementation for User Story 2

- [X] T052 [US2] Make the spawned daemon genuinely detached in `Packages/AgentsKit/Sources/AgentsKit/Client/DaemonClient.swift`: its own session, no inherited pipes that die with the app, stdout and stderr to `daemon.log`
- [X] T053 [US2] Implement start-up recovery in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift`, running before the socket accepts anything so no client ever sees a state known to be a lie (FR-019b)
- [X] T054 [US2] Append transcript entries as updates arrive rather than at turn end, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`, so a daemon that dies mid-turn still leaves an honest record
- [X] T055 [US2] Implement reconnect in `App/Sources/AppModel.swift`: on connect, list, ask for the recent transcript of whatever is open, and subscribe, with no special case for "the app crashed"
- [X] T056 [US2] Roll `daemon.log` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonLog.swift` so a long-lived daemon cannot fill the disk

**Checkpoint**: The daemon earns its existence

---

## Phase 5: User Story 3 - Follow up, and stop (Priority: P2)

**Goal**: Send a message to a working agent, answer what it asks, and stop it when it goes wrong.

**Independent Test**: Send a follow-up that changes what an agent is doing and see the change; answer
a permission question; stop the agent and see it stop.

### Tests for User Story 3

- [X] T057 [P] [US3] Integration test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/FollowUpTests.swift`: a follow-up to a running agent reaches it and is recorded, and a follow-up to a stopped agent is refused with something the app can show rather than silently dropped
- [X] T058 [P] [US3] Integration test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/PermissionTests.swift`: a permission asked with no client connected is held, the agent stays alive, the daemon does not exit, and the question is delivered when a client connects
- [X] T059 [P] [US3] Test in the same file that stopping an agent that is waiting answers the outstanding request `{"outcome": {"outcome": "cancelled"}}` rather than leaving it hanging

### Implementation for User Story 3

- [X] T060 [US3] Implement `agents/prompt` for a running agent in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Prompt.swift`
- [X] T061 [US3] Implement `agents/stop` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Stop.swift` using the cancel-close-terminate order, recording `cancelled`
- [X] T062 [US3] Implement `permissions/pending` and `permissions/answer` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Permissions.swift`: at most one outstanding request per agent, never answered by us, and `waitingOnUser` while it waits
- [X] T063 [US3] Implement `agents/setOption` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Options.swift`, and follow a `config_option_update` or a mode change the runtime makes itself
- [X] T064 [P] [US3] Build the composer in `App/Sources/Transcript/Composer.swift`, which says the agent is stopped rather than discarding what was typed
- [X] T065 [P] [US3] Build the permission view in `App/Sources/Permission/PermissionView.swift`: the tool call, the agent's own options as buttons, and nothing that answers on the user's behalf
- [X] T066 [US3] Put pending permissions at the top of the window on connect in `App/Sources/AgentList/AgentListView.swift`, so a question asked while the app was shut is the first thing seen
- [X] T067 [US3] Add stop to the agent row and the transcript header in `App/Sources/AgentList/AgentRow.swift`

**Checkpoint**: The agent can be talked to, answered and stopped

---

## Phase 6: User Story 5 - Pick a stopped agent back up (Priority: P2)

**Goal**: A stopped, finished or archived agent carries on from where it was, as the same agent.

**Independent Test**: Start an agent, let it learn something, stop it, restart the Mac, follow up, and
see it answer knowing what it knew.

### Tests for User Story 5

- [X] T068 [P] [US5] Integration test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ResumeTests.swift` against a fake that advertises `resume`: the session is resumed, no replay is recorded, and the transcript is not duplicated
- [X] T069 [P] [US5] Test in the same file against a fake that advertises only `loadSession`: `session/load` is used, its replayed updates are discarded, and the transcript still matches what was there before
- [X] T070 [P] [US5] Test in the same file that a runtime which no longer has the session produces a `runtimeNote`, a new runtime session recorded against the same agent id, and no new agent

### Implementation for User Story 5

- [X] T071 [US5] Implement pick-up in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Resume.swift`: a prompt to a stopped, finished or archived agent starts the runtime, resumes where `sessionCapabilities.resume` is advertised and loads where it is not, and unarchives on the way through
- [X] T072 [US5] Discard a `session/load` replay in `Packages/AgentsKit/Sources/AgentsKit/ACP/SessionUpdate.swift` by treating updates during a load as confirmation rather than content
- [X] T073 [US5] Handle the session being gone in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Resume.swift`: record a `runtimeNote`, start a fresh runtime session for the same agent, keep the history, and tell the app (FR-012d)
- [X] T074 [US5] Release a finished agent's process in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Lifetime.swift` when a turn ends with `endTurn`, since the session can be picked up later (FR-012e)
- [X] T075 [P] [US5] Show picking up as its own moment in `App/Sources/Transcript/TranscriptView.swift`, rendering `runtimeNote` entries plainly so the gaps in an agent's life are visible

**Checkpoint**: Stopping something is no longer throwing it away

---

## Phase 7: User Story 4 - Getting finished work out of the way (Priority: P3)

**Goal**: Finished agents are visibly separate from busy ones, and anything can be put away and got
back.

**Independent Test**: Run an agent to completion, see it become finished on its own, archive it, find
it in the archive with its history, and bring it back.

### Tests for User Story 4

- [X] T076 [P] [US4] Integration test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ArchiveTests.swift`: a turn ending `end_turn` becomes `finished` and nothing archives itself, and every other stop reason becomes `stopped` with its reason
- [X] T077 [P] [US4] Test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ArchiveTests.swift` that archiving a running agent stops it first, and that an archived agent's transcript is still readable

### Implementation for User Story 4

- [X] T078 [US4] Implement `agents/archive` and `agents/unarchive` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Archive.swift`, stopping a live agent first and recording `archivedReason: byUser`
- [X] T079 [US4] Implement `agents/list` with `includeArchived` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+List.swift`
- [X] T080 [P] [US4] Group the list by state in `App/Sources/AgentList/AgentListView.swift` with archived folded away at the foot
- [X] T081 [P] [US4] Show why an agent ended in `App/Sources/AgentList/AgentRow.swift`: finished, or stopped short with the reason, never both
- [X] T082 [US4] Add archive and unarchive to the row and the transcript header in `App/Sources/AgentList/AgentRow.swift`

**Checkpoint**: All five stories work independently

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T083 [P] Write the live suite in `Packages/AgentsKit/Tests/AgentsKitTests/Live/LiveRuntimeTests.swift`, off unless `AGENTS_LIVE=1`: for each of claude, grok and copilot, initialize, start a session, reach `end_turn`, kill the process, pick the session up by whichever way it advertises, and prove the earlier reply is still there
- [X] T084 [P] Assert in `Packages/AgentsKit/Tests/AgentsKitTests/Live/LiveRuntimeTests.swift` that nothing under test branches on a runtime's name, which is the one-code-path claim in SC-009
- [ ] T085 Pin down how a signed-out runtime actually fails, against a logged-out runtime, and make `needsSignIn` real in `Packages/AgentsKit/Sources/AgentsKit/Runtimes/RuntimeDiscovery.swift`. The error is not documented and was not confirmed during planning
- [ ] T086 [P] Check the ten-agent case by hand for SC-006 and fix what stutters, most likely in `App/Sources/Transcript/TranscriptView.swift`
- [X] T087 [P] Make the window's first-run empty state read the way the spec asks in `App/Sources/AgentList/AgentListView.swift`: how to start the first agent, not an error, and no instructional text on a working screen
- [ ] T088 Walk [quickstart.md](./quickstart.md) end to end on this Mac, including the force-quit and the Mac restart, and record what actually happened
- [X] T089 [P] Update `README.md` with how to run the daemon by hand and where its log and state live, for the next person debugging it

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies
- **Foundational (Phase 2)**: Needs Setup. Blocks every user story
- **US1 (Phase 3)**: Needs Foundational. The MVP
- **US2 (Phase 4)**: Needs Foundational. Independent of US1, though only visible once US1 can start an agent
- **US3 (Phase 5)**: Needs Foundational
- **US5 (Phase 6)**: Needs Foundational, and its tests need US3's prompt path to exist
- **US4 (Phase 7)**: Needs Foundational
- **Polish (Phase 8)**: Needs the stories that are wanted

### Within Phase 2

- T006 → T007 → T008, T009
- T010 to T014 in parallel, then T015
- T016 → T017, T018, T019
- T020 → T021 → T022, T023, T024
- T025 before T026 and before every integration test after it
- T027 → T028 → T029 → T030
- T031, T032, T033 in parallel → T034 → T035 → T036, T037 → T038

### Parallel Opportunities

- T003, T004, T005 together
- The whole of the types block, T010 to T014
- The wire (T006 to T009), the store (T016 to T019) and the runtimes (T027 to T030) are three
  independent tracks once the types exist
- Every test task marked [P] within a story
- In US1, the daemon side (T041 to T043) and the views (T044, T045) until T048 joins them

## Parallel Example: Foundational types

```bash
Task: "Create Agent in Packages/AgentsKit/Sources/AgentsKit/Model/Agent.swift"
Task: "Create AgentState and its transition function in .../Model/AgentState.swift"
Task: "Create EndedReason in .../Model/EndedReason.swift"
Task: "Create TranscriptEntry in .../Model/TranscriptEntry.swift"
Task: "Create ConfigOption, StartOptions and PermissionRequest in .../Model/Options.swift"
```

## Implementation Strategy

### MVP

Phases 1, 2 and 3. That is an app that starts a real agent in a real folder and shows its work, which
is the whole of the product's value and the only part with no substitute.

### Then, in order

1. **US2** next, although it is P1 alongside US1, because until it is done the daemon is elaborate
   plumbing for something a terminal already does.
2. **US3**, which is what makes the window worth leaving open. Permissions land here, and an agent
   that cannot be answered will stall on its first real task, so in practice this arrives sooner than
   its P2 suggests.
3. **US5**, which turns stopping from a loss into a pause.
4. **US4**, which only matters once there are enough agents to be untidy.

### Stopping points

Each checkpoint is a place the work can be left with nothing half-built: an app that starts agents,
then one whose agents survive it, then one that can be talked to, then one that forgets nothing, then
one that stays tidy.
