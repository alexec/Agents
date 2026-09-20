---
description: "Task list for How It Actually Went"
---

# Tasks: How It Actually Went

**Input**: Design documents from `/specs/014-agent-outcomes/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included. The spec's central claims are exhaustiveness claims — every outcome lands in exactly one group, no ending is ever asked about twice, no agent is called Complete unless it said so — and none of them is demonstrable by looking at the app. `quickstart.md` names the suites and the cases.

**Organization**: Grouped by user story, in the priority order the spec sets. Each phase is shippable without the next.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)

## Path Conventions

- `Packages/AgentsKit/Sources/AgentsKitCore/` — everything both platforms hold. No `Process`, no PTY.
- `Packages/AgentsKit/Sources/AgentsKit/` — the Mac's half: the daemon, the ACP and MCP serving, the stores.
- `App/Sources/` — the SwiftUI Mac app. `Remote/Sources/` — the phone and iPad. `Daemon/Sources/` — `agentsd` and the MCP helper.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration,Live}/` — Swift Testing.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: The two names everything else refers to.

- [x] T001 Add `public static let reportOutcome = "report_outcome"` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/AppTool.swift`, beside `manageWorkflows`, with a doc comment in the file's voice ("And the fourth: how the work went, said at the end of it")
- [x] T002 [P] Add `public static let agentsReportOutcome = "agents/reportOutcome"` to the `Method` enum in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, beside `agentsManageWorkflows`
- [x] T003 [P] Create the empty test suites `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WorkOutcomeTests.swift`, `Integration/OutcomeReportTests.swift` and `Integration/UnreportedEndingTests.swift` with `@Suite` names matching the house style ("What an agent says about its work", "Reporting how it went", "An ending nobody accounted for")

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The vocabulary, the record it is kept on, and the grouping it feeds. Every user story reads these.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### The outcome and its wording

- [x] T004 Create `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkOutcome.swift` with `public enum WorkOutcome: String, Codable, Hashable, Sendable, CaseIterable` and exactly five cases — `done`, `nothingToDo`, `needsAnswer`, `partlyDone`, `stuck` — with raw values `"done"`, `"nothing_to_do"`, `"needs_answer"`, `"partly_done"`, `"stuck"`, and a type doc comment saying why the set is total over *what does the person do next* rather than over *what happened*
- [x] T005 Add `public var needsAPerson: Bool` to `WorkOutcome` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkOutcome.swift`: `true` for `needsAnswer`, `partlyDone`, `stuck`; `false` for `done`, `nothingToDo`. Exhaustive switch, no `default`. Name and comment it after `WorkflowRefusal.needsAPerson`, which answers the same question about a workflow
- [x] T006 Add `public var heading: String` to `WorkOutcome` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkOutcome.swift`: `done` → "Complete", `nothingToDo` → "Nothing to do", `needsAnswer` → "Waiting on your answer", `partlyDone` → "Partly done", `stuck` → "Stuck". Comment that this is what the app says when it has to speak for itself — the accessibility label, the tooltip, the transcript's label — and never what a row shows in place of the agent's message
- [x] T007 Add `public init?(wire: String)` to `WorkOutcome` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkOutcome.swift`, returning `nil` for any string that is not one of the five raw values, with a comment saying an unknown outcome is treated as a report that never arrived rather than rounded to the nearest known one (FR-027)
- [x] T008 Add `public struct WorkReport: Codable, Hashable, Sendable` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkOutcome.swift` with `outcome: WorkOutcome`, `message: String`, `at: Date`, plus `public static let messageLimit = 1_000`, and a failable `init?(outcome:message:at:)` that trims `message` of whitespace and newlines, returns `nil` when it is empty after trimming (FR-003), and cuts it to `messageLimit` characters rather than refusing when it is longer (Research R9, following `SuggestedPrompt.init(wire:)`)

### The record

- [x] T009 Add `public var report: WorkReport?` and `public var outcomeAsked: Bool` to `Agent` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`, with doc comments in the file's voice — the report is "what the agent said about how the work went, from the turn that just ended"; `outcomeAsked` is "one ask per silence, and the agent cannot write it"
- [x] T010 Add both fields to `Agent`'s `CodingKeys`, to `init(from:)` as `decodeIfPresent(...)` defaulting to `nil` and `false`, and to `encode(to:)`, in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`. Follow the comment convention of the 003/004/008/011 blocks already there: say that a record written before 014 opens as an agent that never reported and has never been asked
- [x] T011 Add `public var needsAPerson: Bool` and `public var endingIsUnaccountedFor: Bool` to the `Agent` extension in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift`, beside `group`, `currentPlan` and `currentStep`. `needsAPerson` is `state == .waitingOnUser || (state == .finished && report?.outcome.needsAPerson == true)`; `endingIsUnaccountedFor` is `state == .finished && endedReason == .endTurn && report == nil && outcomeAsked`
- [x] T012 Add a `report: WorkReport?` parameter, defaulted to `nil`, to `AgentGroup.init(for:wantsEyes:)` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift`, and add the one rule: `.finished` with `report?.outcome.needsAPerson == true` is `.needsAttention`. `.stopped` and `.archived` must ignore the report entirely (FR-018, FR-030). Extend the type's doc comment to say why, the way it already explains `wantsEyes`
- [x] T013 Change `Agent.group` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift` to pass `report: report`, so the daemon's project counts see it without any change to `DaemonCore+Projects.swift`

### The transcript

- [x] T014 Add `case workReported(WorkReport)` to `TranscriptEntry.Kind` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/TranscriptEntry.swift`
- [x] T015 Add `public enum PromptOrigin: String, Codable, Hashable, Sendable { case person, app }` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/TranscriptEntry.swift` and change `case userMessage(String, blocks: [ContentBlock] = [])` to `case userMessage(String, blocks: [ContentBlock] = [], from: PromptOrigin = .person)`, fixing every construction site the compiler names
- [x] T016 Add both to `Packages/AgentsKit/Sources/AgentsKitCore/Model/TranscriptEntry+Coding.swift`, both directions: `workReported` under its own key; `from` as a new key on the existing `userMessage` case, read as `.person` when absent so every record ever written stays correct. Keep the file's hand-written style and its reasons
- [x] T017 [P] Add `from: PromptOrigin = .person` to `QueuedPrompt` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/QueuedPrompt.swift` and to `DaemonAPI.PromptRequest` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, both `decodeIfPresent`-defaulted, so a remote built before 014 still sends prompts that are the person's

### The wire

- [x] T018 Add `public struct ReportOutcomeRequest: Codable, Sendable` to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift` with `token: String`, `outcome: String` (the wire spelling, validated at the daemon) and `message: String`, following `SuggestPromptsRequest`'s doc comment about why it is a token and not an agent id

**Checkpoint**: The vocabulary exists, every record opens, and `AgentGroup` is still total. Nothing observable yet.

---

## Phase 3: User Story 1 - The question that was hiding under a tick (Priority: P1) 🎯 MVP

**Goal**: An agent that ends its turn needing an answer is found from the agents list without opening it, showing its own question.

**Independent Test**: Report `needs_answer` at the end of a turn. Without opening the conversation, confirm the agent is under Needs attention, carries the colour, shows its question, and marks its project. Report `done` and confirm Complete with no colour.

### Tests for User Story 1

- [x] T019 [P] [US1] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WorkOutcomeTests.swift`, assert `needsAPerson` and `heading` are defined for every `WorkOutcome.allCases` with no duplicate headings, and that `WorkReport.init?` refuses an empty and a whitespace-only message and cuts a 2,000-character one to exactly 1,000
- [x] T020 [P] [US1] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentGroupTests.swift`, extend the existing exhaustive walk to every `(AgentState, WorkReport?)` pair, asserting each lands in exactly one group, that `.finished` plus a `needsAPerson` report is `.needsAttention`, and that `.stopped` and `.archived` are unmoved by any report
- [x] T021 [P] [US1] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AppServiceTests.swift`, assert `tools/list` offers four tools including `report_outcome`, that a call with an unknown outcome string and a call with an empty message each come back `isError: true` with the sentences from `contracts/agent-tool.md`, and that the name is matched on its suffix so `mcp__agents__report_outcome` reaches the same sink
- [x] T022 [US1] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/OutcomeReportTests.swift`, drive the daemon over its socket: report `needs_answer`, then assert the agent's group is `.needsAttention`, its `report.message` is the question, and the folder's `ProjectSummary.needsInput` is true
- [x] T023 [US1] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/OutcomeReportTests.swift`, assert reporting `done` leaves the agent in `.finished` with its message on it; that a second report in the same turn replaces the first (FR-005); that a prompt from the person clears the report (FR-006); and that archiving an agent which reported `needs_answer` takes it out of `.needsAttention` (FR-018)
- [x] T024 [US1] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/OutcomeReportTests.swift`, assert every refusal in `contracts/daemon-api.md`: a token whose session is over gives `noSuchAgent` (-32005); an empty message and an unknown outcome give `invalidParams`; and a report sent while a permission request for that agent is outstanding gives `invalidParams` with the "you have a question waiting" sentence (FR-008)

### Implementation for User Story 1

- [x] T025 [US1] Add `reportOutcomeToolName`, the `OutcomeSink` typealias (`@Sendable (String, String) async -> Outcome`), the sink property and its `init` parameter to `AppService` in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, defaulting to `.refused("This app cannot record an outcome.")` as the other two do
- [x] T026 [US1] Add `static let reportOutcomeTool: JSONValue` to `AppService` with the title, description and input schema set out verbatim in `contracts/agent-tool.md` — `outcome` a required string with `enum` exactly `["done", "nothing_to_do", "needs_answer", "partly_done", "stuck"]`, `message` a required string — and add it to the `tools/list` array
- [x] T027 [US1] Add the `tools/call` branch for `name.hasSuffix(Self.reportOutcomeToolName)` in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`: refuse with the contract's sentence when `outcome` is missing or not one of the five, and when `message` is missing or empty after trimming; otherwise pass both to the sink
- [x] T028 [US1] Add `public func reportOutcome(_ request: DaemonAPI.ReportOutcomeRequest) async throws -> String` to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift`, following `suggestPrompts` exactly: resolve the token to an agent or throw `noSuchAgent` with the contract's sentence; refuse with `invalidParams` when an elicitation or permission for that agent is outstanding; build the `WorkReport` (refusing an empty message); set `agent.report`; `await record(.workReported(report), for: agentID)` **before** `changed(agent)`; return the contract's success sentence, which differs by whether the outcome needs a person
- [x] T029 [US1] Add the `DaemonAPI.Method.agentsReportOutcome` case to the switch in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, returning `.success(["note": .string(try await reportOutcome(request))])` as the other three app tools do
- [x] T030 [US1] Add the fourth relay closure to the `AppService(...)` construction in `Daemon/Sources/main.swift`, calling `DaemonAPI.Method.agentsReportOutcome` with a `ReportOutcomeRequest` and the fallback `"Noted."`
- [x] T031 [US1] Clear `agent.report` and `agent.outcomeAsked` in `enqueue` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` when and only when the incoming `PromptRequest.from == .person` (FR-006, FR-023), and pass `from` through to the `QueuedPrompt` it builds
- [x] T032 [US1] Add `Briefing.outcome` to `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift` with the wording from `contracts/agent-tool.md`, insert it into `lines` after `escalation` and before `workflows`, and raise the character ceiling in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift` deliberately, in the manner that test already describes ("a ceiling to notice, not a rule")
- [x] T033 [US1] Teach `AgentsModel.group(of:)` in `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift` to pass `report: agent.report` alongside `wantsEyes`
- [x] T034 [US1] In `App/Sources/AgentList/AgentRow.swift`, insert `agent.report?.message` into `description` between `currentStep` and the `switch agent.state`, per the precedence list in `contracts/ui.md`, and give `StatusIcon` a `report` parameter resolving `needsAnswer` to `questionmark.circle.fill` in orange and `done` to `checkmark.circle.fill` in green
- [x] T035 [P] [US1] Make the same two changes in `Remote/Sources/Projects/AgentCard.swift`, reading the identical `heading` and `needsAPerson` from `WorkOutcome` so the phone and the window cannot drift (FR-017)
- [x] T036 [US1] Draw the `.workReported` entry at the end of the conversation in `App/Sources/Chat/Transcript.swift` — the outcome's `heading` above the agent's message, in the manner of the existing state-change lines rather than as a message from the agent (FR-015)
- [x] T037 [P] [US1] Draw the same entry the same way in `Remote/Sources/Chat/EntryView.swift`
- [x] T038 [US1] Suppress the `report_outcome` tool call in `TranscriptEntry.display` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/TranscriptDisplay.swift`, extending the existing `isSuggestingPrompts` suppression to cover it and keeping its comment's reasoning — what it did is drawn as the report, and a line saying it was called would be the same thing said twice

**Checkpoint**: An agent that needs an answer is findable from the list. The spec's central complaint is answered.

---

## Phase 4: User Story 2 - Four of five, and the fifth needs a decision (Priority: P1)

**Goal**: The other three outcomes read correctly — unfinished rather than finished, stuck rather than complete, nothing-to-do rather than work-done.

**Independent Test**: Run an agent over a task with a part it cannot finish. From the list alone, confirm it is not described as complete, is grouped with the things needing a person, and its line says what was left.

### Tests for User Story 2

- [x] T039 [P] [US2] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/OutcomeReportTests.swift`, assert `partly_done` and `stuck` each land in `.needsAttention` with the agent's own message, and that `nothing_to_do` lands in `.finished` reading as nothing needed rather than as work done
- [x] T040 [P] [US2] Add a test to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WorkOutcomeTests.swift` proving SC-001 directly: no `WorkOutcome` other than `.done` has the heading "Complete", and no combination of `(AgentState, EndedReason?, WorkReport?)` produces it

### Implementation for User Story 2

- [x] T041 [US2] Complete the symbol and tint table in `App/Sources/AgentList/AgentRow.swift` for the remaining three outcomes per `contracts/ui.md`: `nothingToDo` → `checkmark.circle` secondary, `partlyDone` → `circle.lefthalf.filled` orange, `stuck` → `exclamationmark.triangle.fill` orange
- [x] T042 [P] [US2] Complete the same table in `Remote/Sources/Projects/AgentCard.swift`
- [x] T043 [US2] Set every icon's `help` and `accessibilityLabel` from `WorkOutcome.heading` in both `App/Sources/AgentList/AgentRow.swift` and `Remote/Sources/Projects/AgentCard.swift`, so the words a screen reader hears come from the same place the ones on screen do
- [x] T044 [US2] Search `App/Sources/` and `Remote/Sources/` for the literal `"Complete"` and confirm every remaining occurrence is behind `WorkOutcome.done` or `AgentGroup.finished.title`, changing `App/Sources/Chat/Transcript.swift:582` and `Remote/Sources/Chat/EntryView.swift:247` if they describe a state rather than a group (FR-012)

**Checkpoint**: All five outcomes read correctly on both platforms.

---

## Phase 5: User Story 3 - The agent that said nothing (Priority: P2)

**Goal**: A silent ending is asked about once, and if it stays silent is labelled honestly rather than ticked.

**Independent Test**: End a turn without calling the tool. Confirm one question is asked, visibly the app's own; confirm a second silence is never asked about again; confirm the app never says Complete.

### Tests for User Story 3

- [x] T045 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/UnreportedEndingTests.swift`, end a turn with no report and assert exactly one prompt is enqueued, carrying `PromptOrigin.app`
- [x] T046 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/UnreportedEndingTests.swift`, let the asked turn end with no report either and assert no second prompt is ever enqueued — count them, which is SC-009 — and that the agent then reads as unaccounted for, stays in `.finished` rather than `.needsAttention`, and carries no colour (FR-019, FR-021)
- [x] T047 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/UnreportedEndingTests.swift`, assert the asked turn coming back *with* a report leaves the agent indistinguishable from one that reported first time, with nothing marking it as having been asked
- [x] T048 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/UnreportedEndingTests.swift`, assert no question is asked when a person's prompt is already queued (FR-023), when the agent is archived, and when the turn ended short — cancelled, `maxTokens`, `processDied` — and that `EndedReason.summary` is what is shown in those cases (FR-025)
- [x] T049 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/UnreportedEndingTests.swift`, assert a report followed by the process dying before the turn closes leaves both on the record: the `EndedReason` and the `WorkReport` (FR-031); and assert the asked turn's usage is recorded against the agent like any other turn (FR-024)
- [x] T050 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/LegacyRecordTests.swift`, assert an `Agent` record written before 014 opens with `report == nil` and `outcomeAsked == false`, that a 014 record read by a decoder without those keys keeps them in `unknownFields` and writes them back, that a `.workReported` entry read by a `Kind` decoder that does not know it comes through as `.unrecognised` rather than throwing, and that an unknown outcome string decodes to no report (FR-027)

### Implementation for User Story 3

- [x] T051 [US3] Add `askForOutcomeIfSilent(agentID:reason:)` to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` and call it from `finishTurn` after `releaseRuntime` and **before** `drainQueue`. The five conditions, all of which must hold, are in `contracts/daemon-api.md`: `reason == .endTurn`, `report == nil`, `outcomeAsked == false`, `queuedPrompts.isEmpty`, `state == .finished`. Set `outcomeAsked = true` **before** enqueuing, which is what makes the bound structural rather than conventional
- [x] T052 [US3] Enqueue the question through the ordinary `enqueue` path with `from: .app` and the wording from `contracts/agent-tool.md` ("That turn ended without a report…"), so it inherits starting the runtime, being recorded, and having its usage counted
- [x] T053 [US3] Add the unaccounted-for branch to `description` in `App/Sources/AgentList/AgentRow.swift` — "Finished without saying how it went" when `agent.endingIsUnaccountedFor` — with `questionmark.circle` in `.secondary`, placed after the report branch and before the `switch agent.state`
- [x] T054 [P] [US3] Add the same branch, wording and symbol to `Remote/Sources/Projects/AgentCard.swift`
- [x] T055 [US3] Draw a `userMessage` with `from: .app` in the transcript's secondary voice with a short attribution ("Agents asked"), never in the person's bubble, in `App/Sources/Chat/Transcript.swift` (FR-022)
- [x] T056 [P] [US3] Draw it the same way in `Remote/Sources/Chat/EntryView.swift`

**Checkpoint**: The app is honest about endings nobody vouched for, and the cost of asking is bounded by the number of endings.

---

## Phase 6: User Story 4 - The overnight run you read with coffee (Priority: P3)

**Goal**: A workflow's row says how its last run actually went, not merely that it happened.

**Independent Test**: Fire a workflow whose agent reports `stuck`. Confirm the project page's workflow row says so without opening the agent.

### Tests for User Story 4

- [x] T057 [P] [US4] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowFiringTests.swift`, fire a workflow, have its agent report `stuck`, and assert the workflow's row data carries that outcome alongside the existing "Ran" record and that the project's `needsInput` is true (FR-028, FR-029)

### Implementation for User Story 4

- [x] T058 [US4] In `App/Sources/Projects/WorkflowRow.swift`, look the agent up from `WorkflowOutcome.ran(agentID:at:)` — which already carries the id — and show its `report?.message` under the existing "Ran" line. Do not copy the report into the workflow record (Research R10)
- [x] T059 [US4] Give that row the colour it already gives a refusal that needs a person, when the run's agent reported an outcome with `needsAPerson`, in `App/Sources/Projects/WorkflowRow.swift`
- [x] T060 [P] [US4] Make the project page's equivalent show the same thing in `Remote/Sources/Projects/ProjectPageView.swift`, if that view draws workflow rows; otherwise note in the task's commit that the phone has no workflow row yet and this is Mac-only

**Checkpoint**: All four stories work independently.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [x] T061 Create `Packages/AgentsKit/Tests/AgentsKitTests/Live/OutcomeReportLiveTests.swift` modelled on `Live/SuggestedPromptLiveTests.swift`: against each signed-in runtime, give a task containing an unanswerable question and assert the turn ends with a `needs_answer` report rather than the question buried in a reply. This is the only check that can fail for reasons no unit test sees
- [ ] T062 Record the per-runtime adoption rate from T061 in `specs/014-agent-outcomes/research.md` as a new section, against SC-007's 90% target — a runtime that will not call the tool is a finding to write down, not a failure of the design. **Blocked on a person**: T061's suite is written but needs a signed-in runtime and spends real money, so it has not been run. `research.md` R11 holds the place and the command.
- [x] T063 [P] Add `.workReported` and the `userMessage` origin to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ReplayTests.swift` so a transcript round-trips through the store unchanged
- [x] T064 [P] Update `Remote/Sources/Preview/Canned.swift` and `FakeDaemon.swift` with agents carrying each of the five outcomes and one unaccounted-for ending, so the previews show what the feature actually looks like
- [x] T065 Re-read `Briefing.text` in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift` end to end after T032 and cut anything the four lines now say twice — the file's own rule is that an agent told six things at once follows the first two, and this feature adds the fourth thing
- [x] T066 Run `swift test --package-path Packages/AgentsKit` and `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build`, and fix what breaks
- [ ] T067 Walk `specs/014-agent-outcomes/quickstart.md` checks 1 through 6 by hand, including check 5 in the running app, and correct the quickstart where the built thing differs from what it predicted. **Checks 1, 2, 3, 4 and 6 done and the quickstart corrected against them. Check 5 is blocked on a person**: it needs the app in front of somebody with a signed-in runtime.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup. **Blocks every user story** — all four read `WorkOutcome`, `Agent.report` and `AgentGroup`.
- **US1 (Phase 3)**: Depends on Foundational. Nothing else.
- **US2 (Phase 4)**: Depends on US1, and only for its view sites — T041 to T044 extend switches T034 and T035 create. Not independent of US1 in the way US3 and US4 are, because US1 is where the tool and the pipeline get built.
- **US3 (Phase 5)**: Depends on Foundational and on T031 (the `from == .person` clearing rule). Independent of US1 and US2 — the ask-once path and the unaccounted-for label can be built and tested with no outcome ever reported.
- **US4 (Phase 6)**: Depends on US1 for the report to exist. Independent of US2 and US3.
- **Polish (Phase 7)**: Depends on everything wanted.

### Within Each User Story

- Tests are written first and must fail before implementation.
- Model before daemon, daemon before helper, helper before views.
- The Mac view and the remote view are always a `[P]` pair, and they must take their wording from the same `WorkOutcome` member — that is what FR-017 is, and it is the easiest thing in this feature to get wrong.

### Parallel Opportunities

- T002 and T003 alongside T001.
- T017 alongside T014 to T016.
- All of T019, T020, T021 together — three files, no shared state.
- T035, T037, T042, T054, T056, T060: every remote view change is parallel with its Mac twin.
- All six US3 test tasks (T045 to T050) together.
- T063 and T064 alongside each other in Polish.

---

## Parallel Example: User Story 1

```bash
# The three unit suites, written together before any implementation:
Task: "Unit/WorkOutcomeTests.swift — the table and the message limits"
Task: "Unit/AgentGroupTests.swift — every (state, report) pair"
Task: "Unit/AppServiceTests.swift — four tools, and the refusals read well"

# Later, the two view twins together:
Task: "App/Sources/AgentList/AgentRow.swift — description and StatusIcon"
Task: "Remote/Sources/Projects/AgentCard.swift — the same two, same words"
```

---

## Implementation Strategy

### MVP (User Story 1 only)

Phases 1, 2 and 3. That ships the tool, the report, the grouping and the two P1 outcomes that matter most — `done` and `needs_answer`. The app stops saying Complete about an agent with a question in it, which is the whole of the spec's complaint. **Stop here and use it for a week** before building the rest: the live adoption rate from T061 is the thing that decides whether Phase 5's automatic question is carrying its weight, and a week of real turns answers that better than any argument.

### Incremental delivery

1. Setup + Foundational → the vocabulary exists, nothing visible.
2. **+ US1 → MVP.** The question under the tick is gone.
3. + US2 → the other three outcomes read correctly. Small, because the table is total.
4. + US3 → silent endings are asked about once and labelled honestly. This is the phase with a running cost, and the only one worth reconsidering in the light of step 2's adoption rate.
5. + US4 → unattended runs say how they went.

### Notes

- `[P]` tasks are different files with no dependency between them.
- Commit after each task or logical group.
- The two things easiest to get wrong, both of which a test catches and a reading does not: wording that ends up in a view instead of on `WorkOutcome` (FR-017), and an ask-once bound enforced by convention instead of by setting the flag before the enqueue (FR-021).
