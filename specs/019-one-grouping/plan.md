# Implementation Plan: One Grouping, and Everything Agrees With It

**Branch**: `main` (three lanes share one tree; see the 020 notes) | **Date**: 2026-09-20 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/019-one-grouping/spec.md`, planned after 020 landed (`ce65026`), because 020 rewrote the state machine this grouping reads.

## Summary

The rule is right and lives in one place already — `AgentGroup.init(for:wantsEyes:report:)`
at `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift:64`. What is wrong is
how it is reached. Two of its three facts have defaults, so a caller that cannot know
whether an agent asked to be looked at gets "no" for free — and the daemon's project
counts take exactly that free answer (`DaemonCore+Projects.swift:47`, through
`Agent.group` at `AgentGroup.swift:101`), while the window's panel supplies the real one
(`AgentsModel.group(of:)` at `AgentsModel.swift:300`). The badge and the list disagree
because one of them was allowed not to say.

Three changes, all small:

1. **No defaults, one funnel.** The initialiser takes every fact and none of them defaults.
   `Agent.group` — the derivation that quietly said "no eyes" — goes, and in its place is
   `Agent.group(wantsEyes:)`, which every caller must call with an argument. There is
   then exactly one place that decides a group and one way to ask it (FR-001, FR-004).
2. **The window completes the count.** The daemon still ships `ProjectSummary.counts`,
   computed with `wantsEyes: false` said out loud, because it has no window and stores
   nothing for one (the spec's first edge case). The Mac window does not read those
   counts: it derives its own from `group(of:)` over the agents it already holds, so
   the number on the row is the number of rows under the heading by construction
   (FR-006, FR-007, FR-009). "Needs a person" becomes `counts[.needsAttention] > 0` and
   nothing else (FR-008), which retires `wantsEyes(in:)` — the check that never looked at
   state (FR-011, FR-012). The phone, which cannot show a file and so has nothing unseen,
   keeps the daemon's counts; for it they are complete.
3. **The app's own question is not work.** The grouping gains the fact the daemon already
   keeps for exactly this distinction: `outcomeAsked`, which the app's question leaves
   set and only a person's prompt clears (`DaemonCore+Commands.swift:346`). An agent
   that is `running` with `outcomeAsked` is answering the app, and stays under Complete
   (FR-014, FR-018). A person's prompt clears the flag and the same agent is Working
   (FR-016). An agent that never answers ends `finished` with the flag still set, which
   is the unaccounted ending 014 already draws (FR-017).

The spec's key-entities list says this feature adds no fact to the grouping. It adds
`outcomeAsked`. That is the fact FR-018 names, it already exists on the record, and the
alternative — a second flag set alongside it — is the thing FR-018 forbids. The exhaustive
test grows from `6 × 2 × reports` to `6 × 2 × reports × 2`, and that is the whole cost.

## Technical Context

**Language/Version**: Swift 6.2

**Primary Dependencies**: None new. `AgentsKitCore` (the rule, the window model),
`AgentsKit` (the daemon's counts), both apps (the readers)

**Storage**: Nothing. The group stays derived and unstored (FR-003); `outcomeAsked` is
already on the record

**Testing**: swift-testing in `Packages/AgentsKit/Tests/AgentsKitTests`. `AgentGroupTests`
already exhausts the pairs; `LifecycleWriterTests` already shows how a source scan holds a
"one place" claim (SC-009 of 020)

**Target Platform**: macOS 27, iOS 27

**Constraints**: `AgentsKitCore` must not gain `import SwiftUI`. Neither app has a test
target. The daemon has no window and must not pretend to: FR-004 is satisfied by the daemon
saying `wantsEyes: false` with its reason written beside it, not by the daemon guessing

**Scale/Scope**: 1 initialiser signature, 1 method replaced, ~9 call sites, 2 readers on
the Mac, 0 on the phone, 3 tests added and 1 removed

## Constitution Check

- One renderer, one rule: this feature removes a second way to reach the rule; it adds none.
- Nothing stored that can go stale: `wantsEyes` stays window-scoped, the group stays derived.
- The compiler enumerates the callers: removing the defaults breaks every call site, which is
  the point — the list of places that decide a group is the build log.
- Presentation untouched (FR-022): headings, order and the archived toggle are not in scope.

## Project Structure

### Documentation (this feature)

```
specs/019-one-grouping/
├── spec.md
├── plan.md          ← this file
├── quickstart.md    ← the by-hand checks, and what each proves
└── tasks.md
```

No research.md, data-model.md or contracts: nothing is unknown, nothing is stored, and the
one API that changes is a Swift initialiser whose signature is the contract.

### Source Code (repository root)

```
Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift        the rule, the funnel
Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift      group(of:), counts(in:), wantsEyes(in:) retired
Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift        ProjectSummary.counts doc, needsInput
Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift  the daemon's counts, eyes said absent
App/Sources/Projects/ProjectRow.swift                                  reads the window's counts
App/Sources/AppModel.swift                                             wantsEyes(in:) retired
Remote/Sources/Preview/Canned.swift                                    one call site
Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentGroupTests.swift     exhaustive over four facts
Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentsModelTests.swift    counts equal the list
Packages/AgentsKit/Tests/AgentsKitTests/Unit/OneGroupingTests.swift    the source scan (FR-021)
Packages/AgentsKit/Tests/AgentsKitTests/Integration/{Elicitation,UnreportedEnding,AgentBirth,OutcomeReport}Tests.swift
                                                                       `.group` → `.group(wantsEyes: false)`
```

## Approach, in the order it should be built

### Slice 1 — the funnel (US4, then US1 by construction)

Remove both defaults from the initialiser and add `outcomeAsked:`. Replace `Agent.group`
with `Agent.group(wantsEyes:)`. Fix every caller the compiler names: the daemon's counts
say `wantsEyes: false` and why; `AgentsModel.group(of:)` passes `filesToShow[id] != nil`;
`Canned.swift` says `false`; the four integration tests say `false`. The old
`theOlderInitialiserIsTheNoEyesCase` test is deleted with the default it tested. The
exhaustive test now walks `AgentState × Bool × (WorkOutcome? ) × Bool`.

### Slice 2 — the window completes the count (US1, US2)

`AgentsModel.counts(in:)` — a `[AgentGroup: Int]` from `group(of:)` over the folder's
agents, the same filter `agents(in:group:)` uses. `ProjectRow` reads it instead of
`summary.counts`, and `needsPerson` becomes `counts[.needsAttention] > 0`. `wantsEyes(in:)`
is deleted from `AgentsModel` and `AppModel`. A test holds that for a project with one
agent in every group, including one that asked to be looked at, the counts equal the list
under each heading (FR-020). The daemon's `counts` and `needsInput` keep their shape for
the phone, with their doc comments saying eyes are absent and why.

### Slice 3 — the question that is not work (US3)

`AgentGroup.init` maps `(.running, outcomeAsked: true)` to `.finished`'s row — i.e. it is
grouped as the finished agent it was a moment ago, with the same `wantsEyes`/report arms
— and the doc comment carries why. Nothing in the daemon changes: the flag is already set
before the question is enqueued and already cleared by a person's prompt. A daemon test
holds that during the question the broadcast agent is `running` with `outcomeAsked` set
and that a person's prompt mid-question clears it (US3 scenarios 1, 4).

### Slice 4 — keeping it (FR-021)

`OneGroupingTests`: a source scan over `Packages/AgentsKit/Sources`, `App/Sources` and
`Remote/Sources` asserting `AgentGroup(for:` appears in exactly one file — `AgentGroup.swift`
— and that the scan bites (a fixture line matches). Modelled on
`LifecycleWriterTests.anAgentsStateIsWrittenInExactlyOnePlace`.

## Things that will bite

| Where | What | Why it matters |
|---|---|---|
| `AgentGroup.swift:64` | Removing the defaults breaks ~9 call sites | That is the feature working. Do not add a convenience initialiser back |
| `ProjectRow.swift:57` | `needsPerson` ORs `summary.needsInput` with `wantsEyes(in:)` | Replace with one read of the window's counts, or the row keeps two opinions |
| `DaemonCore+Projects.swift:47` | The daemon counts with no eyes | Correct, and must say so in the comment: this is FR-004's "say so explicitly", not a leftover |
| `AgentsModel.filesToShow` | Window-scoped; the phone's model never fills it | So the phone's `group(of:)` and the daemon's counts agree — FR-010 holds for state and report, and the spec's own edge case says eyes are per window |
| `Remote/Sources/Preview/Canned.swift:135` | Calls `agent.group` for preview counts | Must say `wantsEyes: false` like the daemon; a preview that lies is a preview nobody checks |
| The four integration tests | Assert `agent.group` from the daemon's side | They are asking the daemon's view; `group(wantsEyes: false)` is the honest spelling |
| SC-005 | "Mac and phone place every agent under the same heading" | True for every fact the daemon holds. An agent whose file the Mac has not looked at is Needs attention on the Mac and not on the phone, and the spec's second edge case says that is correct. Quickstart check 5 is written to that |

## Complexity Tracking

None. Nothing in this plan needs a justification the spec does not already give.
