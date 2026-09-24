---

description: "Task list for 024 keep-host-awake"
---

# Tasks: The Mac Stays Awake While Its Agents Work

**Input**: Design documents from `/specs/024-keep-host-awake/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/daemon-api.md](./contracts/daemon-api.md),
[quickstart.md](./quickstart.md)

**Tests**: Included, and not optional here. The whole feature is a derivation with two
inputs and one output, which is the cheapest possible thing to test exhaustively and the
most expensive possible thing to get subtly wrong — a hold that is never released is
invisible until somebody's battery is flat.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to

## Before you touch anything

Four standing facts about this tree, all of which will bite:

1. **Three lanes share this working tree.** `git status` churns under you and the package
   may not compile at any moment because somebody else is mid-edit. Verify in a detached
   worktree: `git worktree add --detach /tmp/wake HEAD`, copy your files in, run there.
2. **`Shared/UI/TypeScale.swift` is untracked** (the type-scale lane). The **Mac scheme will
   not build from a clean checkout of HEAD** — `appText` is called all over
   `ProjectListView.swift` and defined only in that uncommitted file. The AgentsKit package
   suite builds and runs fine. Phase 6 is the only phase this affects; plan for it there.
3. **`xcodegen generate` after adding any source file.** The pbxproj is generated and lists
   files explicitly, so a new file that is not regenerated in simply does not exist to Xcode.
4. **Never pattern-kill `agentsd`** — it hosts these sessions. Take the pid from the target
   root's `daemon.lock`.

---

## Phase 1: Setup

**Purpose**: Somewhere for the new code to live.

- [X] T001 Create the directory `Packages/AgentsKit/Sources/AgentsKit/Power/` for the three
      machine-facing types. They go here rather than under `Daemon/` because none of them
      imports `DaemonCore` and none is about agents — this is the seam that keeps
      `Wake.verdict` unit-testable with no daemon in the picture at all.

- [X] T002 Run `xcodegen generate` and confirm the new group appears in `Agents.xcodeproj`.
      Repeat this after **every** task below that adds a file; it is not mentioned again.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The two inputs, the one output, and the pure function between them. Everything
else in this feature is plumbing around what Phase 2 builds.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T003 [P] Create `Packages/AgentsKit/Sources/AgentsKit/Power/PowerSource.swift` with
      `public struct PowerReading: Hashable, Sendable` carrying `batteryPercent: Int?` and
      `isOnMains: Bool`, and `public protocol PowerSource: Sendable { func read() -> PowerReading }`.
      `batteryPercent` is **nil on a Mac with no battery** — a desktop — which FR-012 treats
      as mains. Clamp any percentage to `0...100` in the initialiser.

- [X] T004 Add `IOKitPowerSource` to the same file: `import IOKit.ps`, read
      `IOPSCopyPowerSourcesInfo()`, take `isOnMains` from
      `IOPSGetProvidingPowerSourceType` being `kIOPSACPowerValue`, and the percentage from
      `kIOPSCurrentCapacityKey` divided by `kIOPSMaxCapacityKey`. **Divide; do not assume max
      is 100** — it is not, on an aged battery. An empty power-sources list means no battery,
      so `batteryPercent` is nil. Verified working from a non-GUI process in research §3.

- [X] T005 When IOKit returns nothing at all, `IOKitPowerSource.read()` MUST answer
      `PowerReading(batteryPercent: nil, isOnMains: true)` — i.e. *hold*. Put the reasoning in
      a comment, because it looks arbitrary and is not: holding wrongly leaves a Mac awake,
      which is visible and recoverable; releasing wrongly loses a turn, which is silent.

- [X] T006 [P] Create `Packages/AgentsKit/Sources/AgentsKit/Power/Wakefulness.swift` with
      `public protocol Wakefulness: AnyObject, Sendable { func hold(reason: String); func release() }`
      and `ProcessInfoWakefulness`, which calls
      `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason:)`
      and keeps the returned token, ending it on `release()`. **`.idleSystemSleepDisabled`
      and nothing else** — adding `.idleDisplaySleepDisabled` would break FR-007.

- [X] T007 Make `ProcessInfoWakefulness` idempotent: `hold` while already held does nothing,
      `release` while not held does nothing. `reviseWakefulness()` leans on this, and without
      it the assertion leaks on the second call.

- [X] T008 [P] Create `Packages/AgentsKit/Sources/AgentsKit/Power/Wake.swift` with
      `public enum WakeVerdict: Hashable, Sendable` — cases `hold`, `idle`, and
      `batteryTooLow(percent: Int)`. The third case exists **only** so FR-016 can say
      something different from FR-015's silence; note that in a comment or somebody will
      collapse it into `idle`.

- [X] T009 Add to `Wake.swift`: `public static let batteryFloorPercent = 20` and the pure
      `public static func verdict(workInFlight: Bool, power: PowerReading) -> WakeVerdict`,
      per data-model §3. Order matters: no work → `idle`; mains → `hold`; no battery → `hold`;
      then `percent > batteryFloorPercent ? .hold : .batteryTooLow`. **The floor is
      inclusive** — FR-010 says "reaches or falls below", so 20% is too low, not just below 20.

- [X] T010 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WakeVerdictTests.swift`
      covering the whole truth table in data-model §3, including **both sides of the
      inclusive floor** (19 → `batteryTooLow`, 20 → `batteryTooLow`, 21 → `hold`), mains at
      5% → `hold`, and no battery on battery power → `hold`.

- [X] T011 [P] Add `FakePowerSource` and `RecordingWakefulness` to the test target (in
      `WakeVerdictTests.swift` or a shared test-support file, whichever matches how this
      suite already shares fakes). `FakePowerSource`'s reading must be **settable between
      calls**, so a test can cross the floor mid-turn without discharging a laptop.
      `RecordingWakefulness` counts holds and releases and keeps every reason string.

- [X] T012 Add `power: (any PowerSource)? = nil` and `wakefulness: (any Wakefulness)? = nil`
      to `DaemonCore.init` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift:229`,
      defaulting to `IOKitPowerSource()` and `ProcessInfoWakefulness()`, and store them.
      This joins `launcher`, `now`, `thresholds` and `mailbox`, which exist for exactly this
      reason — follow their shape, including the defaulted-nil-then-substitute idiom.

**Checkpoint**: `swift test --filter WakeVerdict` passes. No daemon involved yet, and the
whole of the feature's logic is already proven.

---

## Phase 3: User Story 1 — A turn does not die because you walked away (Priority: P1) 🎯 MVP

**Goal**: An agent mid-turn holds the Mac awake, and the window being closed changes nothing.

**Independent Test**: Set idle sleep to two minutes, start a five-minute agent, don't touch
the machine. It is still awake at five minutes and the turn reached its own end.

- [X] T013 [US1] Create `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Wakefulness.swift`
      with `var hasWorkInFlight: Bool { agents.values.contains { $0.state == .starting || $0.state == .running } }`.
      Two states and **not** `waitingOnUser` (FR-002, FR-003).

- [X] T014 [US1] In the same file, write the doc comment on `hasWorkInFlight` that names its
      two dangerous neighbours and why it is neither of them: `isHoldingAgents`
      (`DaemonCore+Lifetime.swift:8`) asks whether the daemon may **exit** and counts
      `waitingOnUser`, busy shells and pending permissions; `AgentState.hasTurnInFlight` asks
      whether the **conversation** is busy and also counts `waitingOnUser`. This one asks
      whether the **CPU** is busy. Getting this wrong holds the Mac awake all night for an
      unanswered question.

- [X] T015 [US1] Add `reviseWakefulness()` to `DaemonCore+Wakefulness.swift`: compute
      `Wake.verdict(workInFlight: hasWorkInFlight, power: power.read())`, compare against the
      last verdict held in a new `var lastWakeVerdict: WakeVerdict?` on `DaemonCore`, and
      **return immediately when it has not moved**. Only on a change: `wakefulness.hold(reason:)`
      or `wakefulness.release()`. Idempotence is load-bearing — see T017.

- [X] T016 [US1] The reason string is built here and is carried verbatim into
      `pmset -g assertions` (verified, research §1), so write it for a person reading a
      terminal at midnight: `"Agents: 2 agents are mid-turn"`, singular when one. It must also
      be distinguishable from the assertion 005 §10 will one day add in the bridge, which is
      a different holder for a different reason (research §7).

- [X] T017 [US1] Call `reviseWakefulness()` at the end of `DaemonCore.changed(_:)`
      (`DaemonCore.swift:300`). **`changed(_:)` and not `move(_:on:)`** — an agent is created
      with `agents[agent.id] = agent` directly at `DaemonCore+Commands.swift:196`, before any
      transition, so a hook on `move` alone misses every agent's `starting` moments. Note in a
      comment that this runs on every token of streamed output, which is why T015 compares
      before acting.

- [X] T018 [US1] Call `reviseWakefulness()` at the end of `Daemon.start()` in
      `Packages/AgentsKit/Sources/AgentsKit/Daemon/Daemon.swift`, after
      `pickUpAfterRestart(recovered)`, so a daemon restarting under resumed agents holds from
      its first moment rather than from their next state change (FR-014).

- [X] T019 [US1] Add the two `DaemonLog.shared.write` lines for FR-017 — one when the hold is
      taken, one when it is let go, each naming the verdict and the agent count. The daemon's
      log, **not** the transcript: this is a fact about the machine, not about any one agent's
      conversation.

- [X] T020 [P] [US1] Create
      `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WakefulnessTests.swift` with a test
      that drives a real start-and-turn through `DaemonCore` using the existing fake launcher
      (copy the setup from `DaemonTests`/`AttentionTests`), a `RecordingWakefulness` and a
      mains `FakePowerSource`, and asserts the hold was taken exactly once.

- [X] T021 [US1] Add a test that three overlapping agents cause **exactly one** hold and one
      release, with the release only after the last of them ends (FR-006, US1-3).

- [X] T022 [US1] Add a test that an unchanged `changed(_:)` — the streamed-token case — causes
      no second `hold` call. This is the flood guard, and it is the one that will regress.

**⛔ GATE — quickstart checks 1 and 3, by hand, before Phase 6.** Build, launch with
`env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin open ...`, start a real agent, and
confirm with `pmset -g assertions | grep -i agents` that a line naming `agentsd` and
`PreventUserIdleSystemSleep` appears with your reason string, and that **no**
`PreventUserIdleDisplaySleep` line names `agentsd`. Then three agents at once → still exactly
one line. Record what you saw in the notes at the foot of this file.

**Checkpoint**: A real agent holds a real assertion. The feature exists.

---

## Phase 4: User Story 2 — It gives the Mac back the moment the work is done (Priority: P2)

**Goal**: The hold is released promptly by every route out of a turn, and dies with the
process.

**Independent Test**: With idle sleep at two minutes, run an agent to completion, leave the
Mac alone, and confirm it sleeps on schedule from the moment the turn ended.

**Note**: This is the same `reviseWakefulness()` Phase 3 built — no new production code
beyond T026. The tasks are tests, because release is where this feature fails silently.

- [ ] T023 [P] [US2] Add to `WakefulnessTests.swift`: a turn that ends normally releases the
      hold, and the release happens in the same call that records the ending rather than on a
      timer (FR-004's five seconds is met by construction).

- [ ] T024 [P] [US2] Add the test that matters most: an agent taken to `waitingOnUser` —
      blocked on a permission question — **never causes a hold**, and releases one it was
      holding (FR-003, US2-2). `isHoldingAgents` answers the opposite way for this same agent,
      which is exactly why this test exists.

- [ ] T025 [P] [US2] Add tests for the three remaining endings, each releasing the hold:
      stopped by hand mid-turn (US2-3), the runtime process dying (US2-4), and an agent found
      dead by a restarting daemon.

- [ ] T026 [US2] Add a `reviseWakefulness()` call — or confirm one is already reached — on the
      path where the daemon shuts down cleanly in `Daemon.shutDown()`, so the assertion is
      let go before the process goes rather than relying on the kernel (US2-5). Belt and
      braces; T027 is the braces.

- [ ] T027 [US2] Add a comment in `Wakefulness.swift` recording that **no cleanup path, no
      persistence and no start-up sweep** is to be written for a hold left by a dead daemon:
      the kernel drops it, verified with `kill -9` in research §2. This comment is the task —
      the instinct to write that recovery code is strong and every line of it would be a
      liability (FR-013).

- [ ] T028 [US2] Add a comment at `DaemonCore+Lifetime.swift:8` on `isHoldingAgents` pointing
      at `hasWorkInFlight` and saying the two are deliberately different sets. The pair now
      exists in both directions (T014 is the other half), so neither can be "fixed" into the
      other by someone who finds only one.

**⛔ GATE — quickstart checks 2 and 4, by hand, before Phase 6.** Walk all four ending routes
and watch the `agentsd` line vanish within five seconds of each. Then, on a **scratch** copy
of the app only, `kill -9 "$(cat <scratch>/daemon.lock)"` with a turn in flight and confirm
`pmset -g assertions | grep -i agents` returns nothing, with nothing to clear up (SC-006).

**Checkpoint**: Hold and release both proven against a real agent and a real assertion. **This
is the gate the whole plan turns on — no UI work before it passes.**

---

## Phase 5: User Story 3 — A laptop on battery is not drained flat (Priority: P2)

**Goal**: On mains always; on battery only above the reserve floor; reconsidered when the
power source moves.

**Independent Test**: On battery below the floor, start an agent and confirm the Mac is
allowed to sleep. Plug in and confirm a turn in flight holds it again.

- [X] T029 [US3] Call `reviseWakefulness()` from `tickWorkflows(now:)` in
      `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`, which already
      runs every 15 seconds (`workflowTickInterval`, `:273`) and already carries a second job
      of this exact shape — it notices the local day rolling over without a timer of its own.
      **No new timer.** Research §4 records why the `notify(3)` route was rejected.

- [X] T030 [P] [US3] Add to `WakefulnessTests.swift`: with a turn in flight and
      `FakePowerSource` on battery above the floor, the hold is taken; move the fake below the
      floor, tick, and the hold is released **even though the turn is still running**
      (US3-3, FR-010).

- [X] T031 [P] [US3] Add the reverse: below the floor with a turn in flight, then back on
      mains, then tick — the hold is taken up again **without waiting for the next turn**
      (US3-4, FR-011).

- [X] T032 [P] [US3] Add: on mains at 5% battery, the hold is taken (US3-1, FR-009); and with
      `batteryPercent` nil — a desktop — the hold is taken with no battery rule applying
      (US3-5, FR-012).

- [X] T033 [US3] Confirm by reading that the 15-second tick is only ever a **backstop** for
      agent-side causes: the release on a turn ending comes from T017's `changed(_:)` call and
      is immediate. If a test has to wait 15 seconds for an agent-side change, T017 is wired
      wrong.

**Checkpoint**: The battery rules hold in tests with no hardware. Quickstart check 5 needs a
real laptop and is Alex's — see Phase 7.

---

## Phase 6: User Story 4 — You can tell why your Mac did not sleep (Priority: P3)

**Goal**: The app says it is keeping the Mac awake, says why, and says nothing when it is not.

**Independent Test**: With a turn in flight the app says so; when it ends it stops saying so;
with the battery below the floor mid-turn it says something *different* from silence.

**⚠️ Do not start this phase until the Phase 3 and Phase 4 gates have both passed by hand.**

**⚠️ `Shared/UI/TypeScale.swift` is untracked**, so the Mac scheme does not build from a clean
HEAD. T041–T043 touch `ProjectListView.swift`, which is in that lane's blast radius. Build in
the shared tree (where the file is present), and do not commit `ProjectListView.swift` hunks
that belong to the type-scale lane.

- [ ] T034 [P] [US4] Create
      `Packages/AgentsKit/Sources/AgentsKitCore/Model/WakeState.swift` with
      `DaemonAPI.WakeState` exactly as contracts/daemon-api.md specifies: `isHolding: Bool`,
      `agentsInFlight: Int`, `heldBackByBattery: Bool`, `batteryPercent: Int?`, `since: Date?`.
      `isHolding` and `heldBackByBattery` are **never both true**.

- [ ] T035 [US4] Add to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`:
      `Method.wakeState = "wake/state"` (beside `costState` at `:120`) and
      `Notification.wakeChanged = "wake/changed"` (beside `costChanged` at `:176`). **The two
      strings differ**, following the cost convention — a method is a question about state, a
      notification is news that it changed.

- [ ] T036 [US4] Add `currentWakeState()` and `broadcastWakeState()` to
      `DaemonCore+Wakefulness.swift`, mirroring `broadcastCostState()`
      (`DaemonCore+Commands.swift:491`), and call the broadcast from `reviseWakefulness()`
      **only on the change branch** — never on the early return, or a window is flooded per
      streamed token.

- [ ] T037 [US4] Add `case DaemonAPI.Method.wakeState: return .success(try JSONValue.encoding(await wakeState()))`
      to `DaemonCore+Dispatch.swift`, beside the cost cases at `:181`.

- [ ] T038 [US4] Add all three client pieces in
      `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift`: a
      `case wakeChanged(DaemonAPI.WakeState)` on `Update` (`:107`), a decoder line (`:131`),
      and an applier line setting `wakeState` (`:198`). **Missing the decoder line is the
      silent failure** — the notification simply never arrives and nothing says so.

- [ ] T039 [US4] Add `public private(set) var wakeState: DaemonAPI.WakeState?` and
      `public func replaceWakeState(_:)` to `AgentsModel`, matching `costState` /
      `replaceCostState` at `:85` and `:268`.

- [ ] T040 [US4] Add `refreshWakeState()` to `App/Sources/AppModel.swift`, modelled on
      `refreshCostState()` (`:329`) **including its tolerance of method-not-found** so a new
      window against an old daemon leaves `wakeState` nil and simply says nothing. Call it
      where `refreshCostState()` is called on connect — a window opened mid-hold has heard no
      broadcast and would otherwise show nothing for half an hour.

- [ ] T041 [US4] Add a `wakeState` passthrough to `AppModel` beside `costState` (`:57`).

- [ ] T042 [US4] Add a `WakefulnessRow` to `App/Sources/Projects/ProjectListView.swift` as a
      sibling **above** `SpendingRow` in the bottom `.safeAreaInset` (`:49`). A row of its own
      rather than a second line inside `SpendingRow`, because that row is a button into
      Spending and wakefulness is not spending. It is **absent entirely** when
      `wakeState` is nil or neither flag is set (FR-015).

- [ ] T043 [US4] Give `WakefulnessRow` its three wordings per data-model §5: holding →
      "Keeping this Mac awake" with the agent count; held back by battery → a visibly
      *different* line naming the percentage; otherwise → nothing. FR-016 exists because
      "nothing is running" and "running, but your battery is low" must not read the same, or
      the person learns nothing from either.

- [ ] T044 [P] [US4] Add a test to `WakefulnessTests.swift` that `wake/changed` is broadcast
      when the verdict moves and **not** broadcast when an unchanged `changed(_:)` runs.

**⛔ GATE — quickstart checks 6 and 7.** All three wordings by eye; a second window opened
mid-turn shows the line **immediately** (the fetch-on-connect half); and a new window against
a daemon that answers method-not-found opens normally saying nothing about sleep.

**Note on driving the app**: clicks land in whatever is in front, so check the machine is idle
and unlocked before driving a scratch copy, and prefer `daemon.sock` for anything not visual.

---

## Phase 7: Polish & Cross-Cutting

- [ ] T045 [P] Run the full package suite in a detached worktree:
      `git worktree add --detach /tmp/wake HEAD`, copy your files in,
      `swift test --package-path /tmp/wake/Packages/AgentsKit`. Expect
      `DaemonTests.stoppingAnAgentBeforeItIsPickedUpWithdrawsIt` to fail on `launchCount == 1`
      — it is **pre-existing and not this feature's**. Any other failure is yours.

- [ ] T046 [P] Build both schemes sequentially with
      `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build`
      and the same for the Remote scheme. The flag is needed because SwiftTerm ships a
      build-tool plug-in and `xcodebuild` has nobody to ask about trusting it — without it you
      get three unexplained build commands and no useful error.

- [ ] T047 Re-read `hasWorkInFlight`, `isHoldingAgents` and `AgentState.hasTurnInFlight`
      together and confirm all three carry comments pointing at the other two. Three
      near-identical predicates with three different answers for `waitingOnUser` is the single
      most likely place this feature is broken by a later change.

- [ ] T048 [P] Confirm nothing was persisted: no new file under
      `~/Library/Application Support/Agents/`, no new key on `agent.json`, nothing about the
      hold surviving a restart. If any appeared, delete it — FR-013 and data-model "What is
      deliberately absent".

- [ ] T049 [P] Confirm no agent-facing surface changed: no new MCP tool, no change to
      `show_file` / `manage_workflows` / the briefing. An agent has no business knowing whether
      the Mac is held awake for it.

- [ ] T050 Quickstart check 5 — **the battery walk, and Alex's.** Needs a real laptop taken
      below 20% on battery with a turn in flight, and plugged back in. `FakePowerSource`
      covers the truth table; this covers the real IOKit reading and nothing else can. Record
      the result in the notes below.

- [ ] T051 Write the Implementation Notes section at the foot of this file: what was amended
      after the fact and why, following the pattern at the foot of 020's and 022's tasks.md.

---

## Dependencies & Execution Order

```
Phase 1 Setup
    ↓
Phase 2 Foundational  ← blocks everything
    ↓
Phase 3 US1 (hold)  ──⛔ GATE: pmset, by hand ──┐
    ↓                                           │
Phase 4 US2 (release) ─⛔ GATE: pmset + kill -9 ┤
    ↓                                           │
Phase 5 US3 (battery)                           │
    ↓                                           │
Phase 6 US4 (UI)  ←─────────────────────────────┘ blocked until both gates pass
    ↓
Phase 7 Polish
```

### Where this departs from "stories are independent"

**US4 is deliberately not independent**, and that is the point of the plan. The UI is worth
nothing if the assertion is wrong, and the assertion is fully observable from
`pmset -g assertions` without a single line of UI. So US1 and US2 must both be **walked by
hand against a real agent** before Phase 6 begins — not merely passing their unit tests.

US1, US2 and US3 are genuinely independently testable, and US3 could be built before US2 if
somebody wanted battery handling first. US2 adds almost no production code — it is the tests
that prove the release paths, which is where a feature like this fails silently.

### Parallel opportunities

- **Phase 2**: T003, T006, T008, T010, T011 are four different files — all parallel.
- **Phase 4**: T023, T024, T025 are separate test functions in one file; parallel if written
  as separate additions, sequential if one person is editing.
- **Phase 5**: T030, T031, T032 likewise.
- **Phase 6**: T034 (Core model) is parallel with nothing else until T035 lands.
- **Phase 7**: T045, T046, T048, T049 are all parallel.

---

## Implementation Strategy

### MVP

Phases 1–4. That is a Mac that stays awake for working agents, gives itself back promptly,
and says nothing about any of it. It is shippable on its own and it is the whole of the
value — the spec's US1 is explicit that everything else is about giving the wakefulness back.

### Then

Phase 5 makes it safe on a laptop. Phase 6 makes it honest. Neither changes what it does.

### Do not

- Reuse `isHoldingAgents` (holds all night for an unanswered question).
- Hook `move` instead of `changed(_:)` (misses every agent's `starting` moments).
- Write a cleanup path for a hold left by a dead daemon (the kernel already did it).
- Add a C shim for `notify(3)` power events (the 15-second tick is ample; research §4).
- Add `.idleDisplaySleepDisabled` (breaks FR-007).
- Build any of Phase 6 before both gates pass.

---

## Out of scope — do not "fix" these if you see them

All verified or reasoned in research and repeated in quickstart:

- Closing the lid sleeps the Mac mid-turn. A power assertion cannot survive it.
- Apple menu → Sleep sleeps the Mac mid-turn. The person's instruction wins.
- The screen dims and locks while agents work. FR-007; that is the intent.
- A sleeping Mac is not woken for a scheduled workflow. An assertion keeps an awake Mac
  awake; it cannot rouse a sleeping one.
- A long build in a terminal does not hold the Mac. A build is not a turn — noted in
  research §6 as the obvious follow-up, deliberately not in this feature.

---

## Notes

- Total: 51 tasks. US1 10, US2 6, US3 5, US4 11, plus 12 setup/foundational and 7 polish.
- Commit after each phase, splitting by hunk — three lanes share this tree.
- T050 is Alex's; everything else can be done from here.

---

## Implementation Notes — Phases 1–3, 2026-09-24

Built in a worktree (`/tmp/024`, branch `024-keep-host-awake`) off `a04480b`. T001–T022 done.
**20 new tests pass** (12 unit, 8 integration); the full package suite is **1130 tests**.

### The Phase 3 gate, walked

Driven against a real `claude` runtime on a scratch daemon with its own root
(`AGENTS_ROOT=/tmp/a24`), over `daemon.sock` — no GUI, and the daemon hosting these
sessions never touched. Three real agents:

```
t=3s   states=RRR    idle-sleep-assertions=1  display-sleep=0  Agents: a turn is in flight
...
t=18s  states=FFR    idle-sleep-assertions=1  display-sleep=0  Agents: a turn is in flight
t=19s  states=FFF    idle-sleep-assertions=0  display-sleep=0
```

and the raw line, single agent:

```
pid 35605(agentsd): [0x0009701200019fac] 00:00:24 PreventUserIdleSystemSleep
    named: "Agents: a turn is in flight"
```

Exactly one assertion across three overlapping agents; gone within a second of the last
one finishing; `PreventUserIdleDisplaySleep` never named `agentsd` (FR-007). The daemon log
shows both halves — `holding the Mac awake: 3 agent(s) mid-turn` /
`letting the Mac sleep: nothing is mid-turn`.

### Two things the gate found, both fixed

**1. The count in the assertion reason went stale (T016 amended).** The reason was
`"Agents: N agents are mid-turn"`, and with three real agents it read **"1 agent"**.
`reviseWakefulness` acts only when the *verdict* moves, and the verdict is `.hold` whether
one agent works or five — so the count was written once, by whichever agent started first.

Keeping it true would mean ending the assertion and beginning another whenever the count
changed: a swap in the one place a gap must never open, bought for a number in a diagnostic
tool. The reason is now count-free — `"Agents: a turn is in flight"` — which is the most it
can always say truthfully. **The count belongs in `WakeState.agentsInFlight` (Phase 6)**,
which is broadcast and can be re-sent freely, and the daemon log carries it meanwhile.

**2. IOKit was in the hot path (T015 amended).** `reviseWakefulness` read the power source
on every call, and it is called from `changed(_:)` — which runs on **every streamed token**
and is isolated to the `DaemonCore` actor. A read measures **65 µs**, so every agent's
updates would have queued behind a synchronous IOKit call made for another agent's token.

Now the cheap in-memory answer is computed first and the read is skipped unless it could
change anything: no work in flight → `.idle` with no read at all; work in flight with a
power-informed verdict already in hand → return. `reviseWakefulness(readingPower:)` gained a
parameter for the 15-second tick to force a fresh read — **Phase 5 (T029) must pass
`readingPower: true`**, or a power change is never noticed.

### Added beyond the task list

A `deinit` on `ProcessInfoWakefulness` that ends an outstanding activity. Not for
production — there is one core per process there — but every existing test constructs a
`DaemonCore` without injecting, so each gets a real holder, and a core let go mid-suite
would otherwise keep the developer's Mac awake for the life of the test process. The
*absence* of a start-up sweep is still deliberate and commented (FR-013).

### Pre-existing failures, confirmed not ours

Ran the full suite at clean `a04480b` in a throwaway worktree. It fails
`InterruptionTests.eachNewProcessIsCountedFromNothing` (launchCount, passes alone) **and**
`DaemonTests.aStoppedAgentIsPickedUpRatherThanCopied`. The branch shows the first and not
the second — fewer failures than its base.

### Notes for whoever picks up Phase 4

- The release paths are already exercised by T023–T025's subject matter in the Phase 3
  tests (`waitingOnAPersonDoesNotHold`, `stoppingReleases`), so Phase 4 is thinner than it
  looks. What is genuinely missing is the process-died and found-dead cases, and T026–T028.
- Driving a real agent over the socket needs `cwd` as a **file URL** (`file:///...`). A bare
  path decodes to a non-file `URL` and **crashes the daemon** in `NSTask.currentDirectoryURL`.
  That is a pre-existing robustness gap in the start path, not this lane's, and worth its own
  fix — an unvalidated field from the socket should not be able to take the daemon down.
- `env -i` is too aggressive for a runtime that must authenticate; use `env -u CLAUDE_… -u …`
  to scrub just the session variables and keep the rest.


---

## Implementation Notes

### Phases 1–3 built and walked, 2026-09-24

Worktree `/tmp/024` on branch `024-keep-host-awake`, off `a04480b`. T001–T022 done.
**1130 tests pass** in the package suite. Both gate checks for Phase 3 walked against a real
Claude agent on a scratch daemon (`--root /tmp/a24`), never the one hosting these sessions.

**The gate, as observed.** Three agents in flight at once:

```
pid 43582(agentsd): [0x000973570001a558] 00:00:11 PreventUserIdleSystemSleep
    named: "Agents: a turn is in flight"
```

- peak agents in flight: **3**; peak `agentsd` idle-sleep assertions: **1** (FR-006)
- `PreventUserIdleDisplaySleep` from `agentsd`: **never, in any sample** (FR-007)
- one hold (14:58:00) and one release (14:59:33) spanning all three agents
- released within **1 s** of the last turn ending (FR-004), across several runs

### What the walk changed

**The count in the assertion reason had to go.** The first version read
`"Agents: 2 agents are mid-turn"`. With three real agents running it said **"1 agent"** —
because `reviseWakefulness` acts only when the *verdict* moves, and the verdict is `.hold`
whether one agent works or five. The count was written once, by whichever agent started
first, and then went stale.

Keeping it true would mean ending the assertion and beginning another every time the count
changed: a swap in the one place a gap must never open, bought for a number in a diagnostic
tool. So the reason now says only what it can always say truthfully —
`"Agents: a turn is in flight"` — and the same correction was applied to the daemon log
line. A standing count belongs in `WakeState.agentsInFlight` (Phase 6), which is broadcast
and can be re-sent freely.

This is the kind of thing only a walk finds: every unit test passed with the stale count,
because each one had exactly one agent.

**A `deinit` was added to `ProcessInfoWakefulness`.** Running the suite left real
assertions on the developer's Mac: tests that build a `DaemonCore` without passing
`wakefulness:` get the real one, and an abandoned holder inside a *live* process is not
something the kernel cleans up — it only drops assertions when the process **dies**. This is
a different case from T027's forbidden cleanup path, and needs the opposite treatment. In
production there is one core per process and it never fires before exit.

### Phase 4 arrived early

`WakefulnessTests` already carries the release cases (T023–T025): a turn ending, an agent
stopped by hand, an agent blocked on a person, and answering the question putting the hold
back. Phase 4 is therefore mostly done; **T026–T028 remain** (the `shutDown()` call, the
no-cleanup comment, and the `isHoldingAgents` back-reference).

### Notes for whoever picks this up

- **`env -i` breaks the runtimes.** Launching `agentsd` with a stripped environment gives
  `Error(code: -32000, message: "Authentication required")` and every agent dies as
  `processDied`. The memory note about `env -i` is about `open`-ing the **app** so this
  session's `CLAUDE_*` does not leak into the daemon; for a direct `agentsd` launch, pass
  the real environment with just the `CLAUDE_*` names unset:
  `env $(env | grep -o '^CLAUDE_[A-Z_]*' | sed 's/^/-u /') …/agentsd --root /tmp/a24`.
- **`cwd` must be a `file://` URL** when driving `agents/start` over the socket by hand. A
  bare path decodes to a non-file `URL` and the daemon dies in `NSTask` with
  `'*** -[NSConcreteTask setCurrentDirectoryURL:]: non-file URL argument'`. That is a
  hand-driving hazard, not a product bug — the app always sends a file URL.
- **Three concurrent cold `npx` starts collide.** Stagger them a few seconds apart or the
  runtimes die before any turn begins.
- `DaemonTests.aStoppedAgentIsPickedUpRatherThanCopied` fails on `launchCount == 2`. Checked
  against a pristine worktree at HEAD with none of this branch's changes: **it fails there
  identically.** Pre-existing, not 024's.
- `xcodegen generate` is **not** needed for AgentsKit sources — the package picks files up by
  directory and the pbxproj does not list them. T002's concern applies only to `App/`.


### Phase 5 built, 2026-09-24

T029–T033 done. 14 tests in `WakefulnessTests`, 1161 in the package; three of four full
runs clean, the fourth only the known pre-existing flakes
(`aStoppedAgentIsPickedUpRatherThanCopied`, `andNotAgainOnEveryPromptAfterThat`). Both
schemes build.

**T029's call goes at the very top of `tickWorkflows(now:)`, above the
`guard let since, since < now else { return }`.** That guard returns on the first tick
after starting and whenever the clock has not moved, and neither has anything to do with
the battery — below it, a Mac unplugged in the first fifteen seconds stays held until the
tick after. The obvious placement, next to the day-rollover block, would have been wrong in
a way no test written from the task text would have caught.

**The battery tests assert the state *before* the tick as well as after.** Held, then
unplugged, then *still held*, then ticked, then released. Without that middle assertion the
test would pass just as happily if the hold had been dropped for an unrelated reason, and
would not actually be guarding the wiring T029 adds. Same shape in reverse for plugging in.

T033 is an assertion rather than a reading: `theTickIsOnlyABackstop` proves the release on a
turn ending has already happened with no tick at all. If that ever needs a tick, FR-004's
five seconds is being met by a fifteen-second timer, which is to say not met.

Still open: Phase 4's T026–T028, Phase 6 (the UI), Phase 7. **T050, the battery walk on a
real laptop below 20%, remains Alex's** — `FakePowerSource` covers the truth table and the
tick wiring; only hardware covers the real IOKit reading.
