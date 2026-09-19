---
description: "Task list for A Restarted Background Service Picks Up the Chats That Were Working"
---

# Tasks: A Restarted Background Service Picks Up the Chats That Were Working

**Input**: Design documents from `/specs/011-restart-running-chats/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included. `quickstart.md` names every case. This feature is almost entirely about what happens when the daemon is killed, which no amount of clicking reproduces reliably — and two of its rules (the pick-up limit, the withdrawal on stop) work by *refusing* to act, so they are only demonstrable by test.

**Already built**: Commit `054f099` shipped the core of User Stories 1–3. Tasks it already satisfies are marked `[X]` with a note, so implementation does not redo them. Everything unchecked is genuinely outstanding.

**Organization**: Grouped by user story, in the priority order the spec sets. Each phase is shippable without the next.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US5)

## Path Conventions

An existing Swift package plus a macOS app and an iOS remote. The line between the two source roots is the one `Package.swift` already draws:

- `Packages/AgentsKit/Sources/AgentsKitCore/` — everything both platforms can hold. No `Process`, no `posix_spawn`, no PTY.
- `Packages/AgentsKit/Sources/AgentsKit/` — the Mac's half: the daemon, the stores, the runtimes.
- `App/Sources/` — the SwiftUI Mac app. `Remote/Sources/` — the iOS remote.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration}/` — Swift Testing.

---

## Phase 1: Setup (Baseline)

**Purpose**: Establish that the existing recovery behaviour passes before anything is changed, so a regression in it is visible rather than inferred.

- [X] T001 Run `swift test --package-path Packages/AgentsKit --filter DaemonTests` and confirm the four existing recovery cases in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift` pass: `anAgentFoundDeadOnStartUpIsSaidToBeStopped`, `anAgentFoundDeadOnStartUpIsPickedBackUpAndToldWhy`, `anAgentWaitingOnAnAnswerIsToldItsQuestionWentWithTheDaemon`, `anAgentWhoseRuntimeHasGoneIsLeftAloneWithAnExplanation`
- [X] T002 Read `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift` end to end before editing it. The doc comments on `recover()` and `pickUpAfterRestart(_:)` state the two ordering rules this feature must not break — nothing may be marked live before the socket opens, and nothing may be picked up before it does — and `Daemon.start()` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/Daemon.swift` is where that ordering is enforced

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The one persisted field, the one pure rule, and the API vocabulary. US2 and US4 both need all of it.

**⚠️ CRITICAL**: No US2 or US4 work can begin until this phase is complete. US1, US3 and US5 do not depend on it.

### The record

- [X] T003 Add `public var restartPickUps: Int` to `Agent` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`, documented as "How many times in a row this chat has been picked back up after the daemon went, without a turn since reaching its own end. On the record and not in memory because the event it counts is the daemon dying." Add `restartPickUps` to the `CodingKeys` enum (line 154) so it is not swept into `unknownFields`, decode it as `try c.decodeIfPresent(Int.self, forKey: .restartPickUps) ?? 0` with a comment in the style of the `startedByWorkflow` one above it, and encode it only when non-zero, following the `if !costToDate.isEmpty` precedent. Default it to `0` in the memberwise initialiser
- [X] T004 Add the pure rule `public var mayBePickedUpAfterRestart: Bool` to `Agent` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`: `state == .stopped && endedReason == .daemonGone && restartPickUps == 0`. The threshold is one, because FR-016 says "not picked back up a second time in a row". Depends on T003
- [X] T005 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentPickUpTests.swift` exhausting `mayBePickedUpAfterRestart` over every `AgentState` × every `EndedReason` × `restartPickUps ∈ {0, 1, 2}`, following the exhaustive style of `Unit/AgentGroupTests.swift`. Depends on T004
- [X] T006 [P] Add a round-trip test to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/` asserting that an `Agent` JSON object written without a `restartPickUps` key decodes as `0` and does not gain the key in `unknownFields`. Depends on T003

### The vocabulary

- [X] T007 [P] Add `public static let agentsResuming = "agents/resuming"` to `DaemonAPI.Method` and `public static let agentResuming = "agent/resuming"` to `DaemonAPI.Notification` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, beside `agentsList` and `agentShowFile` respectively
- [X] T008 [P] Add `ResumingNotification` (`agentID: UUID`, `isResuming: Bool`) and `ResumingResponse` (`agentIDs: [UUID]`) to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, in the `// MARK: Notifications` section beside `ShowFileNotification`. Document `isResuming` as "True when the chat has joined the queue to be picked back up, false when it has left it — whether because its prompt went, because it could not be sent, or because the person stopped it first"

---

## Phase 3: User Story 1 — The work you left running is still running (P1) 🎯 MVP

**Goal**: A chat that was mid-turn when the daemon went is working again, in the same conversation, without anybody typing.

**Independent test**: Start a long job, `kill -9` the daemon, reopen the app, and watch it carry on by itself.

- [X] T009 [US1] `recover()` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift` marks every `holdsRuntime` chat `.stopped` with `endedReason == .daemonGone` before the socket opens, and remembers what each was doing in `interrupted` — **shipped in `054f099`**
- [X] T010 [US1] `pickUpAfterRestart(_:)` sends each chat an ordinary `prompt`, which starts the runtime and continues the conversation — **shipped in `054f099`**
- [X] T011 [US1] `resuming` holds the daemon open through `isHoldingAgents` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Lifetime.swift`, so an idle daemon cannot exit out from under a chat that has no runtime yet (FR-010) — **shipped in `054f099`**
- [X] T012 [US1] Sort the ids `recover()` returns in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift` by `lastActivityAt`, most recent first. It currently iterates `for (id, agent) in agents` — a Swift `Dictionary`, whose order is unspecified — while `pickUpEachInTurn`'s comment already promises "in the order they were found". Update that comment to say what the order now actually is and why: with one-at-a-time pick-up, the chat the person most recently left running should not wait behind every runtime ahead of it
- [X] T013 [P] [US1] Add `severalInterruptedAgentsAreAllPickedBackUp` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: save three `.running` agents, `pickUpAfterRestart(await core.recover())`, expect three launches on `FakeLauncher` and all three reaching `.finished` (FR-003)
- [X] T014 [US1] Add `theyComeBackMostRecentlyActiveFirst` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: three agents with staggered `lastActivityAt`, asserting the order `FakeLauncher` saw them. Depends on T012
- [X] T015 [P] [US1] Add `agentsComingBackHoldTheDaemonOpen` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: with a pick-up pending and `connectionCount == 0`, assert `shouldExit` is false (FR-010)

**Checkpoint**: US1 is complete and shippable. This is the MVP.

---

## Phase 4: User Story 2 — Nobody is told anything untrue (P2)

**Goal**: The person sees a chat that is coming back as coming back; the agent is told its turn was cut off and to check its own work.

**Independent test**: Interrupt a chat, reopen, and read it from the top — the break, the reason, and the app's own voice explaining it, all before it starts working.

**Depends on**: Phase 2 (T007, T008).

### What the agent is told — already true

- [X] T016 [US2] `wordsAboutTheRestart(_:)` tells the agent the app restarted, its turn was cut off, and to check what it had actually finished rather than assume its last step worked (FR-004), with a distinct line for a chat that was holding a question open (FR-005), both bracketed so the app's voice is distinguishable from the person's (FR-006) — **shipped in `054f099`**
- [X] T017 [US2] `recover()` writes `"This agent was working when the daemon stopped, so it stopped too."` into the transcript at the point of the break (FR-007) — **shipped in `054f099`**

### What the person sees — outstanding

- [X] T018 [US2] Broadcast `agent/resuming` from `pickUpAfterRestart(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift`: `isResuming: true` for every id in the batch *before the first pick-up begins*, so a window shows the whole batch at once rather than one row at a time, and `false` from `pickUpEachInTurn` as each id leaves `resuming`. Use the existing `broadcast(_:_:)` on `DaemonCore`. Depends on T007, T008
- [X] T019 [US2] Handle `DaemonAPI.Method.agentsResuming` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift` beside `agentsList` (line 95), returning `ResumingResponse(agentIDs: Array(resuming))`. Ordering is not meaningful. Depends on T007, T008
- [X] T020 [US2] Add `public private(set) var resuming: Set<UUID> = []` to `AgentsModel` in `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift` beside `filesToShow` (line 44), fed by a new `case DaemonAPI.Notification.agentResuming` in `apply(_:_:)` alongside the existing `agentShowFile` case. Add `public func isComingBack(_ agent: Agent) -> Bool { resuming.contains(agent.id) }`, and clear a chat's entry wherever `filesToShow.removeValue(forKey:)` is called (line 203) so a deleted chat leaves nothing behind. Depends on T008
- [X] T021 [US2] Seed `resuming` on connect in `App/Sources/AppModel.swift`, in the same path that already calls `DaemonAPI.Method.permissionsPending` (line 426) and `elicitationsPending` (line 393). A method-not-found from an older daemon must be treated as an empty set, not a failed connection
- [X] T022 [P] [US2] Seed `resuming` on connect in `Remote/Sources/RemoteModel.swift`, beside the existing `permissionsPending` call (line 173), with the same older-daemon tolerance. Add the method to `Remote/Sources/Preview/FakeDaemon.swift` (line 66) so previews do not break. Depends on T020
- [X] T023 [US2] Show `Coming back after a restart` in `AgentRow.description` in `App/Sources/AgentList/AgentRow.swift` (the switch at line 59) when `model.isComingBack(agent)`, taking precedence over the `.stopped` case and over `agent.currentStep`. Give it its own `StatusIcon` symbol, distinct from both `stop.circle` and `circle.dotted`. **Do not** change `AgentGroup` — the chat stays under "Stopped" until its prompt lands and its own state moves it to "Working"; claiming a turn is in flight when none is would be the app lying in the other direction. Depends on T020
- [X] T024 [P] [US2] Show the same words and the same icon in `AgentCard` in `Remote/Sources/Projects/AgentCard.swift` (the switches at lines 53 and 111), so the phone and the window say the same thing about the same chat (FR-018). Depends on T020
- [X] T025 [P] [US2] Show the same words at the head of an open chat in `App/Sources/Chat/Transcript.swift` (line 565) and `Remote/Sources/Chat/EntryView.swift` (line 236), so the row and the chat itself agree. Depends on T020
- [X] T026 [P] [US2] Add `anAgentOnItsWayBackUpIsBroadcastAsResuming` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: collect broadcasts through a stub, assert `isResuming: true` arrives for every id before the first launch and `false` after each. Depends on T018
- [X] T027 [P] [US2] Add `aWindowConnectingLateIsToldWhatIsStillComingBack` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: call `agents/resuming` mid-batch, expect exactly the ids not yet picked up. Depends on T019
- [X] T028 [P] [US2] **Done differently, and better.** No test target reaches `App/` or `Remote/`, so a test could not have asserted this. Instead the drift is impossible: `AgentsModel.comingBackDescription` and `AgentsModel.comingBackSymbol` are the one copy of the words and the symbol, and `AgentRow`, `AgentCard`, `Transcript` and `RemoteChatView` all read them. There is no second switch to drift from

**Checkpoint**: US1 and US2 both work independently.

---

## Phase 5: User Story 3 — A chat that cannot come back says so (P3)

**Goal**: A pick-up that fails leaves the chat stopped, explains itself in plain words, and leaves nothing primed to happen later.

**Independent test**: Interrupt a chat, make its runtime unavailable, reopen — it stays stopped with a readable reason, and a later message carries nothing left over.

- [X] T029 [US3] `pickUp(_:)`'s `catch` records `"Could not pick this agent back up: \(why) Send it a message to pick it up yourself."` and leaves the chat stopped (FR-013) — **shipped in `054f099`**
- [X] T030 [US3] The same `catch` removes the restart words from `queuedPrompts` rather than deferring them, because "an agent told next week that the app has just restarted is being told something untrue" (FR-014) — **shipped in `054f099`**
- [X] T031 [US3] `pickUpEachInTurn` awaits each `pickUp` in a loop that does not rethrow, so one failure does not stop the rest (FR-015) — **shipped in `054f099`**
- [X] T032 [P] [US3] Add `oneFailureDoesNotStopTheRest` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: three interrupted agents, the middle one on a runtime `RuntimeDiscovery` cannot find; assert the other two still reach `.finished` and the middle one carries its explanation (FR-015)
- [X] T033 [US3] Broadcast `isResuming: false` for a chat whose pick-up threw, in `pickUp(_:)`'s `catch` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift`, so a window does not leave it reading "Coming back" forever. The contract in `contracts/daemon-api.md` guarantees every `true` is eventually followed by a `false`. Depends on T018

**Checkpoint**: US1–US3 work independently.

---

## Phase 6: User Story 4 — No stampede, no loop (P4)

**Goal**: Chats come back one at a time, and a chat that is itself killing the daemon stops being picked back up.

**Independent test**: Interrupt several at once and watch them return in sequence. Separately, prove in test that a chat cut off twice in a row is left alone the third time.

**Depends on**: Phase 2 (T003, T004).

### The stampede — already handled

- [X] T034 [US4] `pickUpEachInTurn` awaits each pick-up in turn, because "half a dozen runtimes starting at once is half a dozen node processes, and a Mac that notices" (FR-009) — **shipped in `054f099`**
- [X] T035 [US4] `pickUpAfterRestart(_:)` returns at once and works behind itself, and is called last in `Daemon.start()` after the socket is open, so a window watches chats come back rather than connecting to find it over (FR-008) — **shipped in `054f099`**
- [X] T036 [P] [US4] Add `theyAreStartedOneAtATime` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: have `FakeLauncher` record entry and exit times per launch and assert no two overlap (FR-009)

### The loop — outstanding

- [X] T037 [US4] In `pickUp(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift`, increment `restartPickUps` and persist it **before** `prompt` is called, never after. A daemon killed part-way through starting a runtime has then already written down that it tried, and the next daemon does not try again. Use `changed(_:)`, which saves and broadcasts in that order. Depends on T003
- [X] T038 [US4] Replace the eligibility check in `pickUp(_:)` with `agent.mayBePickedUpAfterRestart`, and in `recover()` record a transcript line for each interrupted chat that fails it: `"This agent was picked back up after the last restart and did not get to the end of a turn, so it has been left alone this time. Send it a message to start it again."` The chat's ending stays `daemonGone` — that is what happened to it; why it was not brought back is a line in the transcript, not a different ending (FR-016). Depends on T004, T037
- [X] T039 [US4] Clear `restartPickUps` to `0` in `move(_:on:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` (line 209) whenever a turn ends for any reason other than `.daemonGone`. Any other ending — including `maxTokens` or the person stopping it — is evidence the chat can reach the end of a turn without taking the daemon with it, which is the only question the count asks. `recover()` sets `.daemonGone` directly rather than through `move`, so it can never clear the count itself (FR-017). Depends on T003
- [X] T040 [P] [US4] Add `anAgentCutOffTwiceInARowIsNotPickedUpAThirdTime` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: save an agent with `restartPickUps == 1`, `.stopped`, `daemonGone`; run recovery and pick-up; expect zero launches and the limit line in the transcript (FR-016). Depends on T038
- [X] T041 [P] [US4] Add `aTurnThatEndsClearsTheCount` and `anEndingThatIsNotAFinishAlsoClearsTheCount` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: pick one up and let it finish, then the same with a `maxTokens` ending; assert `restartPickUps == 0` and `mayBePickedUpAfterRestart` is true again in both (FR-017). Depends on T039
- [X] T042 [US4] Add `theCountIsWrittenBeforeTheWordsAreSent` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: a launcher that hangs on launch, asserting the *saved record on disk* already reads `1` while the pick-up is still in flight. This is the test that makes the guard survive a crash mid-pick-up, and the only one that catches the increment being moved after the `prompt`. Depends on T037

**Checkpoint**: US1–US4 work independently.

---

## Phase 7: User Story 5 — Only what was cut off comes back (P5)

**Goal**: Endings somebody chose stay chosen.

**Independent test**: Leave one chat of each kind, interrupt, reopen — exactly one is working.

- [X] T043 [US5] `recover()` considers only `state.holdsRuntime` chats, and `pickUp(_:)` requires `.stopped` with `daemonGone`, so finished, hand-stopped, archived and `processDied` chats are all excluded (FR-011). `processDied` is excluded on purpose: that ending was already reported to the person at the time — **shipped in `054f099`**
- [X] T044 [US5] `interrupted.removeValue(forKey:)` at the top of `pickUp(_:)` is the once-only claim, and the state and reason checks exclude a chat deleted, archived or already spoken to since (FR-012) — **shipped in `054f099`**
- [X] T045 [P] [US5] Add `onlyInterruptedAgentsArePickedBackUp` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: save one each of `.running`, `.waitingOnUser`, `.finished`, `.stopped`/`cancelled`, `.archived`; expect exactly two launches (FR-011)
- [X] T046 [P] [US5] Add `anAgentWhoseProcessDiedIsNotPickedBackUp` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: `.stopped` with `processDied`; expect no launch (FR-011)

**Checkpoint**: All five user stories work independently.

---

## Phase 8: The two cases that are easy to get wrong

**Purpose**: Two defects the existing implementation has that no single user story owns. Both are real today, and both silently do the wrong thing.

### Words queued before the crash (FR-020)

- [X] T047 Remove `agent.queuedPrompts.isEmpty` from the guard in `pickUp(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift`. Its comment means "already spoken to by somebody who got here first", but `prompt` appends *every* prompt to `queuedPrompts` including ones that go straight out, so words the person queued before the crash trip it too and that chat is never picked back up at all — silently, with nothing said. The remaining conditions already express the intent completely: `interrupted.removeValue` is the once-only claim, and any turn started since would have moved the state off `.stopped` or the reason off `daemonGone`. Update the comment to say what it now guards
- [X] T048 Deliver the restart words at the **front** of `queuedPrompts`, not the back. `prompt(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` (line 251) always appends, deliberately, "because that is what keeps the order the order it was typed in". Add an internal front-insertion path for this one caller and document why it is the exception: the queued words were typed by somebody who believed the turn was still running, and the restart words are the news that it was not. Behind them, the agent acts on instructions premised on a state that never existed and only afterwards learns it was cut off — the exact failure FR-004 exists to prevent. Depends on T047
- [X] T049 [P] Add `anAgentWithWordsAlreadyQueuedIsStillPickedBackUp` and `theRestartWordsGoAheadOfWhatWasQueued` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`, the second asserting the order `FakeLauncher` saw the two prompts (FR-020). Depends on T048
- [X] T050 [P] Confirm the `catch` in `pickUp(_:)` still finds and removes the restart words after front-insertion — it matches on `$0.text == text`, which is position-independent, but assert it in `anAgentWhoseRuntimeHasGoneIsLeftAloneWithAnExplanation`. Depends on T048

### Stopping a chat before it comes back (FR-021)

- [X] T051 In `stop(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` (line 483), remove the id from `interrupted` and from `resuming` **before any `await`** — on an actor that is the whole of the lock, and it is what makes the withdrawal race-free. Today `stop()` on such a chat is a no-op that looks like it worked: no live session, no turn task, and `state.holdsRuntime` is false because the chat is already `.stopped`, so nothing runs and the resume loop starts it seconds later. Removing it from `interrupted` alone is sufficient to stop the pick-up — `pickUp` opens with `guard let was = interrupted.removeValue(forKey: id)` — but `resuming` must go too or `isHoldingAgents` keeps a daemon alive for a chat nobody is bringing back
- [X] T052 When a pick-up was actually withdrawn by T051, record `"You stopped this agent before it was picked back up."` for that chat and broadcast `isResuming: false`. Say nothing when there was no pick-up pending — a normal stop should not gain a new line. Depends on T051, T018
- [X] T053 [P] Add `stoppingAnAgentBeforeItIsPickedUpWithdrawsIt` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift`: assert no launch for it, that it is gone from `resuming`, that the withdrawal line is in its transcript, and that `shouldExit` is not held open by it once the rest are done (FR-021). Depends on T052

---

## Phase 9: Polish & Cross-Cutting

- [X] T054 [P] Add `anOlderClientIgnoresTheResumingNotification` asserting `AgentsModel.apply(_:_:)` returns `true` for `agent/resuming` (it is claimed) and that an unknown method still returns `false`, which is the existing documented "a notification nobody claims is skipped, never guessed at" behaviour. Depends on T020
- [X] T055 [P] Update `DaemonLog` lines in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift` to cover the two new outcomes — a chat left alone at its pick-up limit, and a pick-up withdrawn by the person — matching the voice of the existing `"picked agent \(id) back up after the restart"`. Depends on T038, T051
- [X] T056 Run the full suite: `swift test --package-path Packages/AgentsKit`, then `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build`
- [ ] T057 **Outstanding.** Needs hand-driving the window and five real runtimes against a throwaway root; nothing automated stands in for it. Walk `quickstart.md` by hand against a throwaway root (`open Agents.app --args --root /tmp/agents-restart-test`), using `kill -9` — anything gentler lets the daemon shut down cleanly, which is a different code path and reproduces none of this. Confirm SC-001: five chats working, killed, reopened, and inside a minute every one is either working again or carrying a line saying why not
- [X] T058 [P] Checked: no test name or wording drifted. Update `specs/011-restart-running-chats/quickstart.md` if any test name or wording drifted during implementation, so the two do not disagree

---

## Not in this feature

**FR-019 (spending limits)** needs no task. Picking a chat back up *is* an ordinary `prompt`, so whatever gate `010-cost-limits` installs in `prompt` applies to it automatically, and `pickUp`'s existing `catch` already writes the refusal into the chat and drops the words. `010` is specified (`specs/010-cost-limits/spec.md`) and not yet built — nothing in the source mentions a limit. When it lands, add one test asserting a pick-up refused for cost reads in the chat as a refusal rather than a crash. Building a second gate here would mean two places that can refuse a pick-up, and the wrong one would be the one nobody updates.

---

## Dependencies

```
Phase 1 (Setup) ──▶ Phase 2 (Foundational)
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   Phase 4 (US2)    Phase 6 (US4)    Phase 8 (defects)
        │                                  │
        └──────────────┬───────────────────┘
                       ▼
                 Phase 9 (Polish)

Phase 3 (US1), Phase 5 (US3), Phase 7 (US5) depend only on Phase 1.
Phase 8's stop() task (T052) depends on Phase 4's broadcast (T018).
Phase 5's T033 depends on Phase 4's T018.
```

**Story independence**: US1, US3 and US5 are already shipped in substance and need only their tests. US2 and US4 are the new work and are independent of each other — the resuming indicator and the loop guard touch different files and could be built by two people at once.

## Parallel execution examples

**Phase 2, after T003–T004**: T005, T006, T007, T008 are four different files with no shared edits.

**Phase 4, after T020**: T022 (Remote seeding), T024 (AgentCard), T025 (Transcript/EntryView) are three separate view layers.

**Phase 6**: T036 (stampede test) is independent of the entire loop-guard chain and can be written first.

**Phases 3, 5 and 7 entire**: every test task in them (T013, T015, T032, T045, T046) is a new case in one test file with no production dependency, so they can all be written in parallel before any of the new work starts — and four of the five should pass immediately, which is the point of writing them.

## Implementation strategy

**MVP is already shipped.** `054f099` delivers User Story 1. The honest sequence from here:

1. **Phase 1 + the free tests** (T001, T013, T015, T032, T036, T045, T046). Half a day. It converts "we think US1, US3 and US5 work" into "they are tested", which is worth having before anything is changed underneath them.
2. **Phase 8** (T047–T053). The two defects. These are the highest value per line in the feature: one silently abandons work for the most engaged users, the other makes a Stop button do nothing. Neither is visible in any test today.
3. **Phase 6** (T037–T042). The loop guard. The only genuinely new mechanism, and the one that bounds a cost failure.
4. **Phase 4** (T018–T028). The returning indicator. The largest task count and the smallest harm if deferred — a chat that reads "Stopped" for ten seconds before it starts is untidy, not untrue.

Phases 8 and 6 both need Phase 2's field, so T003–T004 come first in practice. T052 needs T018, so if Phase 4 is deferred, ship T051 without its transcript line and add the line with Phase 4.
