---
description: "Task list for An Agent Being Born Is Not a Finished One"
---

# Tasks: An Agent Being Born Is Not a Finished One

**Input**: Design documents from `/specs/020-agent-lifecycle/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/transitions.md](./contracts/transitions.md), [contracts/record-and-wire.md](./contracts/record-and-wire.md), [quickstart.md](./quickstart.md)

**Tests**: Included, and weighted the way the feature is shaped. Three of the nine success criteria are claims about totality, refusal, and where code may write — none of which a person can see, and all of which rot silently. `applying` is pure and exhaustible, which is why the 60-pair test is the single most valuable thing in this list. Two integration suites exist for the claims a pure test cannot make: that an agent is never broadcast in the wrong group, and that a trigger fires from a daemon that has only just come back. One test is a source scan, because SC-009 is a claim about where code *may* write and there is no honest way to assert that from inside the program.

**Organization**: Grouped by user story in the spec's priority order, behind one foundational slice. Phase 2 is `Transition` with no behaviour change — it exists so US1, US2 and US3 are each small enough to review.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US3)

## Path Conventions

- `Packages/AgentsKit/Sources/AgentsKitCore/Model/` — the state, the events, the table, the record. Linked by `agentsd` as well as both apps, so it must never gain `import SwiftUI`.
- `Packages/AgentsKit/Sources/AgentsKit/{Daemon,Store}/` — the funnel, recovery, the workflow layer, and the two gates on the file.
- `App/Sources/` and `Remote/Sources/` — the ten exhaustive switches, and the two that will not break.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration}/` — Swift Testing. Neither app has a test target, so anything to be tested lives here.

---

## The decision this list is written on

`startFailed(EndedReason)` is **dropped**, and the create path is **not** reordered.

The contract made `startFailed` legal only from `starting`. But `start(_:)` makes the session at `freshSession` *before* it constructs the `Agent` at `DaemonCore+Commands.swift:149`, so when a runtime will not start there is no record yet and the error throws to the caller exactly as it does today. Between the record being written and `beginTurn`, only `prepareServing` and `session.apply` run, and neither reports a start failure. An event with no call site is the `foundDead` disease this whole feature exists to remove, and adding a second one in the act of curing the first is not a trade worth making.

Three consequences, carried here rather than left to be discovered:

- `AgentEvent` gains **one** case, not two. The table is **6 × 10 = 60** pairs, not 66.
- Spec scenario **US1-4** and quickstart **check 2** describe an agent that is never made. Phase 1 amends them rather than leaving them reading as promises the code does not keep.
- `starting` covers the window between the record being written and the first turn beginning. That is short — `prepareServing`, `session.apply`, one broadcast — but it is exactly the window in which a new agent is today listed under **Stopped**, which is the thing US1 exists to fix. What it does *not* cover is the several seconds `freshSession` takes, because the agent does not exist for those.

If the create path is ever reordered so the record is written first — which would make a slow start genuinely watchable in the list, and would give `startFailed` a real caller — that is a feature of its own with its own argument about how a start failure reaches the person. It is not this one.

---

## Phase 1: Setup

**Purpose**: Make the design documents true before anybody implements against them. An implementer reading a contract that says 66 when the answer is 60 writes the wrong exhaustion test, and the wrong exhaustion test is a green suite that proves nothing.

- [x] T001 Amend `specs/020-agent-lifecycle/contracts/transitions.md` for the dropped event: delete the `startFailed(r)` row from all six state tables; change "6 states × 11 events = **66 pairs**" to "6 states × 10 events = **60 pairs**" and the same count in rule 1; add a `turnBegun` row to every state table — `running` for `starting`, `—` for the other five; and in the `From starting` table set `turnBegun`'s archived column to **leave** rather than `clear`, noting that invariant 4 already forbids a `starting` agent from carrying an archive reason, so `clear` would imply there could have been one
- [x] T002 [P] Amend `specs/020-agent-lifecycle/data-model.md`: remove `startFailed` from the `AgentEvent` table, delete the paragraph beginning "`startFailed` carries a reason because `freshSession`…", change "6 × 11 = 66" to "6 × 10 = 60" under **Totality**, and correct the count of new events from two to one. Add a short note under `AgentEvent` recording why it was dropped, pointing at the decision section of this file
- [x] T003 [P] Amend `specs/020-agent-lifecycle/spec.md`: rewrite **FR-005** to name the three real ways out of starting — its first turn begins; the person stops it; its process dies or is found dead by the next daemon — dropping "the start fails, and it becomes stopped with the reason it failed". Rewrite **US1 acceptance scenario 4** to say what is true: a runtime that will not start means no agent is made at all, and the failure reaches the person as an error on the start, unchanged. Make **SC-003** name 60 pairs explicitly
- [x] T004 [P] Amend `specs/020-agent-lifecycle/quickstart.md`: change "SC-003 All 66 pairs decided" to 60; correct "the new state breaks 13 exhaustive switches by design" to **10**, which is the number actually in the source — 4 in `App/Sources` plus 4 in `Remote/Sources` plus `AgentGroup` and the post-transition switch in `move`; and rewrite **Doing it by hand → 2** so it says a start that fails produces no agent, and that what is being checked by eye is that the error still reaches the person exactly as it does today
- [x] T005 [P] Amend `specs/020-agent-lifecycle/plan.md`: change **Scale/Scope** from "2 new events" to "1 new event", drop "A failed start becomes `startFailed`" from the Slice 1 paragraph, and add a row to the **Things that will bite** table for `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift:149` — `wordsAboutTheRestart` switches `AgentState` with a `default:`, so it is the **second** switch that will compile silently, and the plan currently names only one
- [x] T006 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Integration/AgentBirthTests.swift` with `import Foundation`, `import Testing`, `@testable import AgentsKit`, `@testable import AgentsKitCore` and an empty `@Suite("An agent being born", .timeLimit(.minutes(1))) struct AgentBirthTests {}`, copying the temporary-root and `FakeLauncher` scaffolding from `Packages/AgentsKit/Tests/AgentsKitTests/Integration/StartResilienceTests.swift` verbatim. Its doc comment must name the claim it carries — a new agent is never broadcast in a group other than Working, not once, not for a frame — and why no pure test can make it: the flicker is a property of the *sequence* of `agents/changed` notifications, not of any single value
- [x] T007 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/LifecycleWriterTests.swift` with `import Foundation`, `import Testing` and an empty `@Suite("Only a transition writes the state") struct LifecycleWriterTests {}`, copying the repository-root discovery and `sources(under:)` helpers from `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ConsistencyTests.swift`. Its doc comment must say this is a source scan for the reason 018's are, and must repeat that suite's own warning: a regex matching nothing is a green test protecting nothing, so the scan is proved to bite before it is trusted

**Checkpoint**: The documents say what the code is going to do. Nothing is built yet.

---

## Phase 2: Foundational (Blocking Prerequisites) — Slice 0, `Transition`

**Purpose**: `applying` stops returning a bare state and starts returning everything the resulting record needs. No new state exists yet and nothing a person can see changes. This phase exists so the three stories after it are each small.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete. All three are written against the new return type.

- [x] T008 Add `ReasonChange` and `ArchiveChange` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentState.swift`: `public enum ReasonChange: Hashable, Sendable { case set(EndedReason), leave }` and `public enum ArchiveChange: Hashable, Sendable { case set(Agent.ArchivedReason), clear, leave }`. Comment why these are three-case enums rather than `EndedReason??`: the third case is real — `unarchivedByUser` leaves the ending alone and `promptSent` clears the archive reason — and a double optional is a shape nobody reads correctly twice
- [x] T009 Add `public struct Transition: Hashable, Sendable` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentState.swift` with `next: AgentState`, `endedReason: ReasonChange`, `archivedReason: ArchiveChange` and `clearsPickUpCount: Bool`, and a memberwise `init` defaulting the two changes to `.leave` and the flag to `false`. Doc-comment it as the whole of what an accepted event does to a record, and say that `nil` from `applying` still means the event must not happen in this state and that the agent is then left entirely unchanged — state, ending, archive reason, pick-up count, and when it was last active (FR-010)
- [x] T010 Change the signature in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentState.swift` to `public func applying(_ event: AgentEvent, endedReason: EndedReason? = nil) -> Transition?`, returning a `Transition` for each of the 45 currently-legal pairs with the ended and archived columns taken from [contracts/transitions.md](./contracts/transitions.md). Keep the `endedReason:` parameter and keep its current meaning — the agent's **existing** ending, read only by `unarchivedByUser` — and add a doc line saying it is no longer how a caller supplies a *new* reason, which is the whole of FR-011
- [x] T011 Set `clearsPickUpCount` inside `applying` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentState.swift` as the derived rule: `next` is settled (`finished` or `stopped`) **and** the resulting ended reason is not `daemonGone`. The comment must carry why it moved here — this is FR-015, it is one of the two reasons `recover` went round the funnel, and once `recover` goes through it the rule has to hold on its own rather than being defended by a caller that stays away
- [x] T012 Set `unarchivedByUser`'s ended column to `.set(.unrecognised)` when the passed-in existing `endedReason` is `nil`, in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentState.swift`. Comment that this pair is unreachable today — the only ways into `archived` are from `finished` and `stopped`, which both carry a reason — that it becomes reachable the moment a record is hand-edited or written by another build, and that `unrecognised` is the right word because nothing vouched for that ending
- [x] T013 Rewrite `move` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift:250` to `func move(_ agentID: UUID, on event: AgentEvent) async`: consume the `Transition`, apply `next`, apply both changes, apply `clearsPickUpCount`, set `lastActivityAt`, then `changed(agent)` and the transcript entry in the order they are in now. **Delete** the `endedReason:` parameter, the `if let endedReason` write, the whole `if next == .finished || next == .stopped` block at line 260 *including* its four-line comment about `recover` setting the reason directly, and the `if next == .archived` / `if next == .running` lines at 263–264. The plan is explicit that a comment explaining a bypass is deleted with the bypass rather than reworded
- [x] T014 Change the transcript entry written by `move` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` to `record(.stateChanged(transition.next, reason: agent.endedReason), for: agentID)` — the reason read off the agent **after** the transition, since the caller's parameter no longer exists. Note in the comment that this is the same entry `recover` writes by hand today, and that it is about to become the only one
- [x] T015 Drop the `endedReason:` argument from the four call sites that pass it: `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:670` (`.turnEnded(reason)`), `:733` (`.processDied`), `:801` (`.stoppedByUser`), and `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift:442` (`.processDied`). Line 670 passes the same value twice today, which is the plainest example of what FR-011 removes
- [x] T016 Delete the pre-write in `stop(_:)` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:~768` — the `if agent.state.hasTurnInFlight { agent.endedReason = .cancelled; agents[agentID] = agent }` block — and let the `move(agentID, on: .stoppedByUser)` at line 801 set the reason, because a write made before the table is consulted is exactly the FR-010 violation this slice closes. **Re-read its comment before deleting it**: it describes the turn unwinding on its own task, a race also guarded by `turnTasks` and `sending`, and the table already refuses a second ending
- [x] T017 In the same function, change the guard at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:800` from `if agent.state.holdsRuntime` to re-read `agents[agentID]?.state.holdsRuntime == true`. The local `agent` was captured before several `await`s and is stale by the time that line runs; it happens to work today because the pre-write kept it in step, and T016 removes that. The wider staleness in this function is out of scope per the plan — this is the one line of it that T016 makes load-bearing, and leaving it would turn a tidy-up into a stop that silently does nothing
- [x] T018 Check `drainQueue(after:)` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:~380`, which reads `agents[agentID]?.endedReason != .cancelled` to decide whether a stopped agent's queue drains. With T016, that reason now arrives only from `move`. Prove by test that it is set before `finishTurn` can reach `drainQueue`; if it is not, write the finding down here rather than leaving it to be met later — "stop means stop, and the queue stays put" is a promise a person relies on
- [x] T019 Rewrite `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentStateTests.swift` for the new return type: every `#expect(state.applying(event) == .running)` becomes an assertion on `.next`, and the `nil` assertions are unchanged. Add `theReasonComesFromTheEventAndNotTheCaller`, asserting `.stoppedByUser` yields `.set(.cancelled)`, `.processDied` yields `.set(.processDied)`, `.foundDead` yields `.set(.daemonGone)` and `.turnEnded(r)` yields `.set(r)`, commented as the four pairs a caller could previously contradict
- [x] T020 [P] Add `theDaemonGoingNeverClearsThePickUpCount` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentStateTests.swift`, exhausting `clearsPickUpCount` over every legal pair: true exactly when the next state is settled and the resulting reason is not `daemonGone`, false everywhere else. This is FR-015, and it is the rule that used to be an inline `if` no test could reach

**Checkpoint** — ✅ **reached 2026-09-19.** `swift test --package-path Packages/AgentsKit`: **850 tests in 97 suites, all passing.** The three inline special cases named in T013 are gone from `move`, and nothing a person can see has changed. See **Implementation Notes on Phase 2** at the foot of this file for four places the code settled differently from the task text.

---

## Phase 3: User Story 1 - A new agent is never a finished one (Priority: P1) 🎯 MVP

**Goal**: The state that was missing exists. A new agent is written down as `starting` with no ending, grouped with the working agents, and becomes `running` when its first turn begins — never appearing, not for a frame, under Stopped or Complete.

**Independent Test**: Record every `agents/changed` from the moment the record is written to the first turn beginning, and assert the group is `.running` throughout and `endedReason` is `nil` throughout. Then read the record written at that moment and confirm it carries no ending.

### The state, the event, and the table

- [x] T021 [US1] Add `case starting` to `AgentState` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentState.swift`, first in the declaration so `allCases` reads in lifecycle order, doc-commented as: the agent exists, a runtime is made, and its conversation has not begun. Add it to the `true` arm of **both** `holdsRuntime` and `hasTurnInFlight`, commenting why each answer is load-bearing — `holdsRuntime` because the session really is made before the record exists, so there is a process to account for and `runUntilIdle` must not exit under it; `hasTurnInFlight` because the turn it was created for is about to begin, which is what makes `enqueue` at `DaemonCore+Commands.swift:302` and `sendNextQueued` at line 324 queue a second prompt rather than race it, with no new code (FR-003, FR-004)
- [x] T022 [US1] Add `case turnBegun` to `AgentEvent` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentState.swift`, immediately after `promptSent`, commented with why it is not just `promptSent`: `beginTurn` is reached two ways — the first turn of a new agent, where the state is `starting`, and an ordinary prompt to a settled one — and keeping them apart is the only thing that lets `(.starting, .promptSent)` be refused, which is FR-004 expressed in the table rather than only in a daemon guard
- [x] T023 [US1] Add the ten `starting` rows to `applying` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentState.swift`, exactly as [contracts/transitions.md](./contracts/transitions.md) has them after T001: `turnBegun` → `running`, leave, leave, clears no; `stoppedByUser` → `stopped`, set `cancelled`, leave, clears yes; `processDied` → `stopped`, set `processDied`, leave, clears yes; `foundDead` → `stopped`, set `daemonGone`, leave, **clears no**; and `nil` for `promptSent`, `permissionAsked`, `permissionAnswered`, `turnEnded`, `archivedByUser` and `unarchivedByUser`. Comment the `promptSent` refusal with FR-004 — a prompt arriving while an agent starts joins the queue, and it is refused by the table rather than only by the daemon's guard so the rule is somewhere it can be read — and the `archivedByUser` refusal with the same words `running` gets: stop it first
- [x] T024 [US1] Add `(_, .turnBegun) → nil` for the other five states in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentState.swift`, so the case is total. One comment rather than five: a turn can only begin out of a start — from `running` it would be a second turn, and from the three settled states it would be a turn beginning with no prompt behind it
- [x] T025 [P] [US1] Add `case .starting: self = .running` to `AgentGroup.init(for:wantsEyes:report:)` at `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift:66`. One line. Do **not** give it the `wantsEyes` arm `.running` has: an agent that has not begun its conversation has not asked anybody to look at anything. No heading is added, renamed or removed (FR-006, FR-023)
- [x] T026 [P] [US1] Add `public static let startingLabel = "Starting"` to `AgentState` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentState.swift`, carrying the comment `EndedReason.summary` already has: the phone and the window have to say the same words about the same agent, and two copies of a switch are two chances to drift. Say explicitly that this is one constant and not a full `AgentState.label`, because the existing five words are **not** in fact identical across the two apps — `AgentRow` says "Waiting for your answer" where its own accessibility label says "Waiting on you" — and unifying them belongs to 018

### The record and the create path

- [x] T027 [US1] Change the `state` default in `Agent.init` at `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift:210` from `.stopped` to `.starting`, leaving `endedReason`'s default at `nil`. Doc-comment the default with FR-002: a new agent carries no ending because it has not had one, and the `endTurn` it used to be handed was simply the cheapest reason that would not print something false on the row — so the falsehood went into the record instead
- [x] T028 [US1] Add rule 4 to `isConsistent` at `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift:346`: a `starting` agent has neither an `endedReason` nor an `archivedReason`. Keep the existing three unchanged and in order, and update the property's doc comment — "in a form a test can assert" stops being the whole truth in Phase 5, when the store starts asking
- [x] T029 [US1] Delete `state: .stopped,` (line 152) and `endedReason: .endTurn,` (line 157) from the `Agent(runtimeID:…)` construction at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:149`, so the agent is made in the state the initialiser now defaults to. This is the one line of the feature a person sees with their own eyes
- [x] T030 [US1] Change `beginTurn` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:587` from an unconditional `await move(agentID, on: .promptSent)` to `.turnBegun` when the agent is `.starting` and `.promptSent` otherwise. Comment that the two arms are one moment reached from two directions, and that the reason they are not one event is the refusal in T023
- [x] T031 [US1] Guard the tail of `start(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, between `changed(agent)` at line 173 and `beginTurn` at line 175, on the agent still being `starting`: if the person stopped it in that window, `stop` has already moved it to `stopped` and let the runtime go, and beginning a turn on top of that would restart an agent they just stopped. Return the id without beginning the turn. This is the spec's "stopping an agent that is starting" edge case, and it is reachable precisely because `starting` answers true to `holdsRuntime`, which is what lets `stop` act on it at all

### The switches the compiler finds, and the two it does not

- [x] T032 [P] [US1] Answer for `.starting` in the `text` switch at `App/Sources/Chat/Transcript.swift:623`, returning `AgentState.startingLabel`. Do not tidy the surrounding switch — that is 018's
- [x] T033 [P] [US1] Answer for `.starting` in the `subtitle` switch at `App/Sources/AgentList/AgentRow.swift:78`, returning `AgentState.startingLabel`
- [x] T034 [P] [US1] Answer for `.starting` in the icon switch at `App/Sources/AgentList/AgentRow.swift:163`, returning `"circle.dotted"` — the working icon. A state that lasts a moment and is grouped under Working does not earn a symbol of its own, and one that flashed a different shape on every start would be the flicker this feature removes wearing a different coat
- [x] T035 [US1] **Visit by hand**: the `tint` switch at `App/Sources/AgentList/AgentRow.swift:177` has `default: return .none` and will compile silently, handing `.starting` whatever the default is. Confirm `.none` is the wanted answer — it is: a starting agent is neither attention nor vouched for — and leave a comment saying the default was checked against this state deliberately, so the next person adding a state knows this switch does not ask
- [x] T036 [P] [US1] Answer for `.starting` in the `description` switch at `App/Sources/AgentList/AgentRow.swift:191`, returning `AgentState.startingLabel`, so the screen reader and the tooltip say what the row says
- [x] T037 [P] [US1] Answer for `.starting` in the `text` switch at `Remote/Sources/Chat/EntryView.swift:285`, returning `AgentState.startingLabel`
- [x] T038 [P] [US1] Answer for `.starting` in the `subtitle` switch at `Remote/Sources/Projects/AgentCard.swift:70`, returning `AgentState.startingLabel`
- [x] T039 [P] [US1] Answer for `.starting` in the icon switch at `Remote/Sources/Projects/AgentCard.swift:163`, returning `"circle.dotted"`, matching T034
- [x] T040 [P] [US1] Answer for `.starting` in `words(for:outcome:isUnaccountedFor:)` at `Remote/Sources/Projects/AgentCard.swift:190`, returning `AgentState.startingLabel`
- [x] T041 [US1] Answer for `.starting` in the post-transition switch inside `move` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift:292`, in the `break` arm beside `.waitingOnUser`, `.running` and `.archived`. An agent that has started has neither finished nor stopped, so it fires nothing — and it is not `running` either, so it is named rather than folded in
- [x] T042 [US1] **Visit by hand**: `wordsAboutTheRestart(_:)` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift:149` switches `AgentState` with a `default:` and will compile silently. `recover` filters on `holdsRuntime`, which now includes `.starting`, so an agent cut off before its first turn would be told the words written for one that was working — "the turn you were in the middle of was cut off… everything above is still yours" — when it had no turn and nothing above it at all. Give `.starting` its own arm: the app restarted before its first turn began, there is no history to carry, and it should simply begin the work it was asked for

### Tests for User Story 1

- [x] T043 [P] [US1] Replace the ad-hoc coverage in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentStateTests.swift` with `everyPairingOfStateAndEventHasExactlyOneAnswer`, looping `AgentState.allCases` against a locally declared array of all ten events — `turnEnded` represented by `.endTurn` and `.refusal` so both branches are covered — and asserting each pair against a table literal transcribed from [contracts/transitions.md](./contracts/transitions.md). 60 pairs, each with exactly one expected answer, `nil` included. The test must fail if a pair is **missing** from the literal as well as if one disagrees, or a state added later slips through undecided (SC-003)
- [x] T044 [P] [US1] Add `aStartingAgentHoldsARuntimeAndOwnsItsTurn` and `aPromptArrivingDuringAStartJoinsTheQueue` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentStateTests.swift`, the second asserting `AgentState.starting.applying(.promptSent) == nil` and commented with the daemon guard it backs up (FR-004)
- [x] T045 [P] [US1] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentGroupTests.swift` so the mapping is exhausted over all six states with `.starting` asserted to be `.running`, and add a case asserting `AgentGroup.live` still holds exactly its four headings in their existing order (FR-023)
- [x] T046 [US1] Add `aNewAgentIsNeverInAGroupOtherThanWorking` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/AgentBirthTests.swift`: install a broadcaster that records every `agents/changed` payload, start an agent against `FakeLauncher`, and assert every recorded agent has `group == .running` and `endedReason == nil` from the first notification to the first turn beginning (SC-001, SC-002)
- [x] T047 [P] [US1] Add `theRecordWrittenAtBirthCarriesNoEnding` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/AgentBirthTests.swift`, reading `agent.json` off disk at the moment the record is first saved and asserting `"state": "starting"` with no `endedReason` key and no `archivedReason` key (SC-002)
- [x] T048 [P] [US1] Add `stoppingAnAgentBeforeItsFirstTurn` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/AgentBirthTests.swift`, covering T031: the agent becomes `stopped`/`cancelled`, no turn begins afterwards, and the runtime is let go rather than left running unowned
- [x] T049 [P] [US1] Add a case to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ConsistencyTests.swift` scanning `App/Sources`, `Remote/Sources` and `Shared/UI` for the literal `"Starting"` outside a comment, failing with the file and line and naming `AgentState.startingLabel`. Prove it bites by putting a literal back and watching it fail, the way that suite's own doc comment demands

**Checkpoint** — ✅ **reached 2026-09-20.** Package suite **883 tests in 101 suites, passing**; `Agents` (macOS) and `Remote` (iOS) both **BUILD SUCCEEDED**. A recorded broadcast sequence for a new agent is now exactly `starting → running → finished`, where it used to open under **Stopped**. T006 was pulled forward from Phase 1 because the birth suite needed the file. See **Implementation Notes on Phase 3** at the foot of this file.

---

## Phase 4: User Story 2 - Every ending reaches the things that watch for endings (Priority: P2)

**Goal**: The bypass is gone. `recover()` goes through the funnel like everything else, so an ending discovered on a restart writes the same record, the same transcript line, the same counts and the same triggers as any other ending.

**Independent Test**: Set a workflow to fire when an agent stops. Leave two agents working — one already picked back up once — kill the daemon, start it again. The workflow fires for the one that will not be picked back up, does not fire for the one that will, and both endings are in their transcripts.

### The deferral the ordering needs

- [x] T050 [US2] Add `var deferredLifecycleEvents: [(event: WorkflowAgentEvent, agentID: UUID, depth: Int)] = []` and `var workflowsAreStarted = false` to the workflow section of `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift:~92`. The doc comment must carry the whole ordering problem: `Daemon.start()` runs `recover()` at line 32 and `startWorkflows()` only at line 54, deliberately, so a workflow is never fired at an agent the daemon has not yet worked out is dead — and routing recovery through `move` without this would call `workflowsRespond` before any workflow is loaded and silently do nothing, trading a visible bypass for an invisible one, which is worse
- [x] T051 [US2] Change `workflowsRespond(to:agentID:depth:)` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift:501` to append to `deferredLifecycleEvents` and return when `workflowsAreStarted` is false, **before** it reads `workflows[folder]` — the early `guard let byID = workflows[folder]` would otherwise swallow the event first. Appending rather than dropping is the point: `move` has one behaviour whenever it runs, and it is the workflow layer that decides when it is able to act (FR-014)
- [x] T052 [US2] Set `workflowsAreStarted = true` at the end of `startWorkflows()` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift:18` and drain `deferredLifecycleEvents` **in order**, clearing the array before replaying so an event that defers again cannot loop. Comment that the order is part of the contract: the endings drain in the order `recover` produced them, which is most recently active first
- [x] T053 [US2] Suppress the ending trigger for an agent that will be picked back up, in `move` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift:~288`: when the next state is `stopped`, skip `workflowsRespond` if the **post-transition** agent's `mayBePickedUpAfterRestart` is true. Comment with FR-016 and 011's reasoning — an agent about to carry on has not finished stopping, firing at it would be false, and it would race the pick-up — and note that the agent which will *not* be picked back up now fires, which is the behaviour this feature adds. The existing `willAskForOutcome` suppression for `finished` is untouched

### Closing the hole

- [x] T054 [US2] Replace the hand-written state change in `recover()` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift:25–33` with `await move(id, on: .foundDead)`: delete `updated.state = .stopped`, `updated.endedReason = .daemonGone`, `agents[id] = updated`, `try? await store.save(updated)`, and the hand-written `record(.stateChanged(.stopped, reason: .daemonGone), for: id)`. Keep the `runtimeNote` about the daemon stopping and keep it **before** the move, so the transcript reads in the order it happened. Re-read the agent from `agents[id]` afterwards, because the `mayBePickedUpAfterRestart` guard below must see the post-transition record
- [x] T055 [US2] Delete, do not reword, the sentences that exist only to explain the bypass: the part of `recover`'s doc comment in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift` that justifies writing the state by hand, and the four-line comment already removed at `DaemonCore.swift:260` by T013. A comment defending a route nothing takes any more is the next person's wrong turn
- [x] T056 [US2] Confirm and comment that `recover()`'s `filter { $0.state.holdsRuntime }` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift:19` now sweeps up `starting` records for free, which is FR-007: a starting agent found on disk had its process die with the last daemon exactly as a working one did. No code change is expected; if one turns out to be needed, that is a finding worth writing down rather than quietly fixing
- [x] T057 [US2] Check that `grep -rn foundDead` over the repository excluding `.build` now returns a **call site** in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift`. This task is a check rather than an edit, and it exists because the event has been declared, given two legal transitions, and called by nothing since the day it was written

### Tests for User Story 2

- [x] T058 [P] [US2] Add `aRestartFiresTheStoppedWorkflowThatWasWaiting` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowFiringTests.swift`: a project with an agent-stopped workflow, one agent left on disk as `stopped`/`daemonGone` with `restartPickUps == 1`, a daemon started over it, and an assertion that the workflow fired. Assert on the fire itself, not on the absence of an error — the deferral in T052 is the kind of thing that silently does nothing, and a test that would pass either way protects nothing (SC-005)
- [x] T059 [P] [US2] Add `anAgentAboutToBePickedBackUpDoesNotFire` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowFiringTests.swift`, the same setup with `restartPickUps == 0`, asserting the workflow did **not** fire and that the agent was nonetheless recorded as stopped (FR-016)
- [x] T060 [P] [US2] Add `anEndingDiscoveredOnRestartDoesNotClearThePickUpCount` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentPickUpTests.swift`, asserting `restartPickUps` survives a `foundDead` transition from every state that holds a runtime, `starting` included (FR-015)
- [x] T061 [P] [US2] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DaemonTests.swift` with an assertion that a recovery ending writes exactly one `stateChanged` entry — not two and not zero — now that the hand-written one is gone and `move` writes it instead, and that the project's counts moved for it (FR-013, SC-004)

**Checkpoint** — ✅ **reached 2026-09-20.** Package suite **passing** (896–901 tests; the count moves because other lanes are editing this tree). `recover()` goes through `move`, `foundDead` has its first call site since the day it was written, and **`agent.state` is now assigned in exactly one place in the whole daemon** — `DaemonCore.swift:296`, inside `move`. That is SC-009, ahead of the source scan that will hold it. See **Implementation Notes on Phase 4**.

---

## Phase 5: User Story 3 - A record that cannot be true is never written (Priority: P3)

**Goal**: The four invariants stop being assertions in a test file and become rules of the record: refused on write, mended on read, and said out loud in the transcript when they are mended.

**Independent Test**: Attempt to save each forbidden shape and confirm each is refused and logged. Then put each on disk by hand, start the daemon, and confirm the agent opens in a state the rules allow with a transcript line saying what was mended.

### The gate on the write

- [x] T062 [US3] Make `AgentStore.save(_:)` at `Packages/AgentsKit/Sources/AgentsKit/Store/AgentStore.swift:19` throw for a record failing `isConsistent`, **before** it creates the directory or encodes anything, logging the agent's id and which rule broke via `DaemonLog.shared.write`. Add a `public enum RecordRefused: Error` with one case per rule so the thrown value says which. Comment that `DaemonCore.saveQuietly` swallows this with `try?`, so the log line is the only evidence — deliberately, because a refused save is a bug in this app rather than news for the person, and taking the daemon down over it would lose the agents that are fine (FR-018, FR-019)

### The mend on the read

- [x] T063 [US3] Add `public enum Mend: Hashable, Sendable` to `Packages/AgentsKit/Sources/AgentsKit/Store/AgentStore.swift` with one case per rule and a `summary: String` in the app's voice for the transcript line. The four are exactly the table in [contracts/record-and-wire.md](./contracts/record-and-wire.md): `archived` with no reason becomes `archived`/`byUser`; `stopped` with no reason becomes `stopped`/`unrecognised`; `finished` with a reason that is not `endTurn` becomes `stopped` keeping the reason it had; and `starting` carrying a reason is treated as an agent found dead and becomes `stopped`/`daemonGone`, because `starting` is only ever transient and a record still in it is a daemon that did not come back
- [x] T064 [US3] Change `AgentStore.load(_:)` at `Packages/AgentsKit/Sources/AgentsKit/Store/AgentStore.swift:25` to apply the mend and return the agent together with an optional `Mend`, and update `loadAll()` at line 34 to carry the mends alongside the agents. `loadAll` keeps skipping records that will not **decode** — a truncated or corrupt file is a different thing from a well-formed record in a forbidden state, and one bad file still must not stop the daemon starting
- [x] T065 [US3] Update `DaemonCore.loadFromDisk()` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift:~297` to write a `runtimeNote` for each mend it is handed, using `Mend.summary`, so the person is told where this app already explains itself. Comment the tension the plan names rather than hiding it: this is a write nobody asked for, against a convention this app otherwise keeps, taken because the alternative is the failure being fixed — `loadAll` already drops what it cannot read, and an agent a person cannot see is one they can do nothing about (FR-020)

### The state a newer build wrote

- [x] T066 [US3] Add a stored `var rawState: String?` to `Agent` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`, deliberately **not** in `CodingKeys` — it must not join the `known` set that `unknownFields` is filtered against at line 148, or it will corrupt that filter. Doc-comment it as the one thing this feature keeps in memory rather than on the wire: the state string a newer build wrote, held only so `encode` can put it back instead of deleting what that build knew
- [x] T067 [US3] Make the `state` decode at `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift:108` lenient: read the raw `String`, and when it is not a known `AgentState`, set `state = .stopped`, `endedReason = .unrecognised` and `rawState` to the original. Comment with D7 — `EndedReason.unrecognised` already means exactly this, and `WorkOutcome.init(wire:)` already takes the same position for the same reason — and record the honest limitation that this protects builds which *have* the fix from states added *after* it, and does nothing for a build predating it meeting a `starting` record
- [x] T068 [US3] Make `encode(to:)` at `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift:158` write `rawState ?? state.rawValue` for the `state` key, so a state from a newer build survives a round trip rather than being quietly replaced with `stopped` (FR-021)
- [x] T069 [US3] Clear `rawState` wherever a `Transition` is applied, in `move` at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`. Without this, an agent read from a newer build's record and then prompted would be written back out still claiming a state it no longer has — the round trip would outlive the truth it was preserving. Comment it as the one place the kept string is allowed to die
- [x] T070 [US3] Add the source scan to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/LifecycleWriterTests.swift`: scan `Packages/AgentsKit/Sources` for assignments to an agent's `.state`, allowing only `Agent.init` and the apply inside `move`, failing with the file and line otherwise. This is SC-009 — one writer, down from two, and it stays one. Prove it bites by adding a direct write and watching it fail

### Tests for User Story 3

- [x] T071 [P] [US3] Add `everyForbiddenRecordIsRefused` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentStoreTests.swift`, attempting to save each of the four broken shapes, asserting each throws and that nothing reached disk (SC-006). The existing assertions in that file check `isConsistent` directly; they should now go through the store, which is what FR-018 means
- [x] T072 [P] [US3] Add `everyBrokenRecordOnDiskOpensAndSaysSo` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentStoreTests.swift`, writing each broken shape as raw JSON, loading it, and asserting both the mended state and the `Mend` returned (SC-007)
- [x] T073 [P] [US3] Add `aStateFromANewerBuildLosesNoAgent` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/LegacyRecordTests.swift`, writing `"state": "hibernating"` by hand and asserting it loads as `stopped`/`unrecognised`, does not appear in `unreadable`, and re-encodes with `"hibernating"` intact (SC-008, FR-021)
- [x] T074 [P] [US3] Add `everyRecordThisAppHasEverWrittenStillOpens` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/LegacyRecordTests.swift` for FR-025 in both directions: a record with none of the fields added since 003 opens unchanged, and an agent saved by this version carries no key an earlier version would choke on other than the `starting` state, which is a known and written-down limitation in [contracts/record-and-wire.md](./contracts/record-and-wire.md)

**Checkpoint** — ✅ **reached 2026-09-20.** Package suite **914 tests in 102 suites, passing**; `Agents` (macOS) and `Remote` (iOS) both **BUILD SUCCEEDED**. All four forbidden shapes are refused on write with nothing partial reaching disk, all four are mended on read and announced in the transcript, and a `"state": "hibernating"` record opens as `stopped`/`unrecognised` and round-trips with its original string intact. T007 was pulled forward from Phase 1 for the source scan. See **Implementation Notes on Phase 5**.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T075 Run `swift test --package-path Packages/AgentsKit` and require it fully green. This is the gate
- [x] T076 Build both schemes **sequentially** with `-skipPackagePluginValidation`, macOS first and then iOS, per this repository's standing rule — without the flag SwiftTerm fails silently, and a green package with a red app means the work is half done
- [~] T077 [P] **Checks 1, 2 and 4 walked; check 3 needs Alex.** Walk all four by-hand checks in [quickstart.md](./quickstart.md), including check 2 as amended by T004. Take the pid for the daemon kill from the target root's `daemon.lock` and never pattern-kill `agentsd`, which would take down the session the work is being done in
- [x] T078 [P] Add `"starting"` to `specs/020-agent-lifecycle/contracts/record-and-wire.md` §1's list of wire values if T001's edits did not already, and confirm §2's mend table matches what T063 built. A contract that disagrees with the code is worse than no contract
- [x] T079 Re-read `specs/020-agent-lifecycle/` end to end against what was built and correct anything the implementation settled differently. The dropped-`startFailed` decision at the top of this file is the model for how to do it: state what changed, state why, and amend the documents rather than leaving them to be believed

**Checkpoint** — ✅ **Phases 1 and 6 done 2026-09-20.** Every document now says what the code does. Package suite **919 tests, passing** (two pre-existing flakes, below); `Agents` (macOS) and `Remote` (iOS) both **BUILD SUCCEEDED**.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies. T001 lands before T002–T005, which read it; T006 and T007 are independent of all of them
- **Foundational (Phase 2)**: Depends on Phase 1. **Blocks all three stories** — each is written against `Transition`
- **US1 (Phase 3)**: Depends on Phase 2 only
- **US2 (Phase 4)**: Depends on Phase 2 only. Independent of US1 — the spec says so, and it is true in the code: nothing in Phase 4 touches `starting` except T056, which is a check
- **US3 (Phase 5)**: Depends on Phase 2. T028 (invariant 4) sits in US1 and gates only the fourth rule; US3 can ship the other three without it, but that leaves a gap and is not recommended
- **Polish (Phase 6)**: Depends on every story intended for the release

### Within Phase 2

T008 → T009 → T010 → T011 → T012 in sequence: one declaration, one file. T013 → T014 → T015 in sequence. T016 → T017 → T018 in sequence and all in `stop`. T019 and T020 last, and they are the checkpoint.

### Within Phase 3

T021 → T022 → T023 → T024 in sequence — one function, one file. T025 and T026 parallel once T021 lands. T027 → T028 → T029 in sequence. T030 needs T022; T031 needs T030. T032–T042 are the widest parallel opportunity in the feature: eight independent files, plus T035 and T042, which are the two that will not fail to compile and must not be skipped. T043–T049 last.

### Within Phase 4

T050 → T051 → T052 in sequence. T053 is independent of them. T054 needs T053 to exist, or the first recovery fires at every agent including the ones about to come back. T055, T056 and T057 are checks. T058–T061 last.

### Within Phase 5

T062 alone. T063 → T064 → T065 in sequence. T066 → T067 → T068 → T069 in sequence. T070 needs Phase 2 complete. T071–T074 last.

### Parallel Opportunities

- Phase 1: T002–T007 together, after T001
- Phase 3: T032, T033, T034, T036, T037, T038, T039, T040 — eight files, no shared lines
- Phase 3 tests: T043, T044, T045, T047, T048, T049
- Phase 4 tests: T058, T059, T060, T061
- Phase 5 tests: T071, T072, T073, T074

---

## Parallel Example: the ten switches

```bash
# Once T021 and T026 land, the compiler names eight of these. The two it will not
# name are T035 and T042, and they are done by hand.
Task: "Answer for .starting in App/Sources/Chat/Transcript.swift:623"
Task: "Answer for .starting in App/Sources/AgentList/AgentRow.swift:78"
Task: "Answer for .starting in App/Sources/AgentList/AgentRow.swift:163"
Task: "Answer for .starting in App/Sources/AgentList/AgentRow.swift:191"
Task: "Answer for .starting in Remote/Sources/Chat/EntryView.swift:285"
Task: "Answer for .starting in Remote/Sources/Projects/AgentCard.swift:70"
Task: "Answer for .starting in Remote/Sources/Projects/AgentCard.swift:163"
Task: "Answer for .starting in Remote/Sources/Projects/AgentCard.swift:190"
```

---

## Implementation Strategy

### MVP First (US1 only)

1. Phase 1 — make the documents true
2. Phase 2 — `Transition`, with no behaviour change. The checkpoint is a fully green suite and a `move` with no `if next ==` left in it
3. Phase 3 — `starting`
4. **STOP and VALIDATE**: quickstart check 1, by eye. The agent never appears under Stopped
5. Ship. This is the whole of what a person sees

### Incremental Delivery

1. Setup + Foundational → the table returns everything a record needs, and nothing else moved
2. + US1 → a new agent is never a finished one (MVP)
3. + US2 → an ending is an ending however it was caused
4. + US3 → a record that cannot be true is never written

Each is a complete increment, and none breaks the one before it.

### Parallel Team Strategy

Phase 2 is one person's work: four files, and every task in it edits a file the next one edits. After it, US1 and US2 genuinely can run in parallel. US3 touches `Agent`'s coding and `isConsistent`, which US1 also touches at T027 and T028, so it wants to start after US1's model tasks land even though nothing in it depends on them logically.

---

## Notes

- **60 pairs, not 66.** The contract says 66 until T001 amends it
- **Two switches compile silently** and give `.starting` a wrong answer without asking: `AgentRow.swift:177` and `wordsAboutTheRestart` at `DaemonCore+Recovery.swift:149`. The plan names only the first
- Ten compile errors look like a large diff. They are one line each. Do not take the chance to tidy the surrounding switches — that is 018's
- `[P]` means different files and no dependency on an unfinished task
- Commit after each task or logical group, and stop at any checkpoint to validate a story on its own


---

## Implementation Notes on Phase 2

Written while building T008–T020 on 2026-09-19. Four places where the code settled
differently from the task text, and why. Each is a correction to the task or the
contract, not a shortcut around it.

### 1. T014 records the reason the *event set*, not the agent's reason after the transition

T014 said to write `record(.stateChanged(transition.next, reason: agent.endedReason))`.
That is wrong, and visibly so. `ReasonChange.leave` means the agent keeps the ending it
already had, so a `promptSent` reviving an agent that had crashed would write
`stateChanged(.running, reason: .processDied)` — and `Transcript.swift`'s `isFailure`
reads exactly that pair, so the line reviving the agent would be drawn as a failure.

`move` now keeps `reasonThisEventSet`, which is the reason **this** transition set and
`nil` when it set none. That reproduces today's behaviour at every call site: the old
code recorded the caller's `endedReason:` argument, which was `nil` for precisely the
events whose `ReasonChange` is now `.leave`.

`willAskForOutcome` is passed the same value, for the same reason.

### 2. The contract's `Clears` cell for `unarchivedByUser` is wrong

[contracts/transitions.md](./contracts/transitions.md) says **no** in that column.
The derived rule in [data-model.md](./data-model.md) — and today's behaviour in
`DaemonCore.move` — both say *yes unless the existing ending is `daemonGone`*:
unarchiving lands on `finished` or `stopped`, both settled, and the old inline `if`
fired on exactly that.

Implemented the derived rule, because Slice 0 promises no behaviour change and T011
mandates the derivation. **T001 should fix that cell** while it is amending the file.

### 3. Unarchiving now clears `archivedReason`; it did not before

The contract says `clear` and the old `move` only cleared on `next == .running`, so an
unarchived agent kept a reason for an archiving that had been undone. Followed the
contract. It is unobservable: outside `isConsistent`'s first rule — which only asks
about agents that *are* archived — nothing in `App/Sources`, `Remote/Sources` or the
daemon reads `archivedReason`.

### 4. One `if next ==` legitimately remains in `move`

The checkpoint's "no `if next ==` left in it" is too strong. The three T013 named are
gone. What remains is `if next == .finished, willAskForOutcome(…)`, which is 014's
outcome-question suppression living inside the `case .finished, .stopped:` arm — it
distinguishes the two states that share that arm. It is not a lifecycle special case
and it is not this feature's to remove.

### Also worth knowing for Phase 3 and 4

- `stop`'s pre-write is gone (T016) and the suite is green, which answers **T018**: the
  `drainQueue(after:)` guard on `endedReason != .cancelled` still holds. The reason it
  holds is that the table refuses the *second* ending — whichever of `stop` and
  `finishTurn` reaches `move` first writes the reason, and the loser is refused. The
  pre-write never actually protected the case its comment described, because
  `finishTurn`'s own `move` overwrote it.
- Direct writes to an agent's `state` in `Packages/AgentsKit/Sources` are now exactly
  **two**: the apply inside `move`, and the bypass at `DaemonCore+Recovery.swift:27`.
  That is the "two, down to one" of SC-009, and T054 closes it.


---

## Implementation Notes on Phase 3

Written while building T021–T049 on 2026-09-20.

### 1. There was an eleventh switch, and the plan counts ten

`App/Sources/Chat/PromptBar.swift:598` switches `agent.state` exhaustively and is not in
the plan's list, the contract's list, or my own count in T004 — none of the three found
it, because every survey was a grep for `case .waitingOnUser` and that switch groups
`.running, .waitingOnUser` on one line.

It is unreachable for `.starting`: the `hasTurnInFlight` guard three lines above returns
first. Answered anyway, and commented as unreachable, because a `default:` there is how
the *next* new state would get the wrong words.

**The real count is eleven exhaustive switches plus two silent ones.** T004 should say
eleven, not ten.

### 2. `.starting` spins, and the "working icon" was never `circle.dotted`

T034 and T039 said to return `"circle.dotted"`, the icon `case .running` returns. But
`StatusIcon.body` in both apps is `if state == .running { ProgressView() } else { Image(systemName: symbol) }`
— so the `symbol` switch is only ever reached in the `else`, and `case .running` in it
is unreachable. The working icon is the **spinner**.

Following the task literally would have drawn a starting agent as a static dotted circle
that flips to a spinner the instant its first turn begins — the same flicker this feature
exists to remove, one layer down. The condition is now
`if state == .running || state == .starting` in `AgentRow.swift` and `AgentCard.swift`,
and the `symbol` entry is kept for the same reason `.running`'s is.

### 3. The birth test observes up to the first ending, not the whole sequence

T046 as written would have been flaky, and was: 014's outcome question is a turn of its
own, so broadcasts keep arriving after the agent first reaches `finished`. Whether they
land before the test reads the recorder is a race — it passed alone and failed in a
loaded full run.

The assertion is now over `broadcasts.prefix { not settled }`, which is the interval the
claim is actually about. `aPromptArrivingDuringAStartQueuesRatherThanRacing` filters the
transcript to `from == .person` for the same reason.

### 4. `AgentGroupTests.oneGroupPerState` was replaced, not extended

It asserted `AgentGroup.allCases.count == AgentState.allCases.count`, which was a true
statement about five states and is false about six — `starting` and `running` share
**Working**, which is the point of the state rather than a slip. Replaced with the two
properties that still hold and are the ones that matter: every state lands in exactly one
group, and every group is reachable from some state. `noHeadingWasAddedRenamedOrRemoved`
was added to hold FR-023 down explicitly.

### 5. One pre-existing flaky test, not caused by this phase

`SuggestedPromptTests.aConversationResumedAfterARestartIsNotBriefedAgain` failed once in
a full run that took 16.3s under load, and passed in five isolated runs and three
subsequent full runs at 3.6s. Its own doc comment records that it "failed in a full run
about one time in three" for a 014-question race that was only partly fixed. It belongs
to lane 015's working tree (it references `ToolPolicyCatalog`), and is not this phase's
to fix — but it is real and it is worth someone's attention.

### Still open for later phases

- `DaemonCore+Recovery.swift:27` remains the second writer of `state`. T054 closes it.
- `recover()`'s `holdsRuntime` filter now sweeps up `starting` records for free, as
  T056 predicted. Untested until Phase 4 adds the recovery suite.


---

## Implementation Notes on Phase 4

Written while building T050–T061 on 2026-09-20.

### 1. The gate defaults **open**, and `Daemon.start()` closes it

T050 said `var workflowsAreStarted = false`. Doing that broke two existing tests, and the
reason is the important part: workflows are also adopted by `rescanWorkflows` /
`adoptWorkflows`, which every test and any future embedder uses **without ever calling
`startWorkflows`**. Defaulting the gate closed meant those queued every lifecycle trigger
forever with nothing to drain them — a trigger surface that silently does nothing, which
is precisely the invisible bypass D4 argues against, reintroduced by the fix for it.

So the flag defaults **true**, and `Daemon.start()` calls a new
`holdWorkflowEventsUntilStarted()` immediately before `recover()`. The deferral now
covers exactly the window that needs it — the real startup ordering — and a `DaemonCore`
driven directly behaves as it always did.

**T050's text should be amended.** The two tests that caught this were
`anAgentFinishingFiresAWorkflowThatWatchesForIt` and
`aTriggeringWorkflowSendsThePromptBackIntoTheSameAgent`; they were right and the task was
wrong.

### 2. A fourth test, for the failure mode that is silence

T058 and T059 assert on a fire and a non-fire. Both would still pass in a world where the
deferral dropped events instead of holding them, so long as nothing fired for other
reasons. `anEventRaisedBeforeWorkflowsStartedIsHeldAndNotDropped` asserts on
`deferredLifecycleEvents` directly — that it holds exactly one event after recovery, that
the event is `.stopped`, and that the array is empty again after `startWorkflows`.

### 3. The scan in T049 is now proved by assertion, not by mutating the repository

Phase 3 proved the `"Starting"` literal scan bites by putting a literal back into
`AgentRow.swift` and watching it fail. That works, and it leaves the mutation on disk the
one time something interrupts between breaking and restoring. The matcher is now a pure
`spellsOutStarting(_:)` asserted against five sample lines — including a comment and a
longer word that merely contains it. **T070's source scan in Phase 5 should be written
the same way from the start.**

### 4. One pre-existing flake, confirmed not to be this phase's

`SuggestedPromptTests.aConversationResumedAfterARestartIsNotBriefedAgain` failed in 2 of
10 full runs, only ever on runs that took ~16s instead of ~3.5s. Its own doc comment
records the 014-question race behind it, and the file belongs to lane 015. Unchanged by
this phase and still worth someone fixing.

### 5. Ordering that had to be got right in `recover`

The `runtimeNote` explaining the ending stays **before** the `move`, so the transcript
reads in the order things happened. And `mayBePickedUpAfterRestart` is re-read from
`agents[id]` after the move rather than asked of the agent the loop was handed — it is a
question about the record *after* the ending. `aRecoveryEndingIsRecordedExactlyOnce`
asserts both: one `stateChanged` line, and the note before it.


---

## Implementation Notes on Phase 5

Written while building T062–T074 on 2026-09-20.

### 1. SC-009 is "one transition writer **plus the record mender**", and the scan says so

T070's scan found three writes, not one — and the two it flagged were mine, in
`AgentStore.mended`. That is not a slip: FR-020 asks for a record the invariants forbid
to be repaired on read, and repair cannot go through the transition table, because the
table is total over *events that happen to an agent* and "this record was already wrong
when we read it" is not one of them. There is no event for it, and inventing one would
put a lie in the transcript.

Rather than loosen the matcher until the number came out right, the scan has a one-entry
allow-list carrying the reason, in the style of `ConsistencyTests.colourAllowList`, plus
an assertion that the mender's write count has not drifted. **SC-009's wording should be
amended** from "one place" to "one transition writer, plus the mender that runs before a
record is an agent anything holds".

The mend is safe for the reason the funnel exists: the funnel governs an agent the daemon
is holding, and this runs on a freshly decoded record before it is one. Nothing is
watching it, nothing has been told about it, and the next thing that happens is
`loadFromDisk` announcing it.

### 2. The scan was written as a proved matcher from the start

Per the note at the end of Phase 4, `writesAnAgentState(_:)` is a pure function asserted
against ten sample lines — including `account.state`, `plan.state` and `self.state`,
which are other things entirely that happen to have the property, and a commented-out
write, and a read. No repository file was edited to prove the scan bites.

### 3. `rawState` needed no init change, and that is worth knowing

T066 warned it must stay out of `CodingKeys`, which it does. What the task did not say is
that Swift gives a `var x: T?` stored property an implicit `nil` default, so the explicit
memberwise `init` needed no new parameter and not one of the dozens of `Agent(...)` call
sites changed. `LegacyRecordTests.aStateFromANewerBuildSurvivesARoundTrip` asserts the
`unknownFields` filter still works alongside it.

### 4. `endedReason` is forced **after** it is decoded

The lenient decode sets `state`, but `endedReason` is decoded thirty lines further down
and would have overwritten it. The unknown-state case therefore re-asserts
`endedReason = .unrecognised` after that line, commented: a state this build cannot
reason about makes whatever reason the record gave meaningless.

### 5. Six call sites outside this feature had to change

`AgentStore.load` now returns `(agent:mend:)` and `loadAll` gained a third tuple element.
Five test call sites needed `.agent` appended — including two in `SuggestedPromptTests`
and `ResidualToolTests`, which belong to **lane 015**. Mechanical, but it is a change in
somebody else's file and they should know.

### 6. The mend table, as built

| On disk | Becomes | Why |
| --- | --- | --- |
| `archived`, no reason | `archived` / `byUser` | the only reason there is |
| `stopped`, no reason | `stopped` / `unrecognised` | nothing vouched for it |
| `finished`, not `endTurn` | `stopped`, keeping its reason | the reason is the one true thing on the record |
| `starting`, carrying an ending | `stopped` / `daemonGone` | `starting` is transient, so a record still in it is a daemon that did not come back |


---

## Implementation Notes on Phases 1 and 6

Written 2026-09-20, after the documents were brought in line with the code.

### What the documents were wrong about

| Document | Said | Says now |
| --- | --- | --- |
| `contracts/transitions.md` | 66 pairs, 11 events, a `startFailed` row per table | 60 pairs, 10 events, and a note at the head explaining why the eleventh was dropped |
| `contracts/transitions.md` | `unarchivedByUser` clears the pick-up count: **no** | **yes, unless the ending is `daemonGone`** — the column is derived, not transcribed, and the old cell contradicted both the derivation and what the app has always done |
| `contracts/transitions.md` | `turnBegun` from `starting` clears the archive reason | leaves it: invariant 4 forbids a `starting` agent from having one |
| `contracts/record-and-wire.md` | 10 exhaustive switches, one silent | **11** exhaustive, **two** silent, both named in a table |
| `spec.md` FR-005 | "the start fails, and it becomes stopped" | the three ways out that exist; a failed start makes no agent |
| `spec.md` US1-4 | a failed start leaves a stopped agent | no agent is made, and the error reaches the person unchanged |
| `spec.md` SC-003 | "every pairing" | **60** pairings, named |
| `spec.md` SC-009 | "one place… down from two" | **one transition writer**, plus the record mender, which cannot go through the table and is named in the scan's allow-list |
| `plan.md` | 2 new events, 10 switches, one silent | 1 event, 11 switches, two silent, with the misses explained |
| `quickstart.md` | 66 pairs, 13 switches, check 2 expects a stopped agent | 60, 11, and check 2 now checks that this feature changed *nothing* there |
| `data-model.md` | "no new stored field" | no new field **on the wire**; `rawState` in memory, and why it is not a `CodingKey` |

### By-hand checks (T077)

- **Check 1 — a new agent is never Stopped.** Walked earlier in this feature against a
  real Claude runtime on a throwaway root. The record went `starting → running →
  finished` and never once said `stopped`. The `starting` window was **6ms**, which is
  why it was measured with a 2ms poller on `agent.json` rather than by eye — no
  screenshot could catch it. The screenshot showed the agent under **Working** with no
  **Stopped** heading drawn at all.
- **Check 2 — a start that fails.** Amended, because as written it described an agent
  that is never made. Nothing to walk: the behaviour is unchanged by this feature.
- **Check 4 — a broken record is mended and says so.** Walked. A hand-written
  `"state": "stopped"` with no `endedReason` opened under **Stopped**, labelled "Stopped
  for a reason we do not know", with this in its transcript: *"This agent's record said
  it had stopped but not how, which should not be possible. Its ending is recorded as
  one nothing vouched for."*
- **Check 3 — a restart fires the workflows that were waiting.** ⚠️ **Not walked.** It
  needs a real daemon killed under two long-running agents, one of which has already
  been picked back up once. The integration suite covers it
  (`aRestartFiresTheStoppedWorkflowThatWasWaiting`,
  `anAgentAboutToBePickedBackUpDoesNotFire`), but the by-eye walk is Alex's.

### Two pre-existing flaky tests, neither caused by 020

Both were confirmed against a clean `git worktree` at HEAD, rather than guessed at.

1. **`DaemonTests.stoppingAnAgentBeforeItIsPickedUpWithdrawsIt`** — fails **6 of 6** runs
   in isolation, and intermittently in a full run. **Fails identically at HEAD with none
   of 020's changes.** Its final assertion is `launcher.launchCount == 1`, which its own
   comment four lines above contradicts: *"At least one, not exactly one: a turn that
   ends without saying how it went is asked, and that question starts a runtime of its
   own."* The comment is right and the assertion is wrong; it only passes when full-suite
   load delays the second launch past the assertion.
2. **`SuggestedPromptTests.aConversationResumedAfterARestartIsNotBriefedAgain`** — fails
   in roughly 2 of 10 full runs, only ever on runs taking ~16s instead of ~3s. Its own
   doc comment records the 014-question race behind it. Belongs to **lane 015**.

### Left for whoever merges this

- 020 is **built and green** across all three user stories, but **nothing is committed**,
  and this working tree also holds lanes 015 and 017's changes.
- Five call sites in other lanes' test files needed `.agent` appended for
  `AgentStore.load`'s new tuple, two of them in lane 015's files.
