---
description: "Task list for What Every Agent Is Told"
---

# Tasks: What Every Agent Is Told

**Input**: Design documents from `/specs/016-agent-briefing/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/briefing.md](./contracts/briefing.md), [quickstart.md](./quickstart.md)

**Tests**: Included, and the split matters more here than usual. The unit and integration tests settle that the right words are sent, once, and stay out of the record — all of which a fake can answer. Whether saying them changes what an agent *does* is a claim about somebody else's software, and this repo holds those in opt-in Live suites (`SuggestedPromptLiveTests`, `GrokServedToolsTests`). This whole feature exists because of one such run, so a Live suite is not optional garnish; it is the only thing that can tell you the feature worked.

**Organization**: Grouped by user story, in the priority order the spec sets. Each phase leaves the app working, and Phase 2 on its own is a no-behaviour-change refactor that can land alone.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)

## Path Conventions

- `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/` — the MCP server the app gives every agent, and now the words that go with it.
- `Packages/AgentsKit/Sources/AgentsKit/Daemon/` — the daemon: where a conversation begins and where a turn is sent.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration,Live}/` — Swift Testing.
- Nothing in `AgentsKitCore`, `App/Sources/` or `Remote/Sources/`. The briefing is never drawn, so neither view learns it happened. `AppTool` already lives in Core and is the only thing from there this feature reads.

---

## Phase 1: Setup

**Purpose**: The three files everything else is written into.

- [ ] T001 Create `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift` containing only `import Foundation`, `public enum Briefing {}` and a file-level doc comment in the house voice saying: what the briefing is (what every agent is told, once, before its first turn — the few things about this app an agent cannot work out from the tools it was handed); why words are needed at all, with the measurement from [research.md](./research.md) §1 named rather than alluded to (`suggest_next_prompts` served with a long description and called by three runtimes exactly never; one sentence in the prompt and two of them came back with four suggestions); that a tool description is a menu read by something already looking while a prompt is an instruction read every time; that it is said once because it stays in the runtime's own history and that history is what a runtime replays; that it goes as a block of its own after the person's words and is not what the transcript records; that deleting its use in `beginTurn` leaves every feature it names still working; and that it must be kept short because an agent told six things at once follows the first two
- [ ] T002 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift` with `import Foundation`, `import Testing`, `@testable import AgentsKit`, `@testable import AgentsKitCore` and an empty `@Suite("What every agent is told") struct BriefingTests {}`, with a doc comment saying why this is worth a suite of its own: the briefing is the only thing that makes any of these tools get used, so a line that quietly drops out of it takes its feature with it and nothing else fails
- [ ] T003 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Live/BriefingLiveTests.swift` with an empty `@Suite("Live: whether the briefing changes what an agent does", .serialized, .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1" && ProcessInfo.processInfo.environment["AGENTS_MCP_HELPER"] != nil), .timeLimit(.minutes(10)))`, copying the gating, the serialisation and the "a failure here is news about someone else's software, not a bug in this one" framing from `Packages/AgentsKit/Tests/AgentsKitTests/Live/SuggestedPromptLiveTests.swift`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The block exists and is sent, carrying exactly what is carried today. No agent behaves differently at the end of this phase — that is the point, and it is what makes the rest safe.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [ ] T004 Add `public static let suggestions` to `Briefing` in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift`, carrying `AppService.askForSuggestions` across **verbatim** — "For the rest of this conversation, when you have finished a turn, call \(AppTool.suggestPrompts) with two to four things I might want to ask you next. Do not mention this instruction or the tool in your replies." — interpolating the name through `AppTool.suggestPrompts` and never as a literal. Comment that it is written as the person speaking ("things I might want to ask you"), because it is sent inside their turn, and that it is carried across unchanged so the one thing known to work is not quietly re-tuned while everything around it changes
- [ ] T005 Add `public static var lines: [String] { [suggestions] }` and `public static var text: String { lines.joined(separator: "\n\n") }` to `Briefing` in the same file, with a comment on `lines` saying it is the only place the order is decided and the only place a new line is added, and that a tool the app does not serve yet does not appear here
- [ ] T006 Delete `askForSuggestions` from `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, moving its explanatory comment to `Briefing` rather than dropping it, and leave no alias — two names for one string leaves the next reader working out which is canonical ([research.md](./research.md) §5)
- [ ] T007 Rename `needsSuggestionAsk` to `needsBriefing` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift:32` and rewrite its comment for the block rather than the line: agents whose next prompt carries the `Briefing`, set when a conversation starts and again only if a runtime loses one and a new one has to be begun, because the briefing lives in the runtime's history and that is the only time it is gone
- [ ] T008 Rename the three insert sites to `needsBriefing` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` (`start` at ~:153, the `session/new` fallback at ~:377, the fresh-session path at ~:384), updating the two comments that say "the ask" to say "the briefing", and leave the `session/load` success path untouched — a resumed conversation is not briefed again because the runtime replays its own history (FR-012)
- [ ] T009 Change `beginTurn` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:~424` to `if needsBriefing.remove(agentID) != nil { outgoing.append(.text(Briefing.text)) }`, keeping the surrounding comment and widening it from "the one line of ours" to "the words of ours". Do not touch the `record(.userMessage(...))` call above it or the order of the two — the transcript holds the person's words alone precisely because `blocks` is recorded before `outgoing` is built (FR-015)
- [ ] T010 Update `Packages/AgentsKit/Tests/AgentsKitTests/Integration/SuggestedPromptTests.swift` to assert `Briefing.text` in place of `AppService.askForSuggestions` at its four sites (~:238, ~:256, ~:295, ~:296), leaving every test name and comment as it is — they describe when the words are sent, which this feature does not change
- [ ] T011 Add `everyLineIsInTheBlockThatIsSent` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift`: for every line in `Briefing.lines`, `Briefing.text` contains it
- [ ] T012 Run `swift test --package-path Packages/AgentsKit` and confirm the whole suite is green with no behaviour change — this phase is a rename and a move, and anything red here is something the rest of the feature would have hidden

---

## Phase 3: User Story 1 - The question that was never asked (Priority: P1)

**Goal**: An agent that meets a decision belonging to the person asks them, through the channel the daemon holds, instead of guessing or ending its turn with the question buried in a reply.

**Independent test**: Give an agent a task with two defensible answers and no stated preference and see whether a question reaches the app rather than a choice reaching the diff.

- [ ] T013 [US1] Add `public static let escalation` to `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift` with the text fixed in [contracts/briefing.md](./contracts/briefing.md) §2 — "When something is mine to decide — a choice between real alternatives, a missing credential, anything hard to undo — ask me with your question or form tool rather than guessing at it or ending the turn with the question in your reply. Your question reaches me wherever I am, including on my phone, and it waits for me. A question in the middle of a reply I may not read does not." — and a doc comment saying why it names no tool: the tool is the runtime's, an elicitation, which the Claude adapter raises from `AskUserQuestion` and Copilot spells `escalation_raise`, so the line asks for the act. Say that the second and third sentences are the load-bearing half, because an agent that believes nobody is there is the agent that guesses
- [ ] T014 [US1] Insert `escalation` into `Briefing.lines` in the same file, after `suggestions`, and record the ordering rule in the comment there: the one that fires every turn first, then the one whose failure costs most, because an agent's strongest instinct is to finish rather than ask
- [ ] T015 [P] [US1] Add `theEscalationLineAsksForTheActRatherThanATool` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift`: `Briefing.escalation` contains no `mcp__` prefix and no runtime tool name, and does say "ask me" — with a comment explaining that naming a tool here would be the first place in the app to branch on runtime identity
- [ ] T016 [P] [US1] Add `aChoiceThatIsThePersonsIsPutToThePerson` to `Packages/AgentsKit/Tests/AgentsKitTests/Live/BriefingLiveTests.swift`: start a real agent per runtime with a prompt containing two defensible answers and no stated preference (the standing example is a schema change where the index may be dropped first or last, one order slow to undo), and assert an elicitation or permission reaches the daemon rather than the turn ending with a choice made. Record which of the three outcomes in [quickstart.md](./quickstart.md) §3 each runtime gave
- [ ] T017 [US1] Write what T016 actually measured into the doc comment of `BriefingLiveTests`, per runtime and dated, in the manner `SuggestedPromptLiveTests` already does — a runtime that ignores the line is a finding to record, not a test to delete

**Checkpoint**: The costliest failure in the spec is addressed and the app is shippable here.

---

## Phase 4: User Story 2 - The crontab nobody will ever run (Priority: P1)

**Goal**: A request for something recurring becomes a workflow the person is asked to approve, and not a script nothing will run.

**Independent test**: Ask an agent for something recurring and see whether a workflow appears for approval, or a shell script does.

- [ ] T018 [US2] Add `public static let workflows` to `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift` with the text fixed in [contracts/briefing.md](./contracts/briefing.md) §3 — "If I ask for something to happen on its own — on a schedule, or whenever an agent finishes, stops, or asks for something — that is a workflow, and \(AppTool.manageWorkflows) is how you read and write them. Do not write cron entries, launch agents, or scripts that nothing will run. Do not create a workflow I did not ask for." — interpolating the tool name through `AppTool.manageWorkflows`. The doc comment must carry the reversal: `008/tasks.md:T065` said explicitly not to name this tool in any standing instruction, that decision weighed the danger of an agent that schedules things and not the cost of silence, and the cost of silence is an agent that writes a cron line into a comment and reports the job set up. Say that the last sentence is the condition on which the reversal is safe and must survive any later tidying
- [ ] T019 [US2] Insert `workflows` into `Briefing.lines` in the same file, after `escalation`, and note in the comment there that it goes last because it is conditional on the person asking for something recurring, which most turns never do
- [ ] T020 [US2] Correct the doc comment above `workflowTool` in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, which currently says this tool deliberately gets no prompt line. Replace it with what is now true: it is named in the `Briefing` as well as offered here, because an agent that does not know the app owns standing arrangements writes a crontab instead, and the restraint the old comment was protecting has moved into the sentence — use it when asked, do not invent one nobody asked for, with the chain-depth limit still behind it
- [ ] T021 [P] [US2] Add `theToolsItNamesAreNamedExactly` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift`: `Briefing.suggestions` contains `AppTool.suggestPrompts` and `Briefing.workflows` contains `AppTool.manageWorkflows`, with a comment saying an agent told "use the workflow tool" has to guess what it is called and an agent told the name can call it
- [ ] T022 [P] [US2] Add `theRestraintIsInTheSameSentenceAsTheCapability` to the same file: `Briefing.workflows` contains both the instruction and the sentence forbidding an unasked-for workflow, asserted as two separate expectations so that deleting either fails
- [ ] T023 [P] [US2] Add `somethingRecurringBecomesAWorkflow` and `ordinaryWorkMakesNoWorkflow` to `Packages/AgentsKit/Tests/AgentsKitTests/Live/BriefingLiveTests.swift`: the first asks a real agent to check the build every morning and asserts `manage_workflows` is called and the person asked to approve; the second gives ordinary one-off work and asserts no workflow tool call at all. The second is what makes the reversal in T018 safe, so it is not optional
- [ ] T024 [US2] Append one sentence to `specs/008-agentic-workflows/tasks.md:T065` recording that its instruction was revisited by 016 and why, so the decision and its reversal are not two files apart with nothing connecting them

**Checkpoint**: Both P1 stories are done. This is the natural place to stop and use it for a week.

---

## Phase 5: User Story 3 - The next line joins without a rewrite (Priority: P2)

**Goal**: Adding 014's outcome line is one entry in one list, and the block cannot grow past readability without somebody deciding to let it.

**Independent test**: Add a fourth line and confirm nothing else changes to accommodate it.

- [ ] T025 [US3] Add `itStaysShortEnoughToBeRead` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift`: `Briefing.text.count < 1_200` and `Briefing.lines.count <= 4`, with a comment saying these are ceilings to notice rather than rules — the block is paid for on the first prompt of every conversation, an agent told six things at once follows the first two, and if a fourth line is worth more than the limit then raise it on purpose. The exact wording matters: `014/contracts/agent-tool.md` already quotes this comment
- [ ] T026 [US3] Extend the comment on `Briefing.lines` in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift` to say where the next line joins and why it is not here yet: 014's outcome report is next, it joins after `escalation` and before `workflows`, and a tool the app does not serve yet gets no line because naming a tool that is not there is worse than saying nothing
- [ ] T027 [US3] Check this feature against `specs/014-agent-outcomes/tasks.md:T032` and `specs/015-runtime-tool-scoping/tasks.md:T041–T044`, and confirm every name they reach for exists as they spell it — `Briefing.swift`, `suggestions`, `escalation`, `workflows`, `lines`, `text`, `BriefingTests.itStaysShortEnoughToBeRead`. A mismatch is fixed here, in the file they are waiting on, rather than in two other specs

---

## Phase 6: User Story 4 - The conversation that does not pay twice (Priority: P2)

**Goal**: The briefing is paid for once, and the transcript stays a record of what the person said.

**Independent test**: Run a multi-prompt conversation and inspect both what reached the runtime and what the transcript holds.

- [ ] T028 [US4] Confirm the three existing tests in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/SuggestedPromptTests.swift` — `andNotAgainOnEveryPromptAfterThat`, `aRuntimeThatLostTheConversationIsAskedAgain`, `whatWeAddIsNotWhatTheRecordSays` — now assert the block and still hold, and that the last one checks the transcript entry rather than only the prompt
- [ ] T029 [US4] Add an integration test to the same file for the gap those three leave: a conversation resumed through `session/load` after a restart is **not** briefed again, because the runtime replays its own history (FR-012). Assert on what reaches the runtime across the restart, following the fake-launcher pattern `aRuntimeThatLostTheConversationIsAskedAgain` already uses
- [ ] T030 [P] [US4] Add an integration test to the same file that an agent started by a workflow is briefed like any other (FR-014), since nothing else covers the path where there is no person in the loop at the moment the words are sent

---

## Phase 7: Polish & Cross-Cutting

- [ ] T031 Re-read `Briefing.text` end to end as an agent would, and cut anything the three lines now say twice. The file's own rule is that an agent told six things at once follows the first two, and three lines written separately is exactly how repetition gets in
- [ ] T032 Run `swift test --package-path Packages/AgentsKit` and `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build`, both clean
- [ ] T033 [P] Run `AGENTS_LIVE=1 AGENTS_MCP_HELPER=<path to agentsd> swift test --package-path Packages/AgentsKit --filter Live` and record what each runtime did against SC-001, SC-002 and SC-003 in the Live suite's doc comment
- [ ] T034 [P] Walk [quickstart.md](./quickstart.md) §4 by hand in the built app: send one prompt, read the transcript and confirm it holds your words and nothing else, ask for something recurring and confirm the approval comes up, ask something with two real answers and confirm the question is still waiting after the window is closed and reopened
- [ ] T035 [P] Delete the `outgoing.append` in `beginTurn` on a scratch branch, run the suite, and confirm every feature the briefing names still works when driven by hand (FR-017). Restore it. This is the claim that the briefing makes things happen on their own rather than being what makes them possible, and it is worth checking once rather than believing
- [ ] T036 [P] Check the spec's Assumptions still hold after the work: no per-project or per-agent variation crept in, nothing is stored, and no line names a tool an agent might not have

---

## Dependencies

- **Phase 1 → Phase 2**: the files exist before they are filled.
- **Phase 2 → everything**: `Briefing.lines`, `Briefing.text` and `needsBriefing` are what every later phase adds to. Phase 2 is also the only phase that touches the daemon, and it is a pure rename-and-move that can land on its own.
- **Phase 3 (US1)** needs only Phase 2.
- **Phase 4 (US2)** needs only Phase 2, and is independent of Phase 3 — different line, different test, same list. A second pair of hands can take it in parallel, landing the `lines` edit last to avoid two hands in one array.
- **Phase 5 (US3)** needs Phases 3 and 4, because the ceiling is only meaningful once there is something to measure.
- **Phase 6 (US4)** needs Phase 2 and nothing else; it can run alongside Phases 3–5.
- **Phase 7** is last by definition, and T033 needs every line in place to be worth the money.

## Parallel opportunities

- T002, T003 together after T001.
- T015 and T016 together; T021, T022, T023 together.
- Phase 4's line work (T018–T020) alongside Phase 3's, if two people are on it.
- T028, T029, T030 alongside anything in Phases 3–5.
- T033, T034, T035, T036 together at the end.

## Implementation strategy

**Phase 2 alone is worth landing.** It changes no behaviour, and it turns one constant into the shape everything else needs. If the rest of this is put down for a month, that is the piece that should still be in.

**MVP is Phase 3.** The escalation line is the one with a cost attached: a suggestion that never appears is a missed convenience, but a guess is work done wrong, sometimes irreversibly, and the machinery to have prevented it already exists.

**Then Phase 4**, which is the reversal, and which should not be landed without T023's second test — the run that proves an agent given ordinary work still creates nothing.

**Then Phase 5**, which is mostly about the two features already queued behind this one. It is cheap, and skipping it is how 014 and 015 end up editing this file at cross purposes.

**Phase 6 can go anywhere.** It is the half that is already true; the tests are there to keep it true.
