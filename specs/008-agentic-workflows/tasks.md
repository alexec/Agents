---
description: "Task list for Agentic Workflows"
---

# Tasks: Agentic Workflows

**Input**: Design documents from `/specs/008-agentic-workflows/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md), [wireframe.md](./wireframe.md)

**Tests**: Included. `quickstart.md` names the test files and cases, and the plan's source tree lists them — this feature's safety rules all work by refusing to act, so they are only demonstrable by test.

**Organization**: Grouped by user story, in the priority order the spec sets. Each phase is shippable without the next.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)

## Path Conventions

This is an existing Swift package plus a macOS app. Two source roots matter, and the line between them is the one `Package.swift` already draws:

- `Packages/AgentsKit/Sources/AgentsKitCore/` — everything both platforms can hold. No `Process`, no `posix_spawn`, no PTY.
- `Packages/AgentsKit/Sources/AgentsKit/` — the Mac's half: file system, FSEvents, the daemon, the stores.
- `App/Sources/` — the SwiftUI app.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration}/` — Swift Testing.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: The few places that have to exist before any workflow code compiles.

- [X] T001 Create the source directory `Packages/AgentsKit/Sources/AgentsKit/Workflows/` for the parser, folder scan, schedule and store
- [X] T002 Add `public var workflows: URL { root.appendingPathComponent("workflows.json") }` to `Packages/AgentsKit/Sources/AgentsKit/Store/StoreLocations.swift`, beside the existing `projects` property and following its comment style
- [X] T003 [P] Add `public static let manageWorkflows = "manage_workflows"` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/AppTool.swift`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The model, the parser and the pure decision rules. Every user story needs all of it.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### The model

- [X] T004 [P] Create `WorkflowTrigger` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowTrigger.swift` with cases `schedule(WorkflowSchedule)`, `agentFinished`, `agentAskedPermission`, `agentAskedForm`, `agentStopped`, `workflowCompleted(id: String?)` where nil means any workflow in this project, and `unrecognised(name: String, keys: [String: JSONValue])`. Manual running is deliberately NOT a trigger — FR-012 makes Run now available on every workflow whatever its triggers
- [X] T005 [P] Create `WorkflowSchedule` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowSchedule.swift` with `minutes: Set<Int>` ("Subset of `{0, 30}`. The half-hour granularity, enforced at parse"), `hours: ClosedRange<Int>` (0–23, defaults to all day) and `days: Set<Weekday>` (defaults to every day). Add `nextDue(after:calendar:) -> Date?` as a pure function of schedule, date and calendar — never precomputed, so a time-zone move or a DST boundary needs no rewrite
- [X] T006 [P] Create `WorkflowMode` (`new`, `standing`, `triggering`) in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowMode.swift`. An unknown value must surface as a `problem` of kind `unsupportedMode`, never as a decode failure
- [X] T007 Create `Workflow` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Workflow.swift` with `id: String` (the file name without extension — identity per FR-004), `folder: URL` (standardized by `Project.standardize`), `name: String`, `triggers: [WorkflowTrigger]`, `mode: WorkflowMode` (defaults to `new`), `prompt: String`, `problem: WorkflowProblem?`, and `unknownFields: [String: JSONValue]` following the `Agent.unknownFields` precedent. Depends on T004–T006
- [X] T008 Add the derived `summary: String` to `Workflow` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Workflow.swift` — the trigger and mode in plain language, e.g. "Every weekday at 9:00am, in a new agent". One renderer only: the project-page row and the write confirmation both read it, so the thing you approve and the thing you later see cannot drift
- [X] T009 Add the derived `canFire: Bool` to `Workflow` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Workflow.swift` — false when `problem` is set or when no trigger is supported
- [X] T010 [P] Create `WorkflowRefusal` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowRefusal.swift` as a closed enum with exactly the nine cases FR-026 requires: `chainTooDeep(depth: Int)`, `runInFlight`, `paused`, `unreadable`, `triggerNotSupported(name: String)`, `agentUnavailable`, `noTriggeringAgent`, `missedWhileClosed`, `folderGone`. Each carries a plain-language `message` in the voice `showFile`'s refusals use
- [X] T011 Create `WorkflowOutcome` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowOutcome.swift` with `ran(agentID: UUID, at: Date)` and `refused(WorkflowRefusal, at: Date, repeats: Int)`. Depends on T010
- [X] T012 [P] Create `WorkflowRun` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowRun.swift` with `id`, `workflowID`, `folder`, `trigger`, `triggeringAgentID: UUID?`, `depth: Int`, `agentID: UUID?`, `startedAt`. It lives only while in flight — this is not a history
- [X] T013 Create `WorkflowSummary` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Workflow.swift` with `workflow`, `isPaused`, `nextFireAt: Date?`, `lastOutcome: WorkflowOutcome?`, `isRunning: Bool`, and `id: String` composed as `workflow.folder.path + "/" + workflow.id` so one window showing two projects cannot collide. Resolved daemon-side, for the reason `ProjectSummary` is
- [X] T014 Add `startedByWorkflow: String?` and `startedByRun: UUID?` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`. Both optional, so older records decode with no migration

### The parser

- [X] T015 [P] Write `Unit/WorkflowFileTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/` covering the sample from `contracts/workflow-file.md`: round-trip; unknown top-level keys survive a rewrite; missing `on:` is unreadable; empty body is unreadable; `at: [":15"]` is rejected; an unknown trigger name yields `unrecognised` and NOT a failure; an unknown `agent:` value yields `unsupportedMode` and NOT a failure. Write these first and confirm they fail
- [X] T016 Create `WorkflowFile` in `Packages/AgentsKit/Sources/AgentsKit/Workflows/WorkflowFile.swift` — parse one file to a `Workflow` and write one back. Reuse `FrontMatter.strip(_:)` from `AgentsKitCore` rather than writing a second, subtly different positional rule. The line that matters: a file we cannot read is broken, and a file we can read but cannot act on yet is a file from the future — they get different `problem` values and different words. Makes T015 pass
- [X] T017 Create `WorkflowFolder` in `Packages/AgentsKit/Sources/AgentsKit/Workflows/WorkflowFolder.swift` — scan a project's `.agents/workflows` for `*.md` and return `[Workflow]`, including unreadable ones so they can be listed with their problem (FR-006)

### The state, and the rules

- [X] T018 Create `WorkflowStore` in `Packages/AgentsKit/Sources/AgentsKit/Workflows/WorkflowStore.swift` — load and save one JSON file at `locations.workflows`, following `ProjectStore` exactly. Holds per-workflow `isPaused`, `standingAgentID`, `lastFiredAt`, `lastOutcome`, plus file-level `pausedProjects: Set<URL>` and `lastTickAt: Date?`. Nothing here is ever written back to the repository (FR-024)
- [X] T019 [P] Write `Unit/WorkflowOutcomeTests.swift` as a table covering every refusal rule and the repeat-collapsing rule: same reason twice increments `repeats`; a different reason resets it to 1; a run replaces the value entirely (FR-030)
- [X] T020 Add the pure decision function `Workflow.mayFire(state:projectPaused:depth:now:) -> WorkflowRefusal?` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowOutcome.swift`. Takes the workflow, its state, the project's pause set, the proposed depth and the current date; no file system, no actor, no clock of its own. If a refusal case needs a live daemon to test, the decision has leaked out of this function — move it back. Makes T019 pass
- [X] T021 [P] Write `Unit/WorkflowScheduleTests.swift` covering `nextDue(after:)` across a day boundary, a `days:` set, a DST spring-forward, a DST fall-back, a time-zone change between two calls, and the empty-set cases

### The wire

- [X] T022 Add to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`: methods `workflows/list`, `workflows/run`, `workflows/pause`, `workflows/pauseProject`, `workflows/confirm`, `workflows/pendingConfirmations`; notifications `workflow/changed`, `workflow/removed`, `workflow/confirmation`; the `WorkflowConfirmation` type; and failure codes `noSuchWorkflow = -32014`, `workflowUnreadable = -32015`, `notInWorkflowFolder = -32016`, `confirmationTimedOut = -32017`. Start at -32014 because -32013 is the highest in use. Do NOT reuse -32010: `shellWillNotStart` and `notConfirmed` already collide on it, which is a pre-existing bug and out of scope here

**Checkpoint**: The model parses, persists and decides. No workflow fires yet.

---

## Phase 3: User Story 1 — A workflow runs on a schedule (Priority: P1) 🎯 MVP

**Goal**: A Markdown file in `.agents/workflows/` is listed on the project page with its trigger in plain words and its next fire time, and an agent starts with its prompt at that time. Run now and pause work.

**Independent Test**: Write one workflow file into a project with a schedule a few minutes out. It appears on the project page within five seconds without a restart, and an agent starts at that time with that prompt.

### Tests for User Story 1

- [X] T023 [P] [US1] Write `Integration/WorkflowFiringTests.swift` — writing a file into a watched project lists it; a due schedule starts an agent through the injectable fake `SessionLauncher`; `standing` resumes the same agent on a second fire; `standing` with a deleted agent starts and adopts a fresh one (FR-016). Drive the clock by injecting `Date` into the tick, never by sleeping
- [X] T024 [P] [US1] Write the first cases of `Integration/WorkflowRefusalTests.swift` — the refusals reachable without chaining: `runInFlight` (fire twice without letting the first finish), `paused` (workflow and project, asserted against Run now too), `unreadable`, `triggerNotSupported`, `noTriggeringAgent`, `folderGone`

### Discovery and scheduling

- [X] T025 [US1] Create `DaemonCore+Workflows.swift` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/` and hold the workflow state on `DaemonCore`: loaded workflows by project, in-flight runs, the `WorkflowStore`, and the folder watchers
- [X] T026 [US1] Add folder watching in `DaemonCore+Workflows.swift` — one `FolderWatch` per non-archived project rooted at the project folder, its callback filtered to paths under `.agents/` and debounced by 250ms, rescanning only that project's `.agents/workflows`. Watch the project root rather than the leaf: FSEvents on a path that does not exist yet reports nothing, so watching the leaf would miss the first workflow anyone ever adds — the exact moment the feature has to work. Also rescan on project change, on tool write and at daemon start
- [X] T027 [US1] Add the scheduler tick in `DaemonCore+Workflows.swift` — a single `Task` ticking every 15 seconds that reads wall-clock `Date()` and asks each scheduled workflow whether a due time falls between the last tick and now. Never a sleep-until-due: that is a bet on whether the clock advances across a lid close, and it is wrong the moment the machine changes time zone. 15 seconds leaves margin against SC-008's one minute
- [X] T028 [US1] Persist `lastTickAt` on every tick via `Packages/AgentsKit/Sources/AgentsKit/Workflows/WorkflowStore.swift` — the heartbeat that later makes `missedWhileClosed` decidable

### Firing

- [X] T029 [US1] Implement `fire(_:trigger:triggeringAgentID:depth:)` in `DaemonCore+Workflows.swift` — call the pure `mayFire` from T020, and on refusal persist the outcome then broadcast, in that order, the rule `record(_:for:)` already follows
- [X] T030 [US1] Implement agent resolution for `new` and `standing` in `DaemonCore+Workflows.swift`, reusing `start(_:)` and `prompt(_:)` from `DaemonCore+Commands.swift` rather than opening sessions directly. Set `startedByWorkflow` and `startedByRun` on the agent (FR-019, FR-021)
- [X] T031 [US1] Mark the run finished and record `WorkflowOutcome.ran` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift` when the fired agent's turn ends, hooking the existing `finishTurn` path in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` so the in-flight rule releases correctly

### The daemon API

- [X] T032 [US1] Implement `workflows/list`, `workflows/run` and `workflows/pause` in `DaemonCore+Workflows.swift`. `workflows/run` is not a bypass: it sets depth 0 and ignores the schedule, but still obeys the in-flight and paused rules and returns a summary whose `lastOutcome` is the refusal — someone is watching when they tap it
- [X] T033 [US1] Implement `workflows/pauseProject` in `DaemonCore+Workflows.swift`, writing only to `workflows.json`
- [X] T034 [US1] Route the workflow methods in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift` alongside the existing `projects/*` routes
- [X] T035 [US1] Broadcast `workflow/changed` and `workflow/removed` from every path in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift` that alters a workflow, carrying the whole resolved `WorkflowSummary` rather than a delta — so two windows cannot disagree and a window that missed one is corrected by the next

### The project page

- [X] T036 [P] [US1] Hold workflows per project in `App/Sources/AppModel.swift` and handle `workflow/changed`, `workflow/removed` and `workflow/confirmation`
- [X] T037 [US1] Create `App/Sources/Projects/WorkflowRow.swift` per `wireframe.md` — `StatusIcon`-style symbol, then three lines matching `AgentRow`'s existing idiom: `.headline` name; `.callout` `.secondary` saying what it is (the trigger summary, FR-027); `.caption` `.tertiary` saying what is happening (next fire, last outcome, FR-028). Trailing glass buttons for Run now and pause. The card is deliberately NOT a button — an `AgentCard` is one because it opens a conversation, and a workflow has no conversation to open
- [X] T038 [US1] Add the link from the third line to the agent that run started or resumed, in `App/Sources/Projects/WorkflowRow.swift` (FR-029)
- [X] T039 [US1] Create `App/Sources/Projects/WorkflowsSection.swift` — the `GroupHeading`, the rows, the pause-all control and the empty state. The empty state names where the files live, because that is the one fact nobody can guess
- [X] T040 [US1] Place the section in `App/Sources/Projects/ProjectAgentsView.swift` below the agent groups and above `archivedSection`, inside the same 144pt gutter and the same `GlassEffectContainer`
- [X] T041 [US1] Run `xcodegen generate` to regenerate `Agents.xcodeproj` from `project.yml` so the new `App/Sources/Projects/` files are picked up, then build

**Checkpoint**: User Story 1 is fully functional. A hand-written workflow runs on a schedule and you can see it, run it and stop it.

---

## Phase 4: User Story 2 — A workflow reacts to what an agent just did (Priority: P2)

**Goal**: Workflows fire on agent lifecycle events, and `triggering` mode sends the prompt back into the agent whose event fired it.

**Independent Test**: Write a workflow triggered on an agent finishing. Start an agent by hand, let it finish, and confirm the workflow's agent starts with the triggering agent's identity available to it.

### Tests for User Story 2

- [X] T042 [P] [US2] Extend `Integration/WorkflowFiringTests.swift` — `move(agentID, on: .turnEnded(.endTurn))` fires `agent-finished`; a permission request fires `agent-asked-permission` **while that request is still pending** (assert `pendingPermissionRequests()` is non-empty at fire time); an elicitation fires `agent-asked-form`; both `.stoppedByUser` and `.processDied` fire `agent-stopped`; workflow A completing fires workflow B; a workflow with two triggers that both match one event runs **once** (FR-011)
- [X] T043 [P] [US2] Extend `Integration/WorkflowRefusalTests.swift` with `agentUnavailable` — `triggering` mode where the agent has been archived

### Implementation

- [X] T044 [US2] Hook `DaemonCore.move(_:on:endedReason:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`, after `changed(agent)` and `record(...)`. It is the single funnel every state transition passes through and it returns nil for transitions that must not happen, so the hook cannot fire on a non-event
- [X] T045 [US2] Hook `.permissionRequested` in `DaemonCore.handle(_:agentID:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` after the pending request is held and broadcast, so the workflow fires while the request is still outstanding
- [X] T046 [US2] Hook `.elicitationRequested` in `DaemonCore.handle(_:agentID:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`, the same way
- [X] T047 [US2] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`, compute the depth for a lifecycle fire by reading the triggering agent's `startedByRun`, defaulting to 0 when there is none (FR-021)
- [X] T048 [US2] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`, start the run on a detached task rather than awaiting inside the hook — `DaemonCore` is an actor and the hook is called from inside it, so firing must not await anything that could call back into `move`. Follow the shape `beginTurn` already uses for `turnTasks`
- [X] T049 [US2] Implement `triggering` mode agent resolution in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`: resume the triggering agent, and when it can no longer take a prompt refuse with `agentUnavailable` rather than substituting (FR-017). A schedule or manual fire in `triggering` mode refuses with `noTriggeringAgent` (FR-018)
- [X] T050 [US2] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`, supply the triggering agent's identity and what it did to the run alongside the prompt, so a `new` agent has something to act on without a placeholder syntax (FR-020)
- [X] T051 [US2] Fire `workflowCompleted` triggers in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift` when a run finishes, at depth + 1 (FR-010)
- [X] T052 [US2] Ensure one fire per firing event in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift` however many of a workflow's triggers match it (FR-011)

**Checkpoint**: User Stories 1 and 2 both work independently.

---

## Phase 5: User Story 3 — You can see that a workflow did not run (Priority: P3)

**Goal**: Every fire that produces no agent leaves a stated reason on the project page. Chains stop on their own and say so.

**Independent Test**: Write a workflow whose prompt takes a long time, on a schedule tight enough that a second fire falls due while the first is still running. The project page says the second fire was refused because a run was still in flight, and no second agent started.

### Tests for User Story 3

- [X] T053 [P] [US3] Complete `Integration/WorkflowRefusalTests.swift` with `chainTooDeep` (chain past the limit and assert the **run count**, not just the final refusal) and `missedWhileClosed` (advance `lastTickAt` backwards past a due time). Assert on the recorded outcome, never on the absence of an agent — this story is entirely about things not happening
- [X] T054 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowRefusalTests.swift`, add an explicit test that walks every trigger and every refusal and asserts the count of fires equals runs plus refusals. This is SC-003, the criterion most likely to be quietly wrong

### Implementation

- [X] T055 [US3] Enforce the chain-depth limit in `DaemonCore+Workflows.swift`, "default to three". Deliberately not configurable per workflow or per project: a runaway workflow able to raise its own limit is not stopped
- [X] T056 [US3] Implement `missedWhileClosed` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift` — on a tick, a due time in the past that is after the workflow's `lastFiredAt` but falls inside a gap where `now - lastTickAt` exceeds a few ticks is recorded as missed and NOT fired (FR-014). Opening the app after a weekend must not start a queue of agents nobody asked for
- [X] T057 [US3] Implement repeat collapsing in `Packages/AgentsKit/Sources/AgentsKit/Workflows/WorkflowStore.swift` — increment `repeats` when the incoming refusal has the same reason as the stored one; any different reason, or a run, replaces the value and resets it to 1 (FR-030)
- [X] T058 [US3] Render every refusal on the row in `App/Sources/Projects/WorkflowRow.swift`, with the count when repeated: "Did not run — a run is still going", "Missed 14 times — the app was closed"
- [X] T059 [US3] Apply the colour rule in `WorkflowRow.swift`: grey for refusals that resolve themselves (paused, run in flight, missed while closed) and colour only for those needing a person (chain limit reached, file unreadable, folder gone). The app's existing rule is that "the only colour in this app means something needs a person" — colouring every refusal would shout about a workflow skipping one fire and spend the signal reserved for agents waiting on an answer
- [X] T060 [US3] Show the unreadable and not-yet-supported states distinctly on the row per `wireframe.md`: a file we cannot read states the problem and where; a file from the future says which trigger this version does not know about, and still offers Run now (FR-012, FR-013)

**Checkpoint**: Nothing fails quietly. All three stories work independently.

---

## Phase 6: User Story 4 — An agent sets up its own workflows (Priority: P4)

**Goal**: An agent creates, changes and removes its project's workflows through a tool, with writes gated behind a confirmation the daemon raises itself.

**Independent Test**: Ask an agent to create a workflow. A confirmation describes the trigger and the mode in plain words, and approving it makes the workflow appear on the project page with no further step.

### Tests for User Story 4

- [ ] T061 [P] [US4] Write `Integration/WorkflowToolTests.swift` — `list` and `read` return without raising a confirmation; `write` raises one, and `allow: false` writes nothing while `allow: true` writes and lists; a path outside `.agents/workflows` is refused; unparseable front matter is refused **before** any confirmation is raised; `connectionCount == 0` refuses and writes nothing; an unanswered confirmation times out and writes nothing
- [ ] T062 [P] [US4] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowToolTests.swift`, add the regression guard for narrowing auto-allow: `autoAllowed(_:)` returns nil for a `manage_workflows` tool call and still returns an option for `suggest_next_prompts` and `show_file`

### Implementation

- [ ] T063 [US4] Add `isAutoAllowable` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/PermissionRequest.swift`, true only for `isSuggestingPrompts` and `isShowingFile`
- [ ] T064 [US4] Narrow `autoAllowed(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift` from `request.toolCall.isTheApps` to `request.toolCall.isAutoAllowable`. This makes the permission surface stricter, not looser
- [ ] T065 [US4] Advertise and route `manage_workflows` in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift` per `contracts/mcp-tool.md`. Do NOT add it to `askForSuggestions` or any other standing instruction — telling every agent it can schedule things would invite exactly the behaviour the chain-depth limit exists to contain
- [ ] T066 [US4] Implement the `list` and `read` actions in `DaemonCore+AppTools.swift`, resolving the project from the token-bound agent's `cwd` and raising no confirmation (FR-034)
- [ ] T067 [US4] Hold pending confirmations on `DaemonCore` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` as a third structure beside `pendingPermissions` and `elicitations`. Do not reuse `PermissionRequest`: that is a thing a runtime asked and is answered back into an ACP session, whereas this originates with the daemon and is answered by doing or not doing a file write
- [ ] T068 [US4] Implement `write` and `remove` in `DaemonCore+AppTools.swift` — validate the front matter first, then raise the confirmation and block on it. Validating first matters: raising a confirmation for a file that could never fire wastes the one moment of the reader's attention this feature gets
- [ ] T069 [US4] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift`, refuse a write when `connectionCount == 0` with "No window is open, so there was nobody to ask. Nothing was written.", following the precedent `showFile` sets
- [ ] T070 [US4] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift`, time a confirmation out after two minutes, refusing and writing nothing, so a runtime is not left hanging on somebody who walked away
- [ ] T071 [US4] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift`, scope every action to the calling agent's `.agents/workflows` via `FolderScope`, refusing anything outside it (FR-037)
- [ ] T072 [US4] Implement `workflows/confirm` and `workflows/pendingConfirmations` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift` and route them in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, broadcasting `workflow/confirmation`, mirroring `permissions/answer` and `permissions/pending`
- [ ] T073 [US4] Create the confirmation UI per `wireframe.md`, shown wherever permission requests are shown today. It leads with the trigger in words from the **same renderer as the row** (T008), shows the prompt in full rather than behind a disclosure, and has **no "always allow"** — an agent with blanket approval to write workflows could write a workflow that writes workflows

**Checkpoint**: All four user stories are independently functional.

---

## Phase 6b: Watcher lifetime (found during implementation)

Not in the original plan. Adoption happened only at daemon startup, so a project added
during a session never got a watcher and its workflows stayed invisible until a restart
— the case where somebody trying the feature writes their first workflow.

- [X] T080 Add `adoptWorkflows(in:)` and `forgetWorkflows(in:)` to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`, called from `addProject`, `unarchiveProject`, `archiveProject` and `allWorkflows(in:)`
- [X] T081 Adopt on the read path rather than on agent state changes — adoption reads a directory, reads a file and opens an FSEvents stream, and doing that per state change made starting an agent slow enough to miss test deadlines
- [X] T082 Stop watchers rather than dropping them in `stopWatchingWorkflows` and `stopWatchingAllWorkflows`: `FolderWatch` hands itself to FSEvents with `passRetained`, so letting go of the reference leaks the stream
- [X] T083 Add `Integration/WorkflowFiringTests.swift` suite "Taking a project's workflows on" — six cases covering add, first use, archive, unarchive, idempotence, and the guard that agent starts touch no file system

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T074 [P] Confirm `Unit/LegacyRecordTests.swift` still passes unchanged — `Agent` gained two optional fields and older records must decode with no migration
- [ ] T075 [P] Check the SC-009 scale case against `App/Sources/Projects/WorkflowsSection.swift`: twenty workflows in one project list and scroll as smoothly as the agent list beneath them
- [ ] T076 Run the full `specs/008-agentic-workflows/quickstart.md` by hand, including the by-hand steps for all four stories
- [ ] T077 Confirm nothing was written to the repository (no writes under any project's `.agents/workflows` beyond those deliberately created, and none to `specs/`): after the full suite against a scratch project, `git status` in it is clean apart from workflow files deliberately created
- [ ] T078 [P] Update `README.md` to mention workflows and where their files live
- [ ] T079 Run `swift test --package-path Packages/AgentsKit` and `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build` clean

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories
- **US1 (Phase 3)**: Depends on Foundational
- **US2 (Phase 4)**: Depends on Foundational. Independently testable, but only meaningful once something can fire, so in practice follows US1
- **US3 (Phase 5)**: Depends on Foundational. The refusals it completes — chain depth, missed fires — are only reachable once US2 exists. The in-flight, paused and unreadable refusals are built with US1 in T024 rather than deferred; treat this phase as *the rest of* the refusal surface plus its presentation
- **US4 (Phase 6)**: Depends on Foundational and on T008's summary renderer. Otherwise independent of US1–US3
- **Polish (Phase 7)**: Depends on the stories you intend to ship

### Within Each User Story

- Tests are written first and confirmed failing
- Model before parser, parser before store, store before the daemon
- The pure decision function before anything that calls it
- Daemon before UI

### Parallel Opportunities

- T004, T005, T006 — three model files, no shared edits
- T010, T012 — two more model files
- T015, T019, T021 — three test files, all written before their implementations
- T023, T024 — two integration test files
- T042, T043 — extend two different test files
- T053, T054 — different test concerns
- T061, T062 — tool tests and the auto-allow guard
- T074, T075, T078 — independent polish

Note that T007–T009 and T013 all touch `Workflow.swift` and must be sequential; likewise T044–T046 all edit `DaemonCore.swift`.

---

## Parallel Example: Foundational

```bash
# The three independent model files:
Task: "Create WorkflowTrigger in AgentsKitCore/Model/WorkflowTrigger.swift"
Task: "Create WorkflowSchedule in AgentsKitCore/Model/WorkflowSchedule.swift"
Task: "Create WorkflowMode in AgentsKitCore/Model/WorkflowMode.swift"

# The three test files, all written before their implementations:
Task: "Write Unit/WorkflowFileTests.swift"
Task: "Write Unit/WorkflowOutcomeTests.swift"
Task: "Write Unit/WorkflowScheduleTests.swift"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1: Setup — T001–T003
2. Phase 2: Foundational — T004–T022 (**blocks everything**)
3. Phase 3: User Story 1 — T023–T041
4. **STOP and VALIDATE**: write a workflow file by hand, watch it appear, run it, pause it, let it fire on schedule
5. Ship

### Incremental Delivery

1. Setup + Foundational → the model parses, persists and decides
2. + US1 → a workflow runs on a schedule and you can see and stop it (**MVP**)
3. + US2 → workflows react to agents
4. + US3 → nothing fails quietly
5. + US4 → agents set up their own workflows

### A note on sequencing

Consider building T037–T040 (the project page section) against fake data early, before the daemon work in T025–T035. The three layout decisions flagged at the end of `wireframe.md` — where the section sits, buttons versus a context menu, and the colour rule — are cheaper to settle by running it than by arguing about it, and every one of them is independent of whether anything actually fires.

---

## Notes

- `[P]` = different files, no dependencies
- Each user story is independently completable and testable
- Verify tests fail before implementing
- Commit after each task or logical group
- Persist before broadcasting, everywhere — the rule `record(_:for:)` already follows
- Avoid: adding a workflow trigger that fires on the app's own writes; making the chain-depth limit configurable; writing workflow state back into the repository
