---
description: "Task list for One Call to End a Turn"
---

# Tasks: One Call to End a Turn

**Input**: Design documents from `/specs/023-end-of-turn-tool/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included. The spec's claims are about what a call leaves behind — both halves or neither, the same state by any name, a briefing one line shorter — and none of them is visible in the app. `quickstart.md` names the suites and the cases. The live suite is the only thing that can answer SC-004 and is run last.

**Organization**: Grouped by user story, in the priority order the spec sets. US1 is the tool; US2 is the promise to conversations already under way; US3 is the briefing and the measurement.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US3)

## Path Conventions

- `Packages/AgentsKit/Sources/AgentsKitCore/` — everything both platforms hold.
- `Packages/AgentsKit/Sources/AgentsKit/` — the daemon, the ACP and MCP serving.
- `Daemon/Sources/` — `agentsd` and the MCP helper it runs as.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration,Live}/` — Swift Testing.

Three lanes share this tree. If the package will not build, `git worktree add --detach /tmp/023 HEAD`, copy the feature's files in, and run the suite there.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: The names everything else refers to, and the suites the stories fill.

- [x] T001 Add `public static let finishTurn = "finish_turn"` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/AppTool.swift`, first in the enum, with a doc comment in the file's voice ("The one call that ends a turn: how it went, and what to ask next"). Re-comment `suggestPrompts` and `reportOutcome` beneath it as the older names for its two halves, kept since 2026-09-23 so a conversation briefed with them still finds what it was told, to be removed together once no such conversation could be resumed (Research R5)
- [x] T002 [P] Add `public static let agentsFinishTurn = "agents/finishTurn"` to the `Method` enum in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, beside `agentsReportOutcome`
- [x] T003 [P] Create the empty suites `Packages/AgentsKit/Tests/AgentsKitTests/Integration/FinishTurnTests.swift` (`@Suite("Ending a turn in one call", .timeLimit(.minutes(1)))`) and `Packages/AgentsKit/Tests/AgentsKitTests/Live/FinishTurnLiveTests.swift` (`@Suite("Live: whether a runtime ends its turns", .serialized, ...)` with the same `.enabled(if:)` and `.timeLimit` as `OutcomeReportLiveTests`), each with the `temporary()`, `core(_:locations:)`, `midTurn()`, `mintedToken(_:)` and `settle(_:_:)` helpers copied from `Integration/OutcomeReportTests.swift`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The daemon method that makes the call one act, and the predicate that makes the call the app's own. US1 serves it, US2 compares against it, US3 names it.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### The wire

- [x] T004 Add `public struct FinishTurnRequest: Codable, Sendable` to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift` beside `ReportOutcomeRequest`, with `token: String`, `outcome: String`, `message: String`, `prompts: [SuggestedPrompt]` and a memberwise `public init`. Doc comment: the token does the work it does for a report; `outcome` is the wire spelling, checked at the daemon and never rounded; `prompts` is already cleaned by the service and may be empty, which means no chips

### The daemon

- [x] T005 In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift`, split `reportOutcome(_:)` so its four refusals and its tail are reusable: a private `func checkedReport(token:outcome:message:) throws -> (agentID: UUID, agent: Agent, report: WorkReport)` that raises, in this order and with the existing sentences, `noSuchAgent` for a token that binds to no live agent, `invalidParams` for an outcome not one of the five, `invalidParams` for a pending permission or elicitation for that agent, and `invalidParams` for an empty message; and a private `func land(_ report: WorkReport, on agent: inout Agent, prompts: [SuggestedPrompt]?, agentID:) async -> String` that sets `agent.report`, sets `agent.suggestedPrompts` when `prompts` is non-nil, records `.workReported`, calls `changed(agent)` once, calls `reconsider()`, and returns the outcome's sentence. `reportOutcome` becomes a call to both with `prompts: nil` and must read and behave exactly as before (contracts/daemon-api.md)
- [x] T006 Add `public func finishTurn(_ request: DaemonAPI.FinishTurnRequest) async throws -> String` to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift` after `reportOutcome`: `checkedReport` first, then `land` with `prompts: Array(request.prompts.prefix(SuggestedPrompt.limit))` — an empty array, not nil, so a call with no prompts clears the chips (FR-003, FR-008, Research R3). The returned note is the outcome's sentence followed, when prompts is non-empty, by a space and the chips' sentence from `suggestPrompts` ("3 shown above the prompt. The person may tap one, edit it, or ignore them."). Doc comment says why the merge is here and not in the helper (Research R2)
- [x] T007 Add the `DaemonAPI.Method.agentsFinishTurn` case to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift` beside `agentsReportOutcome`, decoding `FinishTurnRequest` and returning `["note": .string(try await finishTurn(request))]`

### Recognising the call

- [x] T008 [P] Add `public var isFinishingTurn: Bool { (name ?? title).hasSuffix(AppTool.finishTurn) }` to the `ToolCall` extension in `Packages/AgentsKit/Sources/AgentsKitCore/Model/PermissionRequest.swift`, first among the app-tool predicates, and make `isTheApps` `isFinishingTurn || isSuggestingPrompts || isShowingFile || isManagingWorkflows || isReportingOutcome`. Reword the `isAutoAllowable` comment from "All three of the app's own tools" to "Every one of the app's own tools" (FR-020)
- [x] T009 [P] In `Packages/AgentsKit/Sources/AgentsKitCore/Model/TranscriptDisplay.swift`, extend the suppression in `add(_:)` from `call.isSuggestingPrompts || call.isReportingOutcome` to include `call.isFinishingTurn`, and reword the comment: the end-of-turn call is not drawn, by any of its three names, because what it did is the chips above the prompt and the report at the foot (Research R8). Check `git status` first: this file was in 022's diff this morning

**Checkpoint**: `swift build --package-path Packages/AgentsKit` is green; `OutcomeReportTests` passes unchanged.

---

## Phase 3: User Story 1 - The turn ends in one breath (Priority: P1) 🎯 MVP

**Goal**: An agent makes one call with an outcome, a message and up to four prompts, and the agent is left exactly as two calls would leave it — or, if refused, untouched.

**Independent Test**: Run an agent that ends its turn with one `finish_turn` call carrying `done`, a sentence and two prompts. From the record alone: `report` is set, two chips are set, one `.workReported` entry is at the foot, and the call itself is not drawn. Make the same call under a pending permission and confirm nothing landed.

### Tests for User Story 1

- [x] T010 [P] [US1] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AppServiceTests.swift`, extend `pair(...)` with a `finishTurn: AppService.FinishSink` parameter defaulted to a refusal, and change `everyToolIsListedWithASchemaTheAgentCanFill` to expect five names in the order `[finishTurn, showFile, workflow, suggestPrompts, reportOutcome]`; assert `finish_turn`'s schema has the five-value enum on `outcome`, `required == ["outcome", "message"]`, and `next_prompts.items.required == ["label", "prompt"]` with `maxItems` 4 (contracts/agent-tool.md)
- [x] T011 [P] [US1] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AppServiceTests.swift`: `aFinishCallReachesTheSinkWithBothHalves` (outcome, trimmed message and two prompts arrive at the sink; reply is not an error), `aFinishCallWithNoPromptsStillReachesTheSink` (`next_prompts` absent and `next_prompts: []` both reach the sink with an empty list — never refused, FR-003), `aFinishCallWithAnUnknownOutcomeIsRefusedWhole` (sink never called; text names `nothing_to_do` and `partly_done`; Research R4), `aFinishCallWithNoWordsIsRefused`, `aPrefixedFinishCallIsStillOurTool` (`mcp__agents__finish_turn`), and `fiveNextPromptsBecomeFour`
- [x] T012 [P] [US1] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/FinishTurnTests.swift` a `finish(_ core:_ launcher:_ outcome:_ message:_ labels: String...)` helper calling `core.finishTurn`, and the tests `oneCallLandsTheReportAndTheChips` (after settle: `report?.outcome == .done`, `suggestedPrompts.map(\.label) == ["A", "B"]`, and exactly one `.workReported` entry at the foot of the transcript — FR-001, FR-004), `oneCallWithNoPromptsLeavesNoChips` (FR-003), `theReplyNamesBothHalves` (note contains `Noted.` and `2 shown above the prompt`; a call with no prompts contains only the first — FR-007), and `theNextPromptClearsBoth` (send a person's prompt; `report == nil` and `suggestedPrompts.isEmpty` — FR-009)
- [x] T013 [P] [US1] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/FinishTurnTests.swift`: `aCallWhileAQuestionIsOutstandingLandsNothing` (copy the `script.permission` setup from `OutcomeReportTests.aReportWhileAQuestionIsOutstandingIsRefused`; after the refusal `report == nil` **and** `suggestedPrompts.isEmpty` — FR-005), `aTokenThatNoLongerSpeaksForAnAgentIsRefused` (FR-006), and `aSecondCallIsTheWholeAccount` (first call `partly_done` with two prompts; second `done` with none; expect `report?.outcome == .done` and no chips — FR-008)
- [x] T014 [P] [US1] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/FinishTurnTests.swift` `thePermissionForTheFinishCallIsAnsweredForYou`, a copy of `SuggestedPromptTests.thePermissionForOurOwnToolIsAnsweredForYou` with `"name": "mcp__agents__finish_turn"` and `"title": "finish_turn"`
- [x] T015 [P] [US1] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/TranscriptDisplayTests.swift` `theFinishCallIsNotDrawn`, modelled on `SuggestedPromptTests.theCallItselfIsNotDrawnInTheTranscript` with `finish_turn` / `mcp__agents__finish_turn`, and a second case where the finished update carries only `"Tool call"` as its title and is still suppressed by id
- [x] T016 [P] [US1] In `Packages/AgentsKit/Tests/AgentsKitTests/Integration/UnreportedEndingTests.swift`, add `theQuestionNamesTheOneTool`: the enqueued app prompt's text contains `AppTool.finishTurn` and neither old name (FR-018)

### Implementation for User Story 1

- [x] T017 [US1] In `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, add `public static let finishTurnToolName = AppTool.finishTurn`, `public typealias FinishSink = @Sendable (String, String, [SuggestedPrompt]) async -> Outcome`, a `finishSink` property, and a `finishTurn:` init parameter defaulted to `{ _, _, _ in .refused("This app cannot end a turn.") }`, placed first among the sinks in the signature so the helper reads top-down as the list does
- [x] T018 [US1] In `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, add `static let finishTurnTool: JSONValue` with title "Finish the turn", the description from `contracts/agent-tool.md` verbatim, and the schema: `outcome` (the five-value enum, "The one that is true."), `message` (014's description), `next_prompts` (array, `minItems` 0, `maxItems` `SuggestedPrompt.limit`, items `{label, prompt}` both required, descriptions copied from `tool`), `required: ["outcome", "message"]`. Doc comment in the file's voice: this is the one call that ends a turn, why the ordering paragraph 014 had is gone, and that the last paragraph is 014's verbatim because the line between ending and asking still has to be drawn
- [x] T019 [US1] In `AppService.handle` in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, add the `finish_turn` branch **before** the other four (longest-suffix note in the comment stays true: none shares a suffix): trim and check `outcome` with `WorkOutcome(wire:)` → refuse with 014's five-name sentence; trim and check `message` non-empty → refuse with 014's no-words sentence; `SuggestedPrompt.list(in: arguments?["next_prompts"])` → may be empty; then `reply(await finishSink(raw, message, prompts))`. Add `finishTurnTool` first in the `tools/list` array (data-model.md "Validation, in the order it runs")
- [x] T020 [US1] In `Daemon/Sources/main.swift`, add a `finishTurn:` closure to the `AppService` init that relays `DaemonAPI.Method.agentsFinishTurn` with `DaemonAPI.FinishTurnRequest(token:outcome:message:prompts:)` and fallback `"Noted."`. Update the comment above `relay` from "Both tools" to say every tool does the same thing
- [x] T021 [US1] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, change `askForOutcome` to name `AppTool.finishTurn`: "That turn ended without a report. Call finish_turn now with how it actually went, and say nothing else. If the work is done, that is done." Extend its doc comment: answered by either name, because the aliases are accepted everywhere (FR-018, contracts/briefing.md)
- [x] T022 [US1] Run `swift test --package-path Packages/AgentsKit --filter 'AppServiceTests|FinishTurnTests|TranscriptDisplayTests|UnreportedEndingTests|OutcomeReportTests|SuggestedPromptTests'` and make every test in T010–T016 pass with no expectation in `OutcomeReportTests` or `SuggestedPromptTests` changed

**Checkpoint**: One call ends a turn. A fresh conversation is not yet told to make it (that is US3), so this is testable against the daemon and by calling the tool by hand from a runtime.

---

## Phase 4: User Story 2 - A conversation that was told the old names keeps working (Priority: P1)

**Goal**: Both old names stay listed, described as aliases, and accepted with their existing rules; a call by an old name touches only its half; the alias handling is confined so it can be deleted later.

**Independent Test**: Drive `suggest_next_prompts` then `report_outcome` (and the reverse) through the daemon for one agent, and `finish_turn` with the same values for another; the two agents' `report` and `suggestedPrompts` are equal. Call each alias alone and confirm the other half is untouched.

### Tests for User Story 2

- [x] T023 [P] [US2] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/FinishTurnTests.swift`: `theOldNamesInEitherOrderLeaveTheSameStateAsOneCall` (two agents; one gets `core.suggestPrompts` then `core.reportOutcome`, the other `core.finishTurn`, same values; compare `report?.outcome`, `report?.message`, `suggestedPrompts.map(\.label)`; then the reverse order — FR-012, SC-006), `theOldSuggestionNameAloneTouchesOnlyTheChips` (after `finishTurn(done, 2 prompts)`, `suggestPrompts(["C"])` → labels `["C"]`, report still `.done`), and `theOldOutcomeNameAloneTouchesOnlyTheReport` (after `finishTurn(done, 2 prompts)`, `reportOutcome(stuck)` → report `.stuck`, chips still two)
- [x] T024 [P] [US2] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AppServiceTests.swift` `theOldNamesAreListedAsAliasesOfTheOneTool`: the last two entries of `tools/list` are `suggest_next_prompts` and `report_outcome`, each description contains `finish_turn` and the word "older", and each `inputSchema.required` is unchanged (`["prompts"]` and `["outcome", "message"]`) (FR-011, FR-013)
- [x] T025 [P] [US2] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/UnreportedEndingTests.swift` `anAnswerByTheOldNameStillAccountsForTheEnding`: a silent ending is asked; the fake answers by calling `core.reportOutcome` with the minted token; `endingIsUnaccountedFor` is false and `report?.outcome == .done` (FR-018)

### Implementation for User Story 2

- [x] T026 [US2] In `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, replace the descriptions of `tool` (`suggest_next_prompts`) and `reportOutcomeTool` with the one-paragraph alias descriptions from `contracts/agent-tool.md`, retitle them "Suggest what to ask next (older name)" and "Say how the work went (older name)", leave their schemas untouched, and move them to the end of the `tools/list` array. Replace their doc comments with one shared comment: kept so a conversation briefed before 2026-09-23 finds what it was told; removing them is deleting these two entries, their two `handle` branches, their two sinks in the helper and their two predicates in `PermissionRequest`, and nothing else may depend on them (FR-014, Research R5)
- [x] T027 [US2] In `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, rewrite the type's header comment: the app offers one tool to end a turn and two to act mid-turn, plus two older names; `toolName` is no longer "how the app knows a tool call is ours" — reword that property's comment to say it is the older suggestion name and that `finishTurnToolName` is the current one. Delete `public static let askForSuggestions = Briefing.suggestions` (nothing reads it; the test that did is rewritten in T033)
- [x] T028 [US2] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift`, update the file's header comment ("Where a suggested prompt, and a file the agent wants looked at, come from") and the doc comment on `suggestPrompts` to say the old methods stay because the helper relays the old names to them, and that they share `checkedReport`/`land` with `finishTurn` so the refusals cannot drift
- [x] T029 [US2] Run `swift test --package-path Packages/AgentsKit --filter 'FinishTurnTests|AppServiceTests|UnreportedEndingTests|OutcomeReportTests|SuggestedPromptTests'` and make T023–T025 pass with `OutcomeReportTests` and `SuggestedPromptTests` still unchanged (SC-007)

**Checkpoint**: A resumed conversation cannot tell the difference. The two integration suites the old tools have always had are green without edits.

---

## Phase 5: User Story 3 - The briefing gets shorter and agents still do it (Priority: P2)

**Goal**: One briefing line in place of two, naming `finish_turn` and nothing older; the "use this instead" sentence names it too; and the live suite measures whether the runtimes call it.

**Independent Test**: `Briefing.lines(for:)` for every built-in policy has at most five lines, the first contains `finish_turn` and neither old name, and the whole block is under 1,500 characters. Then one live turn per runtime ends with the call.

### Tests for User Story 3

- [x] T030 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift`, change `theToolsItNamesAreNamedExactly` to `#expect(Briefing.finish.contains(AppTool.finishTurn))` in place of the `suggestions` line, and add `theFinishLineNamesNeitherOldName` (`!Briefing.finish.contains(AppTool.suggestPrompts)`, `!Briefing.finish.contains(AppTool.reportOutcome)`, and the same over `Briefing.text(for:)` for every built-in policy — FR-016)
- [x] T031 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift`, tighten `itStaysShortEnoughToBeRead` to `count < 1_500` and `lines.count <= 5`, and rewrite its doc comment: 023 folded two lines into one, so the ceiling comes down rather than up, and it is still "a ceiling to notice, not a rule" (SC-003)
- [x] T032 [P] [US3] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift` `theFinishLineGoesFirst`: `Briefing.lines(for:)[0] == Briefing.finish` for every built-in policy, with a comment giving the file's rule (the line that fires every turn goes first) and why 014's after-escalation placement no longer applies (Research R6)
- [x] T033 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ToolPolicyTests.swift`, change `everyCategorySaysWhatToDoInstead` to expect `RemitCategory.suggestions.instead.contains(AppTool.finishTurn)` and add `!...contains(AppTool.suggestPrompts)` (FR-017)
- [x] T034 [P] [US3] Fill `Packages/AgentsKit/Tests/AgentsKitTests/Live/FinishTurnLiveTests.swift` modelled on `OutcomeReportLiveTests`: a `run(_:asking:)` that waits past the first ending as that file does, then `@Test(arguments: ["claude", "grok"]) func askedOutrightItCallsIt` (prompt names the tool; expect `report != nil` and `!suggestedPrompts.isEmpty`) and `@Test(arguments: ["claude", "copilot", "grok"]) func fromTheBriefingAloneDoesItEndTheTurn` (a plain task; record per runtime whether `report` is set, its outcome, and `suggestedPrompts.count`, printing a line in the format 014's R11 uses; never fail on a runtime that will not call it — a finding, not a bug)

### Implementation for User Story 3

- [x] T035 [US3] In `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift`, replace `suggestions` and `outcome` with `public static let finish`, the text from `contracts/briefing.md` verbatim, and a doc comment that carries forward what the two it replaces said: descriptions alone got the tool called never; written as the person speaking; does not list the five because the schema does; does not name the old tools. Change `lines(for:)` to `[finish, liveDocument, escalation(named:), workflows(scheduling:)] + residue` and rewrite its comment for five lines. Update the type's header where it says "the one that closes a turn"
- [x] T036 [P] [US3] In `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ToolPolicy.swift`, change `RemitCategory.suggestions.instead` to `"Use \`\(AppTool.finishTurn)\` at the end of the turn."` (FR-017, Research R7)
- [x] T037 [US3] Run `swift test --package-path Packages/AgentsKit --filter 'BriefingTests|ToolPolicyTests|BriefingLiveTests'` (the live one only if `AGENTS_LIVE=1`) and make T030–T033 pass. Fix any test elsewhere that asserted `Briefing.lines(for:).count == 6` or looked for the old `suggestions` text
- [ ] T038 [US3] Run `FinishTurnLiveTests` per `quickstart.md` check 6 against every signed-in runtime, and write the per-runtime findings into `specs/023-end-of-turn-tool/research.md` under R10 in the table shape of 014's R11, with the SC-004 comparison stated in one sentence per runtime. Launch the daemon with a clean environment per memory (`env -i`)

**Checkpoint**: A fresh conversation is told once, in one line, and the numbers say whether it listens.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: The comments that still say "four tools", the by-eye walk, and the record.

- [x] T039 [P] `grep -rn "four tools\|fourth\|three tools\|All three" Packages/AgentsKit/Sources Daemon/Sources` and fix every comment that counts the app's tools, including the `AppService` header ("This speaks MCP itself... it is four methods of JSON-RPC" is about MCP methods and stays), `AppTool.swift`'s "And the fourth", and the `autoAllowed` comment in `DaemonCore+AppTools.swift`
- [x] T040 [P] In `specs/014-agent-outcomes/contracts/agent-tool.md`, add a one-line note at the top: superseded by 023's `finish_turn`; `report_outcome` remains as an alias with this contract
- [x] T041 Run the full suite `swift test --package-path Packages/AgentsKit` and both app builds (`xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build`, then the Remote scheme, sequentially per memory). Record the counts at the foot of this file. The two flaky tests named in memory (`stoppingAnAgentBeforeItIsPickedUpWithdrawsIt`, `aConversationResumedAfterARestartIsNotBriefedAgain`) are pre-existing
- [ ] T042 Walk `quickstart.md` check 7 by eye: launch the app with `env -i … open`, run one short turn on Claude, and confirm chips above the prompt, the row reading the agent's sentence, no `finish_turn` line in the transcript, and no "Finished without saying how it went". Screenshot on a delay per memory
- [x] T043 Update the memory file `next-up-017-workflow-settings.md` and `MEMORY.md`'s 023 line: built, walked or not, commits, and the alias-removal condition still open

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup. **Blocks every user story** — US1 serves `finishTurn`, US2 compares old names against it, US3 names it.
- **US1 (Phase 3)**: Depends on Foundational. Nothing else.
- **US2 (Phase 4)**: Depends on US1 for `finishTurn` to compare against and for `handle` to have the new branch the aliases sit beside. T023 and T025 can be written alongside US1's tests.
- **US3 (Phase 5)**: Depends on Setup only for the name; T030–T036 do not need US1's tool to exist to compile. T038 needs everything, since a live runtime calls the tool the briefing names.
- **Polish (Phase 6)**: Depends on everything wanted.

### Within Each User Story

- Tests are written first and must fail before implementation.
- Model before daemon, daemon before service, service before helper.
- `OutcomeReportTests` and `SuggestedPromptTests` are never edited. If a change makes one fail, the change is wrong (SC-007).

### Parallel Opportunities

- T002 and T003 alongside T001.
- T008 and T009 together, after T004–T007.
- All of T010–T016 together: seven test tasks, four files.
- T023, T024, T025 together.
- T030–T034 together; T036 alongside T035.
- T039 and T040 together.

---

## Parallel Example: User Story 1

```bash
# The tests, together, before any implementation:
Task: "Unit/AppServiceTests.swift — five tools listed, finish_turn's schema, its refusals"
Task: "Integration/FinishTurnTests.swift — both halves land, or neither"
Task: "Unit/TranscriptDisplayTests.swift — the call is not drawn"
Task: "Integration/UnreportedEndingTests.swift — the ask names finish_turn"

# Then, in order: AppService (T017–T019), helper (T020), the ask (T021).
```

---

## Implementation Strategy

### MVP (User Story 1 only)

Phases 1, 2 and 3. That ships the tool and the daemon method, callable by any agent that finds it in the list. Nothing tells a fresh agent to use it yet and nothing has changed for an old one, so it is safe to leave in the tree between sittings.

### Incremental delivery

1. Setup + Foundational → the method exists; the existing suites are green.
2. **+ US1 → MVP.** One call ends a turn.
3. + US2 → the old names are aliases by description, not just by accident. Small.
4. + US3 → fresh conversations are told the one line, and the live numbers say whether it lands. **This is the step that changes what every runtime is told**, so run T038 the same day and read the numbers before moving on.
5. Polish.

### Notes

- `[P]` tasks are different files with no dependency between them.
- Commit after each phase. Per memory, three lanes share this tree: stage by hunk, never `git add -A`.
- The two things easiest to get wrong, both of which a test catches and a reading does not: a `finishTurn` that sets the chips before a refusal fires (FR-005), and a `finishTurn` with no prompts that leaves the previous call's chips standing (FR-008).

---

## Implementation Notes

### Phases 1–3, built 2026-09-23 in a detached worktree at `4e33841`

Everything in T001–T022 is as the tasks say, with four things worth knowing:

- **The alias reordering landed in T019, not T026.** `tools/list` already returns
  `finish_turn`, `show_file`, `manage_workflows`, `suggest_next_prompts`, `report_outcome`, because
  the list test in T010 asserts the final order and there was no reason to assert an intermediate
  one. T026 has only the alias descriptions and titles left to do.
- **One test helper outside the plan was edited.** `SuggestedPromptTests.prompts(_:)` leaves the
  app's own ask out of what it counts by looking for the ask's tool name, and that name is now
  `finish_turn`. Keyed on wording, not an expectation, so SC-007 holds: no expectation in
  `SuggestedPromptTests` or `OutcomeReportTests` changed. Without the edit two of its tests fail
  under parallel runs and pass alone, which is how it was found.
- **`aTurnThatSaidNothingIsAskedExactlyOnce` now looks for `finish_turn`** in the ask, beside
  the new `theQuestionNamesTheOneTool`. Same fact as before, new name.
- **The `Agents` scheme does not build at `4e33841`** — `App/Sources/Sidebar/LivePage.swift:172`
  wants a `Text.appText` that exists only in the shared tree's uncommitted work. Not 023's: no
  file under `App/` was touched. The helper's change in `Daemon/Sources/main.swift` was compiled
  through the `agentsd` scheme instead, which succeeds.

The two refusal sentences an outcome meets at the service are now `AppService.unknownOutcome` and
`AppService.noWords`, shared by the one call and the older name. On the daemon, `reportOutcome`
and `finishTurn` share `checkedReport` and `land`, and the chips' sentence is `shownNote(count:)`,
shared with `suggestPrompts`.

Counts: the six affected suites, 88 tests, three runs green; the whole package, 1,104 tests,
green; `swift build` and the `agentsd` scheme green.

### Phases 4–5, built 2026-09-24 on the same branch

T023–T037 are as the tasks say. T038, the live run, is deliberately not done: it needs signed-in
runtimes and the numbers are Alex's to read. Two notes:

- **T025 is the new-name half.** The old-name half of FR-018 — an ask answered by
  `report_outcome` — was already `anAnsweredQuestionLeavesNothingMarkingItAsHavingBeenAsked`
  in `UnreportedEndingTests`, so the new test `anAnswerByEitherNameAccountsForTheEnding` answers
  by `finish_turn` with a chip, and the two together are the requirement.
- **The briefing's `liveDocument` comment named `suggestions`** as the line whose measurement it
  repeated. Reworded to "the suggestion line", since the constant is gone.

`Briefing.finish` is first in `lines(for:)`; `Briefing.outcome` and `Briefing.suggestions` are
gone, and so is `AppService.askForSuggestions`. The ceiling in `BriefingTests` is 1,500 characters
and five lines.

Counts: the seven affected suites, 113 tests, three runs green; the whole package, 1,113 tests,
green.

### Polish, 2026-09-24

T039, T040, T041 and T043 done; T038 (the live run) and T042 (the by-eye walk) are Alex's.

- **T039** found five comments still counting the app's tools the old way, in `DaemonAPI.swift`
  (the two older methods and the older request), `DaemonCore+AppTools.swift` (`autoAllowed`), and
  the header of `OutcomeReportTests`. The `AppService` header and `AppTool.swift` had already been
  rewritten in US2 and Setup. Nothing under `App/` or `Remote/` counts them.
- **T041 record.** Package suite: 1,113 tests in 121 suites, green, one run. `swift build`,
  `agentsd` and `Remote` schemes build. The `Agents` scheme does not build at any commit on this
  branch, for the reason memory records (`LivePage.appText` exists only in the shared tree's
  uncommitted type-scale lane); nothing under `App/` changed here. The two flaky pick-up tests
  memory names did not fire in this run.
