# Tasks: An Agent Can Run a Few Agents of Its Own

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/agent-tools.md](contracts/agent-tools.md), [quickstart.md](quickstart.md)

**Tests**: Included. The quickstart names each property to be tested, and this repo tests every
daemon behaviour. Write each test before the code that makes it pass. Model the integration tests
on `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowToolTests.swift`, which already
drives a daemon tool call through a bound app token with a fake runtime.

**Where**: Everything runs in the worktree `/tmp/w-028` on branch `028-agents-manage-agents`. Never
edit the shared checkout at `/Users/alexcollins/Agents`. Paths below are relative to `/tmp/w-028`.
`Pkg/` stands for `Packages/AgentsKit/`.

**Glossary**: A *helper* is an agent whose `startedByAgent` is set. Its *starter* is the agent
named there. A *place* is one of the project's three.

## Phase 1: Setup

- [X] T001 Confirm the baseline in `/tmp/w-028`: run `swift test` in `Packages/AgentsKit` once and write down which tests fail on main before any change. The suite is flaky under load, so a failure there later is only this lane's if it is new.

---

## Phase 2: Foundational (blocks every story)

The record, the state table and the wire shapes. Nothing behaves differently yet.

- [X] T002 [P] Add table tests in `Pkg/Tests/AgentsKitTests/Unit/AgentStateTests.swift`: for every `AgentState`, `AgentEvent.stoppedByAgent` is accepted exactly where `.stoppedByUser` is, goes to `.stopped` and sets the ending to `.set(.stoppedByAgent)`. `AgentEvent.archivedByAgent` is accepted exactly where `.archivedByUser` is, with the same next state and ending, and sets the archive reason to `.set(.byAgent)`. Derive the expected rows from the `…ByUser` transitions in a loop, so the two stay twins.
- [X] T003 [P] Add codec tests in `Pkg/Tests/AgentsKitTests/Unit/` (in the existing Agent or EndedReason test file, whichever holds the `unrecognised` decode test). An `Agent` with `startedByAgent` round-trips, and a record without the key decodes as nil. `"stoppedByAgent"` decodes as `EndedReason.stoppedByAgent`. An unknown archive reason still decodes as `.byUser`.
- [X] T004 Add `case stoppedByAgent` to `EndedReason` in `Pkg/Sources/AgentsKitCore/Model/EndedReason.swift`, with summary `"Stopped by the agent that started it"`. Leave `init?(stopReason:)` alone: this is not a protocol stop reason.
- [X] T005 In `Pkg/Sources/AgentsKitCore/Model/Agent.swift`: add `public var startedByAgent: UUID?` after `startedByRun`, with a doc comment ("The agent whose start_agent call made this one. Set once, never changed."). Add it to `CodingKeys`, `init(from:)` (`decodeIfPresent`), `encode` (`encodeIfPresent`) and the memberwise init (default nil). Add `case byAgent` to `Agent.ArchivedReason`.
- [X] T006 In `Pkg/Sources/AgentsKitCore/Model/AgentState.swift`: add `case stoppedByAgent` and `case archivedByAgent` to `AgentEvent`. Add their rows to the transition table, mirroring `.stoppedByUser` (ending `.set(.stoppedByAgent)`, `clearsPickUpCount: true`) and `.archivedByUser` (archive reason `.set(.byAgent)`), and refusing wherever the twin refuses. Make T002 and T003 pass.
- [X] T007 [P] Create `Pkg/Sources/AgentsKitCore/Model/HelperLimit.swift`: `public enum HelperLimit { public static let perProject = 3 }`, plus a pure function `placesInUse(in project: URL, agents: some Sequence<Agent>, reserved: Int) -> Int`. It counts agents with `startedByAgent != nil`, `Project.standardize(cwd) == project` and `state != .archived`, plus `reserved`. Unit-test it in `Pkg/Tests/AgentsKitTests/Unit/HelperLimitTests.swift`: archived agents are excluded, other folders are excluded, the person's agents are excluded, and stopped or finished helpers count.
- [X] T008 [P] In `Pkg/Sources/AgentsKitCore/Model/AppTool.swift`, add `startAgent = "start_agent"`, `stopAgent = "stop_agent"`, `archiveAgent = "archive_agent"` and `listMyAgents = "list_my_agents"`, with one-line doc comments in the file's voice.
- [X] T009 [P] In `Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, add `Method.agentsStartHelper = "agents/startHelper"`, `agentsStopHelper = "agents/stopHelper"`, `agentsArchiveHelper = "agents/archiveHelper"` and `agentsListHelpers = "agents/listHelpers"`. Add the request types `StartHelperRequest { token, prompt, runtime?, model?, permissionMode? }`, `HelperRequest { token, agentID: String }` (a String, so a malformed id is refused in words rather than failing decode) and `ListHelpersRequest { token }`, and `Failure.notYours` with the next free code. Follow `ManageWorkflowsRequest`'s shape.
- [X] T010 In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, give `stop(_:)` and `archive(_:)` a `by cause: StopCause = .person` parameter, where `enum StopCause { case person, agent(UUID) }` is defined beside them. For `.agent(starter)`: record `.runtimeNote("‹starter title› stopped this agent.")` (or "archived") before moving, move on `.stoppedByAgent` / `.archivedByAgent` instead of the user events, and when archive stops first, pass the cause through. Nothing else in either function changes, and every existing caller compiles unchanged. Fall back to "Another agent" when the starter has no title or is gone.

**Checkpoint**: `swift test` shows the same results as T001 plus the new passing tests. Both schemes still build.

---

## Phase 3: User Story 1 — An agent starts helpers and they appear to the person (P1) 🎯 MVP

**Goal**: An agent can start an agent in its own project, and the person sees it and who started it.

**Independent test**: Call `startHelper` with a bound token. A new agent exists in the caller's folder, runs the prompt, carries `startedByAgent`, and its transcript opens with "Started by …".

- [X] T011 [US1] Create `Pkg/Tests/AgentsKitTests/Integration/HelperAgentTests.swift` with start tests, in the style of `WorkflowToolTests.swift`. A bound caller's `startHelper` makes an agent with `cwd` equal to the caller's standardised `cwd`, `startedByAgent == caller.id`, and the prompt as its first queued prompt. The result note matches the contract's success text. The helper's first transcript entry is the runtime note "Started by ‹caller title›." An unbound token is refused with "That conversation is not open any more". An empty prompt is refused with "Nothing was started: say what the agent is to do." A `runtime` this build doesn't know is refused, naming the runtimes it does know, and leaves no agent behind.
- [X] T012 [US1] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`, extract the settings-to-`StartRequest` part of `startAgent(for:run:prompt:)` / `settled(...)` into `func startRequest(settings: WorkflowSettings, folder: URL, prompt: String, managesAgents: Bool) async throws -> DaemonAPI.StartRequest`. The workflow path calls it with `managesAgents: true`, and its behaviour must not change: run `WorkflowSettingsFlowTests` and `WorkflowRefusalTests` before and after.
- [X] T013 [US1] Thread `managesAgents` through session creation in `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` and `DaemonCore+AppTools.swift`. `appServer(token:managesAgents:)` appends `"--no-agent-tools"` to the args when false. `freshSession(runtimeID:cwd:mcpServers:managesAgents: = true)` passes it through. `DaemonAPI.StartRequest` gains an internal-only way to say "helper". Prefer a `DaemonCore`-side parameter on `start` over a wire field, so the app can't ask for it. `connect(_:runtime:for:)` uses `agent.startedByAgent == nil`.
- [X] T014 [US1] Create `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Helpers.swift` with `public func startHelper(_ request: DaemonAPI.StartHelperRequest) async throws -> (note: String, agentID: UUID)`. Resolve the caller from `appTokens` (the same refusal as `manageWorkflows`). Folder = `Project.standardize(caller.cwd)`. Trim the prompt and refuse it if empty. Build `WorkflowSettings` from runtime, model and permission mode, and call T012's function with `managesAgents: false`. Call `start`. Then set `startedByAgent = caller.id`, record the runtime note "Started by ‹caller title›." as the helper's first transcript entry, and `changed(agent)`. Prefix `SettingRefused` and other start errors with "Nothing was started: ". The limit and one-level checks come in US2. Leave a `// US2:` marker where they go.
- [X] T015 [US1] Add the `agentsStartHelper` case to `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, returning `["note": .string(note), "agentID": .string(id.uuidString)]`. Make T011 pass.
- [X] T016 [P] [US1] Add the `start_agent` tool to `Pkg/Sources/AgentsKit/ACP/Serve/AppService.swift`: `startAgentTool` JSON with the schema and description from `contracts/agent-tools.md` (the description must say "this project", "at most three … at once", "archiving one frees its place", and "only when part of the work can run alongside the rest"). Add a `StartAgentSink` typealias and init parameter (defaulting to a refusal, as the others do) and a suffix-matched dispatch case. Add a `managesAgents: Bool = true` init parameter, and include the tool in `tools/list` only when it is true. Extend `Pkg/Tests/AgentsKitTests/Unit/AppServiceTests.swift` to cover this: `tools/list` has `start_agent` by default and not with `managesAgents: false`, and a call relays the prompt and settings to the sink.
- [X] T017 [US1] In `Daemon/Sources/main.swift`: parse an optional `--no-agent-tools` after the token (`CommandLine.arguments.dropFirst(3).contains("--no-agent-tools")`), pass `managesAgents:` to `AppService`, and relay `start_agent` to `agentsStartHelper` with `StartHelperRequest(token:…)`.
- [X] T018 [P] [US1] Mac row mark in `App/Sources/AgentList/AgentRow.swift`: beside the workflow mark, when `agent.startedByAgent` is set, show `Image(systemName: "person.2")` with the same `.appText(.fine)` and `.tertiary` styling, and `.help` / `.accessibilityLabel` "Started by ‹starter title›". Read the title live from the model's agents, falling back to "another agent". Use a computed `startedByAgentName` in the style of `startedByWorkflowName`.
- [X] T019 [P] [US1] Phone card mark in `Remote/Sources/Projects/AgentCard.swift`: the same mark and label, matching how that card lays out the title line.

**Checkpoint**: The MVP. An agent can start a helper, and the person can see it and act on it.

---

## Phase 4: User Story 2 — The limits hold (P1)

**Goal**: The project never holds more than three helpers that are not archived. There is no reach beyond the caller's own helpers, and no nesting.

**Independent test**: Three helpers exist, so a fourth start is refused and names them. Archive one and the next start succeeds. Four concurrent starts on an empty project end with exactly three. Helpers get no tools, and their calls are refused.

- [X] T020 [US2] Add limit and nesting tests to `Pkg/Tests/AgentsKitTests/Integration/HelperAgentTests.swift`:
  - (a) With three helpers not archived (from any starters in the project), a fourth start is refused with the contract text naming all three titles, and no agent is made.
  - (b) After one is archived, by the person via `archive(_:)`, a start succeeds.
  - (c) Stopped and finished helpers still count.
  - (d) Helpers in another project don't count.
  - (e) Concurrency: fire four `startHelper` calls at once against a fake runtime whose handshake is held open until all four have been called, then release it. Exactly three succeed and one is refused. Repeat the test body ten times in a loop.
  - (f) A helper's own `startHelper` is refused with the contract text.
  - (g) A helper's `appServer` args contain `--no-agent-tools` both when started and after being picked back up (`connect`). Check the args recorded by the fake launcher, not by reading source.
  - (h) A workflow's agent (`startedByWorkflow` set) *can* start a helper.
  - (i) Restart: rebuild the daemon from the same store, then confirm `startedByAgent` survives and the place count is unchanged.
- [X] T021 [US2] Add `var reservedStarts: [URL: Int] = [:]` to `DaemonCore` in `Pkg/Sources/AgentsKit/Daemon/DaemonCore.swift`, with a comment on why it exists (the actor gives up its exclusivity at the first `await`, and a runtime handshake takes seconds).
- [X] T022 [US2] In `DaemonCore+Helpers.swift` `startHelper`, **before the first `await`**: refuse if `caller.startedByAgent != nil` (`Failure.notYours`, contract text). Compute `HelperLimit.placesInUse(in: folder, agents: agents.values, reserved: reservedStarts[folder, default: 0])`. If it is `>= HelperLimit.perProject`, refuse with `Failure.notYours` and the text naming the titles of the non-archived helpers in the folder. Otherwise increment `reservedStarts[folder]` and `defer`-decrement it on every exit path, success or throw. The success note reports places in use *after* the reservation is released and the helper exists. Make T020 pass.
- [X] T023 [US2] Chain depth in `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift` `workflowChainDepth(causedBy:)`: when `runInFlight(for:)` finds nothing and the agent has `startedByAgent`, return the starter's `workflowChainDepth`. That way a workflow → agent → helper → workflow loop counts against the existing chain limit. Add a test in `HelperAgentTests.swift` where a workflow's agent's helper finishes and fires a workflow at depth + 1.

**Checkpoint**: US1 and US2 together are the whole P1 promise.

---

## Phase 5: User Story 3 — An agent stops and archives what it started (P2)

**Goal**: The starter can stop and archive its own helpers, and only those.

**Independent test**: Stop a working helper, and it ends as "Stopped by the agent that started it" with a note naming the starter. Archive it, and the place count drops. Every attempt at someone else's agent, or at itself, is refused and changes nothing.

- [X] T024 [US3] Add stop/archive tests to `Pkg/Tests/AgentsKitTests/Integration/HelperAgentTests.swift`:
  - (a) Stopping a running helper: its state is `.stopped`, `endedReason == .stoppedByAgent`, and the transcript has "‹starter› stopped this agent." Pending permission questions are cancelled just as by `stop(_:)`.
  - (b) Stopping an already-stopped or finished helper changes nothing, and the note is `"‹title›" had already stopped; nothing changed.`
  - (c) Archiving a running helper stops it first, then archives it with `archivedReason == .byAgent`, and the places in use drop by one.
  - (d) An already-archived target is refused with the contract text.
  - (e) Refusals that change nothing: targeting the caller itself, an agent the person started, one a workflow started, and one another agent started; a malformed id; an unknown id. Snapshot `agents` before and after, and require them to be equal.
  - (f) The project's workflows fire `agentStopped` for a helper stopped this way, just as for any stop.
- [X] T025 [US3] In `DaemonCore+Helpers.swift`, add `stopHelper(_:)` and `archiveHelper(_:)`. Resolve the caller (refuse if it is a helper). Parse `agentID` as a UUID ("there is no agent with that id"). Check in this order: the target exists, the target isn't the caller, `target.startedByAgent == caller.id`, and the target isn't archived. Then call `stop(id, by: .agent(caller.id))` / `archive(id, by: .agent(caller.id))`. For stop, when the target isn't holding a runtime and isn't coming back, return the "had already stopped" note without calling `stop`. Every refusal uses `Failure.notYours` or `noSuchAgent` with the contract's exact text.
- [X] T026 [US3] Add the `agentsStopHelper` and `agentsArchiveHelper` cases to `DaemonCore+Dispatch.swift`. Make T024 pass.
- [X] T027 [P] [US3] Add the `stop_agent` and `archive_agent` tools to `AppService.swift`, with the schemas from the contract, one `HelperSink` typealias `(action, agentID) async -> Outcome` (or two sinks, matching the file's style), suffix dispatch, and inclusion only when `managesAgents`. Add a missing-`id` refusal in words. Extend `AppServiceTests.swift`.
- [X] T028 [US3] Relay both tools in `Daemon/Sources/main.swift`.

---

## Phase 6: User Story 4 — An agent can see what it started (P2)

**Goal**: The starter can list its helpers and see how many places are in use.

**Independent test**: Start two helpers and let one finish. The list shows both with the right states and the finished one's outcome line, shows no one else's, and gives the place count.

- [X] T029 [US4] Add list tests to `HelperAgentTests.swift`. The list shows only the caller's helpers that aren't archived, each as `- ‹uuid›: "‹title›" — ‹state›`, with `finished: ‹outcome› — ‹message›` where a report exists and the ending summary where it stopped. Its first line is `‹n› of 3 places in this project are in use.`. With none, it gives the contract's empty text. Another starter's helpers never appear.
- [X] T030 [US4] In `DaemonCore+Helpers.swift`, add `listHelpers(_:)`. It uses the same state words the Mac row's tooltip uses, from `AgentState`, plus "coming back" when `isComingBack`. Add the dispatch case in `DaemonCore+Dispatch.swift`. Make T029 pass.
- [X] T031 [P] [US4] Add the `list_my_agents` tool (no arguments) to `AppService.swift`, included only when `managesAgents`, with a relay in `Daemon/Sources/main.swift`. Extend `AppServiceTests.swift`.

---

## Phase 7: Polish & proof

- [X] T032 [P] Briefing in `Pkg/Sources/AgentsKit/ACP/Serve/Briefing.swift`: add `public static let helpers` with the text from research R8, and a doc comment on why it is conditional. Change `lines(for:)` to `lines(for:managesAgents: Bool = true)`, appending `helpers` after the workflow line only when true, and do the same for `text(for:)`. In `DaemonCore+Commands.swift` `beginTurn`, pass `agents[agentID]?.startedByAgent == nil`. Extend `Pkg/Tests/AgentsKitTests/Unit/BriefingTests.swift`: the line is present by default, absent for a helper, and the whole briefing stays in the file's stated order.
- [X] T033 [P] Update the `AppService` type's doc comment and `AppTool`'s header comment in the files touched above, so they list the tools the app now serves.
- [X] T034 Run the whole package suite: `cd /tmp/w-028/Packages/AgentsKit && swift test`. Compare against T001. Treat a failure as this lane's only if it fails on the branch and not on main across repeated runs (memory: the suite is flaky under load).
- [X] T035 Build both schemes one after the other: `xcodegen generate`, then the two exact `xcodebuild` invocations in `quickstart.md` §2.
- [X] T036 End-to-end run with the `run-app` skill on a scratch root, following `quickstart.md` §3 steps 1–5. Take screenshots of the project page with helpers showing the mark, and after archiving. Check idle and lock first (memory: drive the scratch app only when Alex is away). Otherwise drive through the scratch socket and screenshot without clicking. Record in the findings which runtimes asked the person before running `start_agent` (plan risk 2).
- [ ] T037 Phone: boot Remote against the scratch root and screenshot a project with a helper showing the mark. The tap-through walk is Alex's (memory: no Simulator GUI).
- [ ] T038 Mark the spec's Status as "Implemented", amend any acceptance scenario that the build changed (as 026 did), and commit on `028-agents-manage-agents` in `/tmp/w-028`. Don't merge to main until Alex says it's this lane's turn.

---

## Dependencies & execution order

- **Phase 1 → Phase 2 → stories.** Phase 2 (record, table, wire, `by:` cause) blocks everything.
- **US1 (Phase 3)** needs only Phase 2. It is the MVP.
- **US2 (Phase 4)** needs US1's `startHelper` to add its checks to. T020(g) needs T013.
- **US3 (Phase 5)** needs Phase 2's `by:` cause (T010) and US1's helpers to exist. It is independent of US2, apart from sharing `DaemonCore+Helpers.swift`.
- **US4 (Phase 6)** needs US1. It is independent of US2 and US3.
- **Polish** needs all four stories.

Within a phase, a test task comes before the code that makes it pass. Tasks touching the same file
run in order: `AppService.swift` (T016 → T027 → T031), `main.swift` (T017 → T028 → T031),
`DaemonCore+Helpers.swift` (T014 → T022 → T025 → T030), `HelperAgentTests.swift` (T011 → T020 →
T024 → T029).

## Parallel opportunities

- **Phase 2**: T002, T003, T007, T008 and T009 touch different files and can run together, then T004–T006 and T010.
- **US1**: T018 (Mac row) and T019 (phone card) are independent of each other and of the daemon work once T005 has landed. T016 (AppService) can run alongside T014 (daemon).
- **US3 and US4** can be built in parallel after US1 by separate hands, if the shared files are merged in order.
- **Polish**: T032 and T033 together.

## Implementation strategy

1. **MVP = Phases 1–3 (US1).** An agent starts a helper, and the person sees who started it. It is demonstrable, but it isn't safe to ship alone, because the limits aren't there yet.
2. **Shippable = MVP + US2.** This is the P1 promise: helpers are bounded, can't reach other projects and can't nest. Don't merge before this point.
3. **Then US3 and US4**, which give the starter control over its helpers and let it see their state.
4. **Then Polish**, ending with the run-app proof and the commit.

---

## Implementation notes (2026-09-24)

- **Tests**: 1,300 pass (1,254 baseline + 46 new), three full runs in a row. `HelperAgentTests` (21), `AgentToolsServiceTests` (8), `HelperLimitTests` (7), `HelperRecordTests` (5), and additions to `AgentStateTests`, `AppServiceTests` and `BriefingTests`.
- **Builds**: Agents (macOS) and Remote (iOS Simulator) both succeed.
- **Live run** on a scratch root with Claude (`/tmp/run-a028-1.png`, `/tmp/run-a028-2.png`):
  - `start_agent` ×2 → `Started "…" (id …). 1/2 of 3 places …`
  - `list_my_agents` showed working, then `finished: done — …`
  - `archive_agent` on a helper → `Archived "…". 1 of 3 places …`
  - `archive_agent` on itself → `Nothing changed: an agent cannot archive itself.`
  - a fourth `start_agent` → `Nothing was started: this project already has 3 agents started by agents — "…", "…", "…". Archive one to free its place.`
  - a helper, asked which `agents__` tools it has, listed only finish_turn, manage_workflows, report_outcome, show_file and suggest_next_prompts. Its chat opens with "Started by “Agent tools test run”."
  - the Mac rows show the `person.2` mark on the three helpers and not on the lead.
- **Plan risk 2, answered for Claude**: the Claude adapter asks the person before *every* call to these tools (Yes / "Yes, and don't ask again for Start Agent commands" / No). The other runtimes were not tried.
- **Found live**: an agent does not know its own agent id; given none, it tried its runtime session id and got "no agent with that id". The daemon still refuses self-targeting, which was proved once the id was supplied. It might be worth putting the caller's own id in `list_my_agents`.
- **Briefing ceiling raised** from 1,500 characters / 5 lines to 1,700 / 6 (measured at 1,688 for Cursor, 1,608 Copilot, 1,532 Grok). The test says why.
- **Also changed, beyond the tasks**: `drainQueue` does not send queued prompts after a stop by an agent, just as after the person's stop. The transcript's ending line on Mac and phone reads "The agent that started it stopped it". Queued-prompt and pick-up notes say "it was stopped" or name the starter instead of "you".
- **Not done**: T037 (phone screenshot; the scratch root has no phone paired, and Remote only builds here). T038's commit: waiting for Alex to say to commit.
