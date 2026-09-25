---
description: "Tasks for 040 parked chats"
---

# Tasks: Park a Chat to Come Back To Later

**Input**: `specs/040-parked-chats/` — plan.md, spec.md, research.md (no data-model.md, contracts/ or
quickstart.md were written; the plan's Summary and research R1–R9 stand in for them).

**Tests**: Included. The project proves daemon and model behaviour with `swift test` in
`Packages/AgentsKit`, and the spec's Independent Tests name what to assert. Tests assert the property
directly; never mutate source to prove one.

**Order**: The plan puts the Mac first, end to end, walked with run-app before depth (memory: settle the
UX before building depth). So US1 + US2 (both P1) are built and walked together, then US3 (turn-end
promotion), then US4 (phone).

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup

- [X] T001 Confirm the worktree is on `040-parked-chats` off current `main` (`git merge-base HEAD main` equals `main`), and `swift test` in `Packages/AgentsKit` is green before any change (record the count).

---

## Phase 2: Foundational (blocks every story)

- [X] T002 Add `public enum Parking: Codable, Hashable, Sendable { case whenTurnEnds(since: Date); case parked(at: Date) }` with `isParked` and `parkedAt` helpers, and `public var parking: Parking?` on `Agent` (init argument defaulting to nil, `CodingKeys.parking`, `decodeIfPresent`, `encodeIfPresent`) in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift` (R1). Older records open as not parked.
- [X] T003 Add `case parked` to `AgentGroup` (title "Parked"), append it to `AgentGroup.live` after `.stopped`, add a `parked: Bool` argument with no default to `AgentGroup.init(for:wantsEyes:report:outcomeAsked:parked:)` with precedence archived → waitingOnUser → parked → existing rules, and pass `parking?.isParked == true` from `Agent.group(wantsEyes:)` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift` (R2). Update the doc comment.
- [X] T004 Add `public enum ParkAction { case park, unpark }` and `Agent.parkAction: ParkAction?` (`.unpark` when a mark is present, `.park` when not archived, nil when archived) in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift` (R3).
- [X] T005 Give `ProjectSummary.counts` a tolerant decode that drops group keys it does not know, and have the daemon leave `.parked` out of the counts it sends, in `Packages/AgentsKit/Sources/AgentsKitCore` (ProjectSummary's file) and `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift` (R7).
- [X] T006 Sort the Parked group most recently parked first in `AgentsModel` (where groups are listed/sorted) in `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift` (FR-003).
- [X] T007 [P] Update `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentGroupTests.swift`: `live` order and titles now end in Parked; parked outranks finished/stopped/report/eyes; waitingOnUser and archived outrank parked; `whenTurnEnds` does not move a chat; `parkAction` for each case.
- [X] T008 [P] Record tests in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/` (the existing Agent record test file): both `Parking` values round-trip; a record without `parking` decodes as not parked; `ProjectSummary` counts with an unknown key decode, dropping it.
- [X] T009 Add the words once in `Shared/UI/ParkWords.swift`: "Park"/"Unpark" labels, symbol `parkingsign.circle`, tooltips/accessibility labels, and a line formatter giving "Parked 3 days ago" / "Parks when this turn ends" (R8, FR-018). Make sure both schemes include it (`project.yml`).

**Checkpoint**: `swift test` green; both schemes build.

---

## Phase 3: User Story 1 + 2 — Park a chat, and come back to it (P1) 🎯 MVP

**Goal**: From the Mac, park a settled chat from the toolbar or card menu; it sits under Parked; open,
read and leave keep it parked; Unpark or a typed prompt brings it back; archive clears the mark.

**Independent Test**: Park a finished chat → under Parked only, transcript/cost/worktree unchanged,
survives daemon restart. Open and leave → still parked. Prompt → runs and unparked. Unpark → back in
its ending's group, nothing prompted. Archive → not parked; unarchive → not Parked.

### Tests

- [X] T010 [P] [US1] Daemon tests in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ParkingTests.swift`: `agents/park` on a finished chat writes `.parked`, groups `.parked`, adds no transcript entry, leaves state/endedReason/report untouched; twice is a no-op with no error; parking a report that needs a person removes its report need from `needs()`; the mark survives reloading the store.
- [X] T011 [P] [US2] In the same file: `agents/unpark` removes the mark and the chat groups by its ending; a person's `agents/prompt` over dispatch clears the mark; a direct `prompt(_:)`/`enqueue` (workflow path) does not; archive clears the mark and unarchive does not restore it.
- [X] T012 [P] [US1] Assert no tool the app gives agents has "park" in its name (FR-016), in `ParkingTests.swift`.

### Implementation

- [X] T013 [US1] Add `agents/park` and `agents/unpark` (request carries the agent id) to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`.
- [X] T014 [US1] Implement `park(_:)` and `unpark(_:)` on `DaemonCore` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`: park on archived is refused quietly; on a turn in flight (`starting`, `running`, `waitingOnUser`) writes `.whenTurnEnds(since: now)`; on a settled chat writes `.parked(at: now)`; no-ops when already so; save, `changed(agent)`, `reconsider()`. Never touch runtime, transcript or queue (FR-005, FR-017).
- [X] T015 [US1] Route the two methods in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, and in the `agents/prompt` case clear the mark when the prompt comes from the person before calling `prompt(_:)` (R4, FR-009).
- [X] T016 [US2] In `DaemonCore.move` (`Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`) clear the mark when the next state is `.archived`, before `changed(agent)` (FR-010).
- [X] T017 [US1] In `needs()` skip parked chats in the report loop only, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Attention.swift` (R6, FR-004). Check any "wants eyes"/file-to-show claim is also dropped for parked chats (edge case).
- [X] T018 [US1] Add `park(_:)`/`unpark(_:)` to `App/Sources/AppModel.swift`, sending the new methods (mirror `archive`).
- [X] T019 [US1] Mac chat toolbar: Park/Unpark button between Stop and Archive switching on `parkAction`, popping to the project on Park as Archive does; and a parked line ("Parked 3 days ago" / "Parks when this turn ends") on the chat page, in `App/Sources/Chat/ChatView.swift`.
- [X] T020 [US1] Mac card: Park/Unpark in the context menu; the row shows how long ago it was parked plus its ending and no unread/needs mark for a parked chat, and "Parks when this turn ends" for a marked one, in `App/Sources/AgentList/AgentRow.swift`.
- [X] T021 [US1] Check `App/Sources/Projects/ProjectAgentsView.swift` draws Parked from `AgentGroup.live` always open (not folded), with its count, and hidden when empty; fix anything keyed on the old four groups (grep `App/` for exhaustive `switch` on `AgentGroup`).
- [X] T022 [US1] Build the Mac scheme (`xcodebuild -skipPackagePluginValidation`), then walk it with the run-app skill on a scratch root: park a finished chat from the toolbar and from the card, see Parked below Stopped, open/leave, Unpark, prompt a parked chat, archive/unarchive. Screenshot each.

**Checkpoint**: Mac parking works end to end and is walked. Stop for Alex's look at the layout if anything is doubtful.

---

## Phase 4: User Story 3 — Park a chat that is still working (P2)

**Goal**: Park during a turn lets it finish, then lands in Parked with no needs alert.

**Independent Test**: Start a turn, park at once; it runs to the end with no stop; row says it will
park; on ending it is under Parked and raised no need.

- [X] T023 [P] [US3] Tests in `ParkingTests.swift`: park while running → `.whenTurnEnds`, group stays `.running`; turn ends finished/stopped/failed/with a needs-a-person report → `.parked`, and `needs()` never held a report need for it; unpark mid-turn withdraws the mark; a mid-turn question still groups `.needsAttention`; a person's prompt mid-turn withdraws the mark; finish/stop workflow triggers still fire (FR-015); `foundDead` with `mayBePickedUpAfterRestart` keeps `.whenTurnEnds`.
- [X] T024 [US3] In `DaemonCore.move` promote `.whenTurnEnds` to `.parked(at: now)` when the next state is `.finished` or `.stopped`, before `changed(agent)` and `reconsider()`, skipping `event == .foundDead && agent.mayBePickedUpAfterRestart`; leave the workflow trigger switch unchanged, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` (R5).
- [X] T025 [US3] Walk on the scratch app: park a working chat, see "Parks when this turn ends", see it land in Parked. *(Mark and landing seen on the live daemon; the "Parks when this turn ends" row text was not caught on screen — the window was on another chat.)*

---

## Phase 5: User Story 4 — Phone and iPad (P3)

**Goal**: Park/Unpark in the phone's chat menu, disabled when stale; Parked group in the same place.

**Independent Test**: Park on the Mac → Parked on the phone; Unpark from the phone → leaves Parked on the Mac.

- [X] T026 [P] [US4] Add `park(_:)`/`unpark(_:)` to `Remote/Sources/RemoteModel.swift`.
- [X] T027 [P] [US4] Answer `agents/park`/`agents/unpark` in `Remote/Sources/Preview/FakeDaemon.swift`.
- [X] T028 [US4] Park/Unpark items in `ChatMenu` switching on `parkAction`, disabled when stale, and the parked line on the chat page, in `Remote/Sources/Chat/RemoteChatView.swift`.
- [X] T029 [US4] Row line for parked and marked chats in `Remote/Sources/Projects/AgentCard.swift`; check `Remote/Sources/Projects/ProjectPageView.swift` draws Parked from `AgentGroup.live` open, and fix any exhaustive `switch` on `AgentGroup` in `Remote/`.
- [X] T030 [US4] Build the Remote scheme for the generic simulator only (no throwaway sims). The phone walk is Alex's. *(Built; walk open.)*

---

## Phase 6: Polish

- [X] T031 Run `ConsistencyTests` and the full `swift test`; compare against T001's count (the suite is flaky under load — rerun before blaming the branch).
- [X] T032 Build both schemes sequentially with `-skipPackagePluginValidation`.
- [X] T033 Commit on `040-parked-chats` (spec docs + code). Do not merge; that is Alex's call.

---

## Dependencies

- Phase 2 blocks everything. T007/T008 run alongside T009 once T002–T004 exist.
- US1 and US2 share the daemon methods (T013–T017) and are built as one phase.
- US3 needs T014 (the mark written mid-turn) and T016's place in `move`.
- US4 needs Phase 2 and T013; it does not need US3.

## Parallel examples

- Phase 2: T007, T008, T009 together.
- Phase 3: T010, T011, T012 (tests) together; then T018 alongside T014–T017.
- Phase 5: T026, T027 together.

## Implementation strategy

MVP is Phase 3: Mac parking and unparking of settled chats, walked. Then US3's promotion, which is a
few lines in `move` plus tests. Then the phone, whose walk is Alex's.
