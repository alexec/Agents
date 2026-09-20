# Implementation Plan: An Agent Being Born Is Not a Finished One

**Branch**: `020-agent-lifecycle` | **Date**: 2026-09-19 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/020-agent-lifecycle/spec.md`

## Summary

One new state, one changed return type, and two gates on the record.

`AgentState` gains `starting`, so a new agent stops having to claim an ending it never had.
`AgentState.applying` returns a `Transition` — the next state *plus* what to write — instead
of a bare state with the reason passed alongside it, so no caller can record an ending that
contradicts its own event. `recover()` stops writing state directly and calls the event the
table has had all along and nothing has ever used. `AgentStore` starts enforcing the four
invariants that are currently asserted only in tests.

The hard part is none of those. It is that `Daemon.start()` runs `recover()` *before*
`startWorkflows()`, deliberately, so routing recovery through the funnel would fire triggers
into a workflow layer that does not exist yet — trading a visible bypass for an invisible
one. The answer is that `move` always emits its event and the workflow layer holds what
arrives before it is ready.

The other thing worth knowing up front: adding a case to `AgentState` breaks **11**
exhaustive switches. That is the feature working — the compiler enumerates the callers,
which is exactly what nobody did when the state was implicit. **Two further switches have
a `default:` and compile silently**, which is how a new state gets the wrong tint, or is
told something false about its own history. Both are named in the risk table below.

*(Corrected after implementation: this plan said 10 and named one silent switch. The
eleventh exhaustive one is `PromptBar.swift`, which every survey missed because it groups
`.running, .waitingOnUser` on a single line and each survey grepped for
`case .waitingOnUser`. The second silent one is `wordsAboutTheRestart`.)*

## Technical Context

**Language/Version**: Swift 6.2 (`swift-tools-version: 6.2`)

**Primary Dependencies**: None new. `AgentsKitCore` (model, shared by daemon and both apps),
`AgentsKit` (daemon)

**Storage**: The record at `<root>/agents/<uuid>/agent.json` and its `transcript.jsonl`.
No new field, no migration

**Testing**: swift-testing (`@Suite` / `@Test` / `#expect`), one target —
`Packages/AgentsKit/Tests/AgentsKitTests`. `FakeLauncher` / `FakeACPAgent` exercise the whole
daemon with no runtime installed

**Target Platform**: macOS 27, iOS 27

**Project Type**: Desktop app plus companion iOS app, one shared model package, XcodeGen

**Performance Goals**: None. `applying` is pure and called once per state change; the store
gate is four comparisons on a write that already encodes and writes a whole file

**Constraints**: `AgentsKitCore` must not gain `import SwiftUI` — `agentsd` links it.
`DaemonCore` is an actor, so a refused transition must not have written anything before its
first `await`. `recover()` runs before the socket opens and before workflows are read.
Neither app has a test target, so anything to be tested must live in the package

**Scale/Scope**: 1 new state, 1 new event, 1 new return type, 11 exhaustive switches to
answer for and 1 silent one to find by hand, 2 store gates, 1 bypass to close

## Constitution Check

`.specify/memory/constitution.md` is an unfilled template — every principle is still a
`[PRINCIPLE_N_NAME]` placeholder. There are no ratified gates to evaluate, so none are
claimed as passed.

In their place, the conventions this codebase visibly holds itself to, and how this plan
stands against them:

| Convention, as practised | This plan |
| --- | --- |
| Derive, never store, so two things cannot disagree (`AgentGroup`) | Nothing new is stored. `Transition` is computed and thrown away; `clearsPickUpCount` becomes derived where it was an inline `if` |
| Totality, proved by exhausting it in a test (`AgentGroup`, `AgentState`) | 60 pairs, every one decided, exhausted by test (SC-003) |
| The rule lives in one place, because two copies are two chances to drift (019's whole subject) | The reason an agent ended is expressed once, in the event. The pick-up rule moves out of `move` into the table |
| Wording lives in the model, not the view (`EndedReason.summary`, `WorkOutcome.heading`) | "Starting" is defined once in `AgentsKitCore` |
| An unaccounted ending is never a completion (014) | A state from a newer build opens as `unrecognised`, never as `finished` |
| The record before the windows (`DaemonCore.changed`) | Unchanged, and now true of recovery too, which writes by hand today |
| A comment says why, not what | Every comment that currently explains a bypass is deleted with the bypass, not reworded |

**One tension worth naming.** FR-020 says a forbidden record is mended on read. That is a
write the person did not ask for, against a convention this app otherwise keeps — it does
not quietly change records. It is taken because the alternative is the failure being fixed:
`loadAll` already drops a record it cannot decode, and an agent a person cannot see is one
they can do nothing about. The mend is always announced in the transcript, which is where
this app already explains itself.

## Project Structure

### Documentation (this feature)

```text
specs/020-agent-lifecycle/
├── plan.md                      # This file
├── research.md                  # Phase 0: what the scar tissue is, and 8 decisions
├── data-model.md                # Phase 1: the state, the events, the Transition, the gates
├── contracts/
│   ├── transitions.md           # All 60 pairs, and what the daemon does with one
│   └── record-and-wire.md       # The record format, the invariants, compatibility
├── quickstart.md                # How to run it, what proves what, four checks by hand
├── checklists/requirements.md
└── tasks.md                     # NOT created by /speckit-plan
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/Model/
├── AgentState.swift             # + starting; + turnBegun;
│                                #   applying → Transition; + Transition, ReasonChange,
│                                #   ArchiveChange
├── Agent.swift                  # init defaults to starting with no ending;
│                                #   isConsistent gains rule 4; lenient state decoding
└── AgentGroup.swift             # + case .starting → .running

Packages/AgentsKit/Sources/AgentsKit/
├── Store/AgentStore.swift       # save refuses a forbidden record; load mends one
└── Daemon/
    ├── DaemonCore.swift         # move loses its endedReason: parameter and its three
    │                            #   inline special cases; emits its event always
    ├── DaemonCore+Recovery.swift # the direct write becomes move(_:on: .foundDead)
    ├── DaemonCore+Commands.swift # create stops passing state:/endedReason:;
    │                            #   beginTurn fires turnBegun from starting;
    │                            #   stop stops pre-writing endedReason;
    └── DaemonCore+Workflows.swift # holds lifecycle events until startWorkflows drains

App/Sources/                     # 5 exhaustive switches answer for .starting, and
                                 #   AgentRow.swift:178 (default:) must be found by hand
Remote/Sources/                  # 4 exhaustive switches answer for .starting

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/AgentStateTests.swift   # 60 pairs exhausted
├── Unit/AgentGroupTests.swift   # mapping stays total
├── Unit/AgentStoreTests.swift   # the gates, both directions
├── Unit/LegacyRecordTests.swift # a state from a newer build
├── Integration/WorkflowFiringTests.swift  # a restart fires what was waiting
└── Integration/ + Unit/         # new: the birth suite, the source scan
```

**Structure Decision**: no new module, no new file beyond tests. Every change lands in a
file that already exists, because every one of them is removing a second way of doing
something rather than adding a first.

## Approach, in the order it should be built

Four slices. Each is independently shippable, and they map to the spec's three stories plus
the plumbing the second one needs.

### Slice 0 — `Transition` (no behaviour change)

`applying` returns a `Transition` instead of `AgentState?`; `move` reads it. The reason and
the archive reason move from `move`'s parameters and inline `if`s into the returned value.
`clearsPickUpCount` moves out of `DaemonCore.swift:242` into the table.

Nothing a person can see changes. This exists so the next three slices are small.

**Done when**: all 45 existing pairs behave exactly as before, and `move` has no
`if next ==` left in it.

### Slice 1 — `starting` (US1, P1)

The new state, its two events, its group, its invariant, its word. The create path at
`DaemonCore+Commands.swift:149` stops passing `state:` and `endedReason:`. `beginTurn` fires
`turnBegun` when the agent is `starting` and `promptSent` otherwise. A failed start becomes
The 11 exhaustive switches answer for it, and `AgentRow.swift:178` is
visited by hand.

**Done when**: an agent is never in a group other than Working between being made and its
first turn, and its record carries no ending (SC-001, SC-002).

### Slice 2 — closing the hole (US2, P2)

`recover()` calls `move(id, on: .foundDead)` and deletes its hand-written state change. The
workflow layer holds lifecycle events that arrive before `startWorkflows()` and drains them
in order. `move` suppresses an ending trigger for an agent that will be picked back up,
using `mayBePickedUpAfterRestart`.

**Done when**: a `stopped` workflow fires for a daemon-restart ending that is final, and
does not for one about to be picked back up (SC-005).

### Slice 3 — the gates (US3, P3)

`AgentStore.save` refuses and logs. `AgentStore.load` mends and reports. `Agent.init(from:)`
decodes an unknown state leniently. The source scan that keeps SC-009 true.

**Done when**: no forbidden record reaches disk, a hand-broken one opens and says it was
mended, and a record from a newer build loses no agent (SC-006, SC-007, SC-008).

## Things that will bite

Named here so they are not discovered late.

| Risk | Where | What to do |
| --- | --- | --- |
| Firing triggers into a workflow layer that is not started | `Daemon.swift:31` runs `recover()` before `startWorkflows()` | Defer and drain in order (research D4). A test must prove the deferred event actually arrives, or this silently does nothing |
| `stop` writes `endedReason` before its first `await`, outside the table | `DaemonCore+Commands.swift:729` | The write moves into the transition. The comment explaining why it was pre-written describes a race that `sending`/`turnTasks` also guard — re-read it before deleting |
| `stop` then re-reads a stale local `agent` across several `await`s | same function | Out of scope to fix, but do not make it worse. The table already refuses the second ending |
| Unarchiving an agent with no recorded ending lands on `stopped` with no reason | `AgentState.swift:117` | Unreachable today; becomes a store-gate failure once the gate exists. The contract sets `unrecognised` |
| An older build meeting a `"starting"` record drops the agent | `Agent.init(from:)` in builds predating this one | Accepted and written down in `contracts/record-and-wire.md`. The lenient decode makes this the last time |
| 10 compile errors look like a large diff | `App/Sources`, `Remote/Sources` | They are one line each. Do not take the chance to tidy the surrounding switches — that is 018's |
| One switch will *not* break: `AgentRow.swift:178` has `default: return .secondary` | `App/Sources/AgentList/AgentRow.swift:178` | A new state silently gets the secondary tint. Visit it by hand; the compiler will not ask |
| **A second switch will not break either**, and this plan missed it | `DaemonCore+Recovery.swift:149` | `wordsAboutTheRestart` switches `AgentState` with a `default:`. `recover` filters on `holdsRuntime`, which now includes `starting`, so an agent cut off before its first turn would be told "the turn you were in the middle of was cut off… everything above is still yours" when it had neither. Give it its own arm |
| **An eleventh exhaustive switch**, not in the count above | `App/Sources/Chat/PromptBar.swift:598` | Every survey here grepped for `case .waitingOnUser`, and this one groups `.running, .waitingOnUser` on a single line. Unreachable for `.starting` because of the `hasTurnInFlight` guard above it, but the compiler still asks |

## Complexity Tracking

No Constitution Check violations to justify — there is no ratified constitution. The one
judgement call that goes against a convention this app otherwise keeps (mending a record on
read) is argued in the Constitution Check above rather than hidden here.

Net effect on complexity is negative: one enum case and one struct added; one function
parameter, three inline special cases in `move`, one hand-written state change in `recover`,
and one dead event removed.
