# Implementation Plan: An Agent Can Say It Is Blocked, and Carries On When the Block Clears

**Branch**: `039-blocked-status` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/039-blocked-status/spec.md`

## Summary

Add a sixth `WorkOutcome`, `blocked`, to `finish_turn` (and the older `report_outcome`). A
blocked report has two new optional fields: `waiting_on`, a list of agent ids or exact titles
in the caller's project, and `check_again_in_minutes`, from 1 to 1440. The daemon checks them
in `checkedReport` before anything is written. It refuses unknown or ambiguous names, agents in
another project, the caller itself, agents that have already ended, circles, and times out of
range. The block is kept on the report as a `Block`: its waits, when to check again, and
whether it has cleared. So a person's prompt clears it the way it already clears any report
(FR-015), and a later report replaces it.

Waits close in `move(_:on:)`, the one place every state change already goes through. They
close when the waited-on agent reaches an accounted `finished` (not a finish the app is about
to ask about, and not a finish whose own report is `blocked`), `stopped` (except a restart
pick-up), or `archived`. A wait also closes if its agent has gone from the record. When the
blocked agent is `finished`, every wait has closed and the block hasn't cleared, the daemon
does one write: it marks the block cleared and queues a resume prompt `from: .app`. It then
drains the queue as usual. Doing both in one write before any `await` means one resume per
block on the actor, across restarts too (SC-002). The workflow ticker, every 15 s, checks for
blocks whose time to check again has passed, and `recover()` looks at every block once at
startup (FR-020). If a resume can't start, a `stuck` report with the reason replaces the
block (FR-018).

`AgentGroup` gains `.blocked`, drawn between Needs attention and Working. Grouping sends a
finished agent with an uncleared block there. `needsAPerson` stays false for `blocked`, so
counts, badges and notifications need no change (FR-009). The Mac row and the phone card show
the message, one line per wait (name and whether it has finished), the time to check again,
and a **Carry on** button that sends a fixed prompt from the person.

See [research.md](research.md) for each decision, [data-model.md](data-model.md) for the
record changes, and [contracts/finish-turn-blocked.md](contracts/finish-turn-blocked.md) for
the tool and wire shapes.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), SwiftUI

**Primary Dependencies**: AgentsKit / AgentsKitCore (in-repo package), ACP runtimes over stdio, the app's own MCP server (`AppService`), relayed by the `agentsd` helper

**Storage**: Agent records as JSON through the existing `store`. `WorkReport` gains one optional field, `block`. No new files.

**Testing**: swift-testing in `Packages/AgentsKit` (Unit + Integration with fake runtimes), xcodebuild for both schemes (plugin validation skipped, one after the other), and the run-app skill for end to end

**Target Platform**: macOS app + `agentsd` daemon. The iOS/iPadOS Remote app gets the new group, the card lines and Carry on.

**Project Type**: Desktop app with a daemon, plus a companion iOS app

**Performance Goals**: Resume within 5 s of the last wait closing (SC-001). In practice this is immediate, since closing happens inside `move`. Time to check again is honoured within one tick (15 s).

**Constraints**: One resume per block, even when agents finish at the same moment or the daemon restarts (SC-002). No `await` between deciding to resume and writing that it happened. Older builds must not lose a whole agent record because of the new outcome word (research R8).

**Scale/Scope**: One enum case in each of two enums, one struct with its waits, a fifth check in `checkedReport`, one hook in `move`, one tick check, one recovery pass, one event in the state table, the tool schema and description, and row/card/section changes on the Mac and iOS.

## Constitution Check

The constitution (`.specify/memory/constitution.md`) is still the unfilled template, so there
are no gates to check. This plan follows the working rules the repo does have:
- **Settle the UX before depth**: the new UI is one section and one row style, copied from
  Needs attention. Phase 2 builds that first, over a hand-made blocked report, and it is
  looked at running before the resume machinery is built.
- **One path, not two**: a blocked report goes through `checkedReport`/`land` like the other
  five. A resume is an ordinary `enqueue(from: .app)` like the silent-ending question. Carry
  on is an ordinary person prompt. Grouping stays the one `AgentGroup.init`.
- **Prove it running**: quickstart §3 runs a parent and two helpers on a scratch daemon,
  rather than leaving that walk to Alex.

Re-checked after design: still no violations.

## Project Structure

### Documentation (this feature)

```text
specs/039-blocked-status/
├── spec.md
├── plan.md              # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── finish-turn-blocked.md
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/WorkOutcome.swift          # .blocked; heading; WorkReport.block; lenient decode of unknown outcomes
├── Model/Block.swift                # NEW: Block, Wait, WaitEnding, checkAgain range, resume/carry-on wording
├── Model/AgentGroup.swift           # .blocked, live order, grouping arm; lenient unknown keys in counts
├── Model/AgentState.swift           # AgentEvent.stoppedWaiting(finished → stopped)
├── UI/StatusShape.swift             # a blocked shape (not needsYou, not done)
└── Daemon/DaemonAPI.swift           # FinishTurnRequest/ReportOutcomeRequest gain waitingOn, checkAgainInMinutes

Packages/AgentsKit/Sources/AgentsKit/
├── ACP/Serve/AppService.swift       # schema: sixth enum value, two properties, description text
└── Daemon/
    ├── DaemonCore+Blocks.swift      # NEW: resolve names, circle check, closeWaits(on:), resumeIfCleared, tick, recovery pass
    ├── DaemonCore+AppTools.swift    # checkedReport validates the block; land keeps it
    ├── DaemonCore.swift             # move() calls closeWaits(on:) and resumeIfCleared(self)
    ├── DaemonCore+Commands.swift    # stop/archive drop a block; resume failure → stuck
    ├── DaemonCore+Workflows.swift   # tickWorkflows calls the check-again pass
    └── DaemonCore+Recovery.swift    # recover() re-judges every block once

Daemon/Sources/main.swift            # relay waiting_on / check_again_in_minutes

App/Sources/Projects/ProjectAgentsView.swift   # Blocked section (comes from AgentGroup.live)
App/Sources/AgentList/AgentRow.swift           # wait lines, time to check again, Carry on
Remote/Sources/Projects/ProjectPageView.swift  # Blocked section
Remote/Sources/Projects/AgentCard.swift        # same lines, Carry on
Remote/Sources/Preview/Canned.swift            # a blocked agent for previews

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/WorkOutcomeTests.swift       # sixth case, lenient decode
├── Unit/AgentGroupTests (existing)   # exhaustive grouping incl. blocked
├── Unit/BlockTests.swift             # NEW: resume wording, range, circle detection on a fixture graph
├── Unit/AppServiceTests.swift        # schema, local refusals
└── Integration/BlockedTests.swift    # NEW: two helpers, one resume; person prompt clears; stop/archive; circle; restart; timer; resume failure
```

**Structure Decision**: The existing layout. New files: `Block.swift` (model, next to
`WorkOutcome.swift`), `DaemonCore+Blocks.swift` (following the `DaemonCore+Area` split), and
two test files.

## Phases (for /speckit-tasks)

1. **Model and table**: `.blocked`, `Block`/`Wait`, lenient decoding, `AgentGroup.blocked`, the
   `stoppedWaiting` event, `StatusShape`. Unit tests. No behaviour change yet.
2. **Seen by the person (US2, P1). UX gate**: Blocked section, row and card lines, Carry on
   on Mac and iOS, driven by a blocked report written by hand on a scratch daemon. Screenshot
   it and settle it before phase 3.
3. **Report and refusals (US1)**: schema and description, `checkedReport` checks (names,
   project, self, already ended, circle, range), relay in `main.swift`.
4. **Clearing and resuming (US1 + US3)**: `closeWaits` in `move`, `resumeIfCleared` (one
   write), resume prompt wording, person prompt clears it (already true through
   `report = nil`), stop/archive drop it, resume failure goes to stuck. Integration tests.
5. **Time and restart (US4 + FR-020)**: tick check, recovery pass, tests with an injected
   `now`.
6. **Proof**: both builds, the full suite, and the quickstart run on a scratch daemon with
   screenshots.

## Risks

- **Older phone builds.** A phone built before this change can't decode `"blocked"` inside a
  report, or the `blocked` key in project counts, and would drop that agent or project summary.
  This build makes both decoders lenient from now on (R8). The phone should still be updated
  alongside the Mac, as it always has been.
- **Resumes cost money with nobody watching.** Each resume is bounded to one per block, and
  every block needs a fresh turn to create. The existing per-agent and daily limits still hold
  the resume in the queue. That hold counts as "can't start" and goes to Needs attention (R7).
- **Naming siblings.** Helpers don't get `list_my_agents`, so a helper only knows a sibling's
  id if its parent put it in the prompt. v1 accepts that (spec Assumptions). The P1 case, a
  parent waiting on its own helpers, has every id it needs.
- **Runtimes ignoring the enum.** An agent on an older conversation was briefed with five
  outcomes and may never use the sixth. That costs nothing: it keeps behaving as it does today.

## Complexity Tracking

None. There are no constitution gates. The one new state-table event exists because a
finished agent can't be stopped today, and FR-017 needs a blocked one to be stoppable.
