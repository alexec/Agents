# Implementation Plan: The Mac Stays Awake While Its Agents Work

**Branch**: `024-keep-host-awake` | **Date**: 2026-09-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/024-keep-host-awake/spec.md`

## Summary

While any agent is mid-turn, `agentsd` holds one `PreventUserIdleSystemSleep` assertion, and
it holds it at no other time. The verdict is derived — never commanded and never stored —
from two inputs: whether any agent is `starting` or `running`, and what the machine says
about its own power. A small `wake/state` notification puts the same fact on screen.

The shape of the work is a pure function, two injected protocols, three call sites and one
line in the sidebar footer. It is small, and the reason it is small is that every hard part
turned out to be either already built or free:

- The assertion **works from a non-GUI helper** and carries our reason string into
  `pmset -g assertions`. Verified in a spike, not assumed.
- The assertion **dies with the process**, so FR-013 needs no cleanup path and no
  persistence — verified with `kill -9`.
- `DaemonCore.changed(_:)` is already the one funnel every agent write passes through, so
  FR-004's five seconds is met by construction rather than by a timer.
- `cost/state` is an exact working precedent for a derived daemon fact on screen, including
  the fetch-on-connect and old-daemon tolerance that are easy to forget.

The one design decision with teeth is the narrowness. `DaemonCore.isHoldingAgents` already
exists, is one line away, and is the **wrong** set — it counts an agent blocked on a person,
which is precisely what FR-003 forbids. Reusing it would hold the Mac awake all night for an
unanswered question. The plan keeps the two apart deliberately and comments both.

## Technical Context

**Language/Version**: Swift 6, strict concurrency

**Primary Dependencies**: Foundation (`ProcessInfo.beginActivity`), IOKit.ps
(`IOPSCopyPowerSourcesInfo`). No new package dependency, no new build target, no
entitlement.

**Storage**: None. Nothing about this feature is persisted, by design — see
[data-model.md](./data-model.md). No new file under
`~/Library/Application Support/Agents/`, no new key on `agent.json`.

**Testing**: `swift-testing` via `swift test --package-path Packages/AgentsKit`. Two new
fakes (`FakePowerSource`, `RecordingWakefulness`) joining the existing injection seam on
`DaemonCore.init`. No hardware needed for any automated test.

**Target Platform**: macOS 27. The daemon is `agentsd`, a non-GUI helper inside the app
bundle at `Contents/Helpers/agentsd` that ends in `dispatchMain()` — which rules out any
`RunLoop`-based API (see [research.md](./research.md) §4).

**Project Type**: macOS desktop app plus a helper daemon. This feature is almost entirely in
the daemon; the app's share is one derived property and one line of UI.

**Performance Goals**: `reviseWakefulness()` is called from `changed(_:)`, which runs on
every token of streamed output. It must be O(agents), allocation-free in the common case, and
must return without acting — and without broadcasting — when nothing moved. Idempotence is
the load-bearing property of the whole design.

**Constraints**: At most one assertion, ever (FR-006). Released within 5 s of the last turn
ending (FR-004) — met inside the same call, not by a timeout. Power re-read on the existing
15 s workflow tick; no new timer.

**Scale/Scope**: Two new files in AgentsKit, one new type in AgentsKitCore, edits to four
existing files, one UI line. Roughly 250 lines including tests.

## Constitution Check

`.specify/memory/constitution.md` is **an unfilled template** — every principle is still
`[PRINCIPLE_N_NAME]` with its placeholder description. There are no ratified gates to check
against, so this section cannot pass or fail on its own terms, and no violation is claimed
or excused by it.

In its place, the standing conventions this codebase actually holds itself to, and how this
plan stands against each:

| Convention | Where from | This plan |
|---|---|---|
| One decider per fact; no second copy of a rule | 019, and `DaemonCore+Attention` | One `Wake.verdict`. The window is told, and never works it out. |
| Derived, not stored, when the fact is about right now | 021's `presences` | Nothing persisted; verdict re-derived at every call. |
| The daemon decides; surfaces report and display | 021 FR-012 | The app holds nothing and decides nothing. |
| Injected seams over mocks of the thing under test | `DaemonCore.init(launcher:now:thresholds:mailbox:)` | `PowerSource` and `Wakefulness` injected; the agent lifecycle is driven for real. |
| Verify against the machine, don't assume | 005's research | Three claims spiked before planning; one route rejected *because* it could not be verified. |
| Say the limits plainly rather than working around them | 005 §10 | Lid close, explicit sleep and dark wake are named as out of scope in spec, quickstart and research. |

**Gate: pass**, with the note that the gate is conventional rather than constitutional.
Filling in the constitution is not this feature's job and is not blocked by it.

## Project Structure

### Documentation (this feature)

```text
specs/024-keep-host-awake/
├── spec.md              # Phase -1
├── plan.md              # This file
├── research.md          # Phase 0 — three spikes, one rejected route
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1 — seven checks
├── contracts/
│   └── daemon-api.md    # Phase 1 — wake/state, one method, one payload
├── checklists/
│   └── requirements.md  # from /speckit-specify
└── tasks.md             # NOT created here — /speckit-tasks
```

### Source code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/
│   └── WakeState.swift              NEW  DaemonAPI.WakeState
├── Daemon/DaemonAPI.swift           EDIT Notification.wakeState, Method.wakeState
└── Client/AgentsModel.swift         EDIT wakeState property + wake/state handling

Packages/AgentsKit/Sources/AgentsKit/
├── Power/
│   ├── PowerSource.swift            NEW  protocol, IOKitPowerSource, PowerReading
│   ├── Wakefulness.swift            NEW  protocol, ProcessInfoWakefulness
│   └── Wake.swift                   NEW  WakeVerdict + the pure verdict function
└── Daemon/
    ├── DaemonCore.swift             EDIT init takes power/wakefulness; changed() calls revise
    ├── DaemonCore+Wakefulness.swift NEW  hasWorkInFlight, reviseWakefulness, broadcast
    ├── DaemonCore+Workflows.swift   EDIT tickWorkflows re-reads power
    ├── DaemonCore+Dispatch.swift    EDIT wake/state method
    ├── DaemonCore+Lifetime.swift    EDIT comment only — points at the neighbour
    └── Daemon.swift                 EDIT one revise call at the end of start()

App/Sources/
├── AppModel.swift                   EDIT wakeState passthrough + fetch on connect
└── Projects/ProjectListView.swift   EDIT the footer line

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/WakeVerdictTests.swift      NEW  the truth table, both sides of the floor
└── Integration/WakefulnessTests.swift NEW real starts/turns/stops through DaemonCore
```

**Structure Decision**: The existing layout, unchanged. The three new source files go in a
new `Sources/AgentsKit/Power/` group because they are about the machine rather than about
agents, and none of them imports `DaemonCore`. The daemon's use of them is one extension
file, matching the `DaemonCore+Attention` / `DaemonCore+Devices` pattern this package
already uses for a self-contained concern.

`Wake.swift` is in AgentsKit and not AgentsKitCore because nothing in the app or the remotes
needs to compute a verdict — only to be told one. `WakeState` is in Core because it crosses
the wire.

**Note for whoever implements**: `xcodegen generate` is needed after adding source files —
the pbxproj is generated and lists files explicitly.

## Phase ordering

Four slices. The first is the feature; the rest are the promises around it.

| Slice | What | Requirements | Gate |
|---|---|---|---|
| **A** | `PowerReading`, `Wakefulness`, `Wake.verdict`, and their unit tests | FR-002, FR-008–FR-012 | Truth table green with no daemon involved |
| **B** | `hasWorkInFlight`, `reviseWakefulness()`, the three call sites | FR-001, FR-003–FR-006, FR-014 | **Quickstart checks 1–4 by hand.** This is the feature; do not build C or D until a real agent holds and releases a real assertion. |
| **C** | `wake/state` — payload, notification, method, model, fetch-on-connect | FR-015 (wire half) | Second window mid-turn shows it at once |
| **D** | The footer line, all three wordings | FR-015, FR-016 | Quickstart check 6 |

FR-017 (recording when the hold is taken and let go) rides along in Slice B as two
`DaemonLog.shared.write` lines — the daemon's log is where this belongs, not the transcript:
it is a fact about the machine, not about any one agent's conversation.

Slice B's gate is the real one. Slices C and D are worth nothing if the assertion is wrong,
and the assertion is observable from `pmset` without a single line of UI.

## Risks, and what is done about each

| Risk | Why it matters | What the plan does |
|---|---|---|
| Reusing `isHoldingAgents` | Would hold the Mac awake all night for an unanswered question — the one abuse the spec names | A separate narrow predicate; a comment at **both** saying why they differ, so neither is "fixed" into the other |
| `hasTurnInFlight` looks right and is not | It includes `waitingOnUser` by design, for a different question | Cross-reference comment on both; the unit test walks all six states |
| Broadcast flood | `changed(_:)` runs per streamed token | `reviseWakefulness()` compares before acting; an explicit test that an unchanged call broadcasts nothing |
| Holding after the last turn | The trust-destroying failure, and silent | Release is in the same call as the ending; the 15 s tick is a backstop; quickstart check 2 walks all four ending routes |
| Inventing persistence for FR-013 | Cleanup code here would be pure liability | Verified the kernel drops it; data-model and quickstart both say not to write it |
| Agent created outside `move` | A hook on `move` alone misses every agent's first moments | Hook on `changed(_:)`, the wider funnel — reasoned out in research §5 from the actual call sites |

## Complexity Tracking

No constitution gates exist to violate. Two choices that *add* nothing are worth recording,
because in each case the more elaborate option was examined and put down:

| Considered | Rejected because |
|---|---|
| A `notify(3)` C shim for instant power events | Needs a new C target in `Package.swift`; registration verified but **delivery could not be**; the existing 15 s tick is ample for a battery reserve. Written up in research §4 if ever needed. |
| Persisting the hold + a start-up sweep | The kernel already drops it on death (verified). Persistence could only ever mislead the next daemon. |
