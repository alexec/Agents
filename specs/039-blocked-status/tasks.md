# Tasks: An Agent Can Say It Is Blocked, and Carries On When the Block Clears

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/finish-turn-blocked.md](contracts/finish-turn-blocked.md), [quickstart.md](quickstart.md)

**Tests**: Included. This repo tests every daemon behaviour, and the quickstart names each
property to test. Model the integration tests on
`Pkg/Tests/AgentsKitTests/Integration/FinishTurnTests.swift` and `HelperAgentTests.swift`, which
already drive `finishTurn` and `startHelper` through a bound app token with a fake runtime.

**Where**: Everything is done in the worktree `.agents/worktrees/039-blocked-status` on branch
`039-blocked-status`. Never edit the shared checkout. `Pkg/` stands for `Packages/AgentsKit/`.

**Glossary**: The *blocked agent* is the one that reported `blocked`. A *wait* is one agent it
waits on. The block *clears* when it is resumed or dropped.

## Phase 1: Setup

- [X] T001 Merge `main` into `039-blocked-status` (main has moved past the spec commit). Run `swift test` in `Pkg/` once and write down which tests fail before any change. The suite is flaky under load, so a later failure is only this lane's if it is new.

---

## Phase 2: Foundational (blocks every story)

The model, the grouping and the state table. Nothing behaves differently yet.

- [X] T002 [P] Add `case blocked` to `WorkOutcome` in `Pkg/Sources/AgentsKitCore/Model/WorkOutcome.swift`: `needsAPerson` false, `heading` "Blocked", with a doc comment in the file's voice ("Waiting on something other than the person"). Update the type's doc comment ("Five values" → six).
- [X] T003 [P] Create `Pkg/Sources/AgentsKitCore/Model/Block.swift` with `Block { waits: [Wait], checkAgainAt: Date?, clearedAt: Date?, clearedBy: Clearing? }`, `Clearing { waits, time, dropped }`, `Wait { agentID: UUID, nameAtReport: String, ending: WaitEnding? }` and `WaitEnding { at: Date, how: How }` where `How` is `.finished(outcome: WorkOutcome?, message: String?)`, `.stopped(EndedReason?)`, `.archived` or `.gone`. All `Codable, Hashable, Sendable`. Add `isOpen`, `allWaitsClosed`, `isDue(now:)` and `shouldResume(now:)` exactly as data-model.md defines them ("isOpen && ((!waits.isEmpty && allWaitsClosed) || isDue(now))"), and `static let checkAgainMinutes = 1...1440`.
- [X] T004 In `WorkOutcome.swift`, give `WorkReport` `public var block: Block?` (optional, encoded only when present). Write `WorkReport.init(from:)` by hand so that an `outcome` this build doesn't know throws a distinct error. In `Pkg/Sources/AgentsKitCore/Model/Agent.swift`, decode `report` with `try?` so that error makes `report` nil and leaves the rest of the record intact (research R8).
- [X] T005 [P] Tests in `Pkg/Tests/AgentsKitTests/Unit/WorkOutcomeTests.swift`: `.blocked` round-trips as `"blocked"` and is not `needsAPerson`. A report with a block round-trips. An `Agent` JSON with `report.outcome = "someday"` decodes with `report == nil` and its title intact.
- [X] T006 [P] Create `Pkg/Tests/AgentsKitTests/Unit/BlockTests.swift`: `shouldResume` for no waits and no time (never), all waits closed (yes), one open (no), due with waits open (yes), and cleared (never).
- [X] T007 In `Pkg/Sources/AgentsKitCore/Model/AgentGroup.swift`: add `case blocked` (title "Blocked") and set `live = [.needsAttention, .blocked, .running, .finished, .stopped]`. In `init(for:wantsEyes:report:outcomeAsked:)`, for the `.finished` arm and the `.running where outcomeAsked` arm: eyes or `needsAPerson` → `.needsAttention`; else `report?.outcome == .blocked && report?.block?.isOpen != false` → `.blocked`; else `.finished`. Update the doc comment. Make the `CodingKeyRepresentable` counts decode tolerate unknown keys: in `DaemonAPI.ProjectSummary.init(from:)` (`Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`), decode `[String: Int]` and map it through `AgentGroup(rawValue:)`, dropping any key it doesn't know.
- [X] T008 [P] Extend `Pkg/Tests/AgentsKitTests/Unit/AgentGroupTests.swift` (and `OneGroupingTests.swift`, if it exhausts the table): finished + blocked-open → `.blocked`, finished + blocked-cleared → `.finished`, finished + blocked + eyes → `.needsAttention`, stopped/archived + blocked → `.stopped`/`.archived`, running + blocked (being resumed) → `.running`. `live` order. Counts JSON with `"someday": 1` decodes.
- [X] T009 In `Pkg/Sources/AgentsKitCore/Model/AgentState.swift`, add `AgentEvent.stoppedWaiting(byAgent: Bool)` (or two cases, `stoppedWaitingByUser` / `stoppedWaitingByAgent`, if the enum has no associated values). Accept it only from `.finished` → `.stopped`, with ending `.set(.stoppedByUser)` or `.set(.stoppedByAgent)` and `clearsPickUpCount: true`. Refuse it everywhere else. Add rows to `Pkg/Tests/AgentsKitTests/Unit/AgentStateTests.swift`.
- [X] T010 [P] In `Pkg/Sources/AgentsKitCore/UI/StatusShape.swift`, add `case blocked` (symbol `"hourglass"`, not `wantsAPerson`). `.finished` with outcome `.blocked` → `.blocked`. Update the "four shapes" comments. Extend `StatusShapeTests.swift`.

**Checkpoint**: `swift test` gives the T001 results plus the new passes. Both schemes build (fix every exhaustive `switch` over `WorkOutcome`, `AgentGroup` and `StatusShape` in App/ and Remote/).

---

## Phase 3: User Story 2 — Blocked is not the person's to-do list (P1). UX gate

Built before the daemon logic, to settle the look first (memory: settle the UX before building depth).

**Goal**: A blocked agent sits in its own group, with its reason and its waits on the row, outside every Needs attention count.

**Independent test**: On a scratch daemon, with a blocked report written into an agent record by hand, the Blocked section appears between Needs attention and Working, and the project's count doesn't include it.

- [X] T011 [P] [US2] In `Pkg/Sources/AgentsKitCore/Model/Block.swift`, add display wording shared by both apps: `func waitLine(name: String, ending: WaitEnding?) -> String` ("‹name› — still working" / "‹name› — finished: ‹outcome heading›" / "— stopped" / "— archived" / "— gone"), `func checkAgainLine(now:) -> String?` ("Checks again at 14:25"), and `static let carryOnPrompt = "I've cleared the block you were waiting on. Carry on."` In `Pkg/Sources/AgentsKitCore/Client/AgentsModel.swift`, add `func waitName(_ wait: Wait) -> String`, which returns the agent's current title or falls back to `nameAtReport` (FR-010: "that agent's current name").
- [X] T012 [US2] Mac row in `App/Sources/AgentList/AgentRow.swift`: when `agent.report?.outcome == .blocked` and the block is open, draw under the message one `.appText(.fine)` `.secondary` line per wait using `waitLine`, the `checkAgainLine` if there is one, and a small bordered **Carry on** button. `StatusIcon.description` already says "Blocked" through `heading`. Add a `send(_:to:)` for a given agent id to `App/Sources/AppModel.swift` if one doesn't exist, and have Carry on call it with `Block.carryOnPrompt`. Also add Carry on to the row's context menu.
- [X] T013 [P] [US2] Phone card in `Remote/Sources/Projects/AgentCard.swift`: the same wait lines and check-again line. Carry on goes in a `.contextMenu` on the card, and in the chat's top bar or menu where Stop sits (find it in `Remote/Sources/Chat/`), calling `model.send(Block.carryOnPrompt, to:)`. Keep the card itself as the button (memory: SwiftUI card taps). Update `StatusIcon.words` and the card's accessibility label to include the wait lines.
- [X] T014 [P] [US2] Add a blocked agent with two waits (one closed) to `Remote/Sources/Preview/Canned.swift`, so the canned previews and screenshots show the Blocked section.
- [X] T015 [US2] UX gate: build the Agents scheme and use the `run-app` skill on a scratch root. Write a blocked report with two waits into one agent's record in the scratch store before launch, and a `needs_answer` report into another. Screenshot the project page. Check: Blocked sits between Needs attention and Working, the row shows the message, the wait lines and Carry on, and the sidebar's Needs attention mark counts only the other agent. Put the screenshot path in this task's notes.
  - *Done 2026-09-24:* `shots/ux-gate-mac.png`. Blocked sits between Needs attention and Working, with the message, one line per wait, the check-again time and Carry on. `projects/list` counts `needsAttention: 1, blocked: 1`, and `attention/pending` lists only the parser agent. The phone's card and toolbar are built (Remote builds) but not seen; that look is Alex's.

**Checkpoint**: The look is settled. No daemon behaviour exists yet.

---

## Phase 4: User Story 1 — An agent waits for its helpers and carries on when they finish (P1) 🎯 MVP

**Goal**: `finish_turn(blocked, waiting_on: [...])` is accepted or refused per the contract, waits close as agents end, and one app prompt resumes the agent.

**Independent test**: A parent blocks on two fake-runtime helpers. After the first ends, nothing is sent. After the second, exactly one `.app` prompt goes out naming both outcomes and messages, and the parent is running.

- [X] T016 [US1] Create `Pkg/Tests/AgentsKitTests/Integration/BlockedTests.swift`: two helpers, one resume (quickstart §1 "Two helpers, one resume"). Both helpers finishing in one actor turn still gives one resume. A helper that ends `needs_answer` closes the wait, and the helper is also in `needs()`. A silent helper closes the wait only after the app's question turn ends. A blocked agent whose waits all close before its own turn ends is resumed when its turn ends.
- [X] T017 [US1] In the same file, a refusal test for every row of contract §2, each asserting that nothing was written: unknown name (the message lists agents as `id: "title"`), ambiguous title, another project's id, itself, stopped target, archived target, finished target with a `done` report, a circle A→B→caller, and minutes 0 and 1441. Plus acceptances: a finished target whose own report is an open block, and a target by exact title with different case.
- [X] T018 [US1] In `Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, add `waitingOn: [String]?` and `checkAgainInMinutes: Int?` to `FinishTurnRequest` and `ReportOutcomeRequest`, both optional with nil defaults in the memberwise inits.
- [X] T019 [US1] Create `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Blocks.swift` with these functions:
  - `func resolveWaits(_ written: [String], for caller: Agent) throws -> [Wait]`: UUID first, then exact case-insensitive title among the project's non-archived agents. Apply the refusal rules of contract §2, using research R3 for "already ended".
  - `func circle(from caller: UUID, through targets: [UUID]) -> [UUID]?`: DFS over the open waits of the project's open blocks, leaving out the caller's own current block (research R4).
  - `func closeWaits(on agentID: UUID, how: WaitEnding.How)`: for every agent whose report has an open block with an open wait on `agentID`, set `ending` and call `changed`. Return the ids of the agents it touched.
  - `func resumeIfCleared(_ agentID: UUID, now: Date) async`: guard that the agent is `.finished`, the outcome is `.blocked`, `block.shouldResume(now:)` holds and `queuedPrompts` is empty. Then, with no `await` before it, set `clearedAt`/`clearedBy`, insert `QueuedPrompt(text: resumeText, from: .app)` and call `changed(agent)`. Then send (see T024).
  - The resume text, in `Block.swift` as `func resumePrompt(message:names:now:) -> String`, matching research R10.
- [X] T020 [US1] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift`, give `checkedReport` `waitingOn`/`checkAgainInMinutes` parameters. After the existing checks, if the outcome is `.blocked`, check the range, call `resolveWaits` and `circle`, and build `report.block`. If the outcome isn't blocked and either field is present, refuse ("waiting_on and check_again_in_minutes only go with blocked"). Have `finishTurn` and `reportOutcome` pass them through. In `land`, return the accepted note from contract §2 for blocked.
- [X] T021 [US1] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore.swift` `move(_:on:)`, after the state write and beside the workflow block, work out the wait ending: `.finished` (not `willAskForOutcome`, and report not an open block) → `.finished(report?.outcome, report?.message)`; `.stopped` (not `foundDead` about to be picked up) → `.stopped(endedReason)`; `.archived` → `.archived`. Call `closeWaits`, then `await resumeIfCleared` for each agent touched. Also, when `next == .finished`, `await resumeIfCleared(agentID)` for the agent itself.
- [X] T022 [US1] In `Pkg/Sources/AgentsKit/ACP/Serve/AppService.swift`: add `"blocked"` to both enums (`finishTurnTool`, `reportOutcomeTool`), add the `waiting_on` and `check_again_in_minutes` properties, and add the description paragraph from contract §1. Update `unknownOutcome`'s list. The handler reads the two arguments and applies contract §1's local checks. `FinishSink` and `OutcomeSink` gain the two values. Extend `Pkg/Tests/AgentsKitTests/Unit/AppServiceTests.swift`: the schema has them, and a relayed call carries them.
- [X] T023 [US1] In `Daemon/Sources/main.swift`, pass `waitingOn` and `checkAgainInMinutes` into both relayed requests.
- [X] T024 [US1] Resume failure (FR-018, research R7). In `resumeIfCleared`, call `sendNextQueued` in `do/catch`. If it throws, or if afterwards the resume prompt is still first in the queue and nothing is in flight, remove that prompt, set `report = WorkReport(outcome: .stuck, wire: "Could not carry on after the block cleared: ‹reason›")`, call `changed` and `reconsider()`. Test in `BlockedTests.swift` with a runtime that fails to start, and with the per-agent cost limit reached.

**Checkpoint**: The MVP. Quickstart §3 step 2 can be run.

---

## Phase 5: User Story 3 — The person can unblock it by hand (P2)

**Goal**: A person's prompt, Carry on, Stop and Archive each end the block, and nothing is sent later.

**Independent test**: Block a parent on a running helper, prompt the parent, then finish the helper. The parent runs the person's prompt, and nothing more is sent.

- [X] T025 [US3] Tests in `BlockedTests.swift`: after a person's prompt, a later finish sends nothing (this already holds through `report = nil` in `enqueue`, so assert it). Carry on through `agents/prompt` with `Block.carryOnPrompt` behaves the same. Stop on a finished blocked agent moves it to `.stopped` with `.stoppedByUser`, and a later helper finish sends nothing. Archive does the same and never un-archives. `stop_agent` from the starter uses `.stoppedByAgent`.
- [X] T026 [US3] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` `stop(_:by:)`: if the report has an open block, mark it `clearedBy: .dropped` with `clearedAt` and call `changed` first. Then, if the agent is `.finished`, `move` on `stoppedWaiting` for the cause. In `archive(_:by:)`, mark it dropped before the move. Make `AppModel.canStop` (and the phone's equivalent) true for a finished agent whose block is open, so Stop is offered on its row.
- [X] T027 [US3] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Helpers.swift` `stopHelper`, a finished-but-blocked helper is stoppable (today it says "nothing to stop"). `helperStatus` says "blocked: ‹message›" for one.

---

## Phase 6: User Story 4 — Blocked on something the app can't see, with a time to check again (P3)

**Goal**: `check_again_in_minutes` resumes it once, at the time, even after sleep or a restart.

**Independent test**: Drive `tickWorkflows(now:)` past `checkAgainAt`. Exactly one resume, and the prompt says the time came and repeats the message.

- [X] T028 [US4] Tests in `BlockedTests.swift`: a block with only a time resumes on the first tick past it and not on the next. Waits and a time: whichever comes first resumes, and the prompt says which. A block with no waits and no time is never resumed by ticks. Out-of-range minutes are refused (covered by T017).
- [X] T029 [US4] Add `func resumeDueBlocks(now: Date) async` to `DaemonCore+Blocks.swift`, calling `resumeIfCleared` for every finished agent with an open, due block. Call it from `tickWorkflows(now:)` in `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`, after the wakefulness read and before the `guard let since`, so the first tick after a start already checks.
- [X] T030 [US4] Restart (FR-020). Add `func resumeBlocksAfterRestart() async` to `DaemonCore+Blocks.swift`. First, close any wait whose agent is missing (`.gone`) or already ended but still open. Then drain any finished agent whose first queued prompt is `.app` and whose block `clearedAt` is set (a resume queued before the crash). Then `resumeDueBlocks(now: Date())`. Call it from where `Daemon.start()` calls `pickUpAfterRestart` (`Pkg/Sources/AgentsKit/Daemon/Daemon.swift`), after that call. Tests: rebuild the core from a store with a cleared-by-waits block and its prompt queued, which gives one send. Then with an open block whose helper record is now `stopped`, which gives one resume.

---

## Phase 7: Polish and proof

- [X] T031 [P] Update the `Agent.needsAPerson` and `AgentGroup` doc comments, and any count/notification doc that says "five outcomes", so the comments say what the code does.
- [X] T032 Run the full `swift test`, and compare it with T001's failures (run twice more if something new fails, per memory: the suite is flaky under load). Then build both schemes, one after the other, with `-skipPackagePluginValidation -skipMacroValidation`.
- [X] T033 Quickstart §3 steps 2–6 on a scratch daemon with the `run-app` skill, with screenshots of blocked, one of two finished, and resumed. Record what ran and what didn't.
  - *T033 done 2026-09-24, real Claude agents on a scratch daemon, driven over the socket (Alex was at the keyboard, so no clicks):* a lead started two helpers and ended blocked on both ids. Both helpers ended blocked themselves, with a time to check again, on their own background `sleep`. `shots/e2e-three-blocked.png` shows all three under Blocked, with live wait names and Carry on. Carry on for both helpers was sent as the person over the socket, not by pressing the button. Both reported done, and the lead got exactly one prompt from the app naming each helper, its outcome and its message, then finished done. **Finding:** the helpers' background commands were killed when their turns ended (the runtime is let go), so the tool description now tells agents never to block on a command of their own. Not run live: the check-again firing (covered by `theTimeResumesItOnceOnTheHeartbeat`), refusals (`everyRefusalWritesNothingAndSaysWhy`, `aCircleIsRefused`) and the phone look (Alex's).
- [X] T034 Commit on `039-blocked-status` with the attribution line. Don't merge into main until Alex says it's this lane's turn (memory: main checkout is only main).

---

## Dependencies

- T001 → Phase 2 → Phase 3 (UX gate) → Phase 4 → Phases 5 and 6 (these two are independent of each other) → Phase 7.
- Within Phase 2: T002/T003 → T004 → T007; T009 and T010 are independent.
- Within Phase 4: T018 → T019 → T020/T021 → T024. T022 → T023.

## Parallel examples

- Phase 2: T002, T003, T006, T010 touch different files.
- Phase 3: T013 and T014 (Remote) alongside T012 (Mac).
- Phase 5 and Phase 6 can go in either order.

## Implementation strategy

MVP is Phases 1–4: an agent waits on its helpers and carries on alone, shown in its own group.
US3 is next, because the person must always be able to say "stop waiting". US4 is last.
