# Implementation Plan: How It Actually Went

**Branch**: `014-agent-outcomes` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/014-agent-outcomes/spec.md`

## Summary

Agents get a fourth app-served tool, `report_outcome`, and it is the last thing they call. It takes
one of five outcomes — done, nothing to do, needs an answer, partly done, stuck — and a message in
the agent's own words. The report lands on the `Agent` record, feeds `AgentGroup` so that three of
the five outcomes move an agent into Needs attention, and replaces the derived wording on the row,
the card and the transcript. The word *Complete* narrows to mean a reported **done**.

A turn that ends with no report gets one automatic question from the daemon — a prompt the app sends
on its own behalf, marked as such, sent once and never again — and if that comes back empty too the
ending is labelled as unaccounted for and left under Complete, with no colour.

Almost all of this is additive to shapes that already exist. The outcome is a new optional field on
`Agent` behind `decodeIfPresent`, the grouping is a third argument to an initialiser that already
takes two, and the tool is a fourth entry in `AppService`'s three-entry tool list. The two genuinely
new things are a transcript kind for the report and a way to mark a prompt as the app's rather than
the person's.

## Technical Context

**Language/Version**: Swift 6, strict concurrency

**Primary Dependencies**: SwiftUI (Mac app and remote), Foundation, the in-house `JSONRPCConnection`
for both ACP and MCP. No new dependency.

**Storage**: The JSON agent records under `StoreLocations.root`, via `AgentStore`. `Agent` has a
hand-written `Codable` conformance with `decodeIfPresent` for every field added after 001 and an
`unknownFields` bag, so a new optional field opens every existing record unchanged and an older
build round-trips a newer record without dropping it.

**Testing**: `swift-testing` (`@Suite` / `@Test`) in `Packages/AgentsKit/Tests/AgentsKitTests`,
split `Unit` / `Integration` / `Live`. Run with `swift test --package-path Packages/AgentsKit`; the
app builds with `xcodebuild -scheme Agents -destination 'platform=macOS'`.

**Target Platform**: macOS app (`App/`), iOS/iPadOS remote (`Remote/`), `agentsd` daemon and MCP
helper (`Daemon/`), shared in `Packages/AgentsKit` (`AgentsKit` for the daemon half, `AgentsKitCore`
for the half both platforms hold).

**Project Type**: Desktop app plus a mobile remote over a local daemon.

**Performance Goals**: None specific. A report is one JSON-RPC call on a socket already open, and the
grouping it feeds is a pure function over a struct.

**Constraints**:

- The wording of every outcome must exist exactly once, because four views draw it
  (`App/Sources/AgentList/AgentRow.swift`, `App/Sources/Chat/Transcript.swift`,
  `Remote/Sources/Projects/AgentCard.swift`, `Remote/Sources/Chat/EntryView.swift`) and FR-017
  requires they agree.
- Records written by older builds must open. Records written by this build must open in older ones.
- `AgentState` must not grow a case. See Research R2.
- The automatic question costs a turn, so its bound has to be structural rather than a convention.

**Scale/Scope**: Five outcome values, one tool, one new transcript kind, two new `Agent` fields,
four view sites, one briefing line. Roughly a dozen source files and six test suites.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is the unedited template — every principle is still a
`[PRINCIPLE_N_NAME]` placeholder, so there are no ratified gates to check against and none are
invented here. In their place, the conventions this codebase actually holds itself to, read off the
existing sources, and how this design stands against each:

| Standing convention | How this design stands |
|---|---|
| Wording a person reads lives on the model, not in a view, so the Mac and the phone cannot drift (`EndedReason.summary`, `AgentGroup.title`, `WorkflowRefusal.message`) | `WorkOutcome` carries its own heading and its own group. No view switches on the outcome. |
| Mappings a person depends on are total and exhausted by a test (`AgentGroupTests` walks every state) | `AgentGroup(for:wantsEyes:report:)` stays total, and the test grows to walk every `(state, report)` pair. |
| The record is append-only and forward-compatible both ways (`unknownFields`, `TranscriptEntry.Kind.unrecognised`) | Both new `Agent` fields are `decodeIfPresent`; the new transcript kind falls to `.unrecognised` in older builds; an unknown outcome string decodes as unaccounted-for rather than throwing. |
| An agent is told, in a sentence, what happened to anything it asked for (`AppService.Outcome`) | Every report is answered with a sentence, refusals included. |
| A ceiling something can raise for itself is not a ceiling (`Workflow.chainDepthLimit`) | The automatic question is bounded by a flag the agent cannot write, and never recurses. |
| `AgentState` means *is a turn in flight*, never *how did it go* | The report is a separate field. No new state, no new transition. |

**Result**: pass, with nothing to record in Complexity Tracking.

**Re-checked after Phase 1 design**: still passing, and the design tightened two of the rows rather
than straining them. `WorkOutcome` ended up carrying `needsAPerson` and `heading`, so the grouping
rule and the wording are both single-sourced. The one row that needed a decision rather than an
assertion is the colour convention, which the tree contradicts today — `StatusIcon` claims grey
except for what wants you, then tints `.finished` green. Research R3 resolves it by narrowing green
to a reported **done** rather than by adding a colour, so the convention comes out true where it was
not before.

## Project Structure

### Documentation (this feature)

```text
specs/014-agent-outcomes/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── agent-tool.md    # What the agent sees: the tool, its schema, its replies
│   ├── daemon-api.md    # The daemon method the helper relays to
│   └── ui.md            # What each outcome looks like, on both platforms
├── checklists/
│   └── requirements.md  # Written by /speckit-specify; all items pass
└── tasks.md             # Written by /speckit-tasks — NOT created here
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/     # Both platforms hold this
├── Model/
│   ├── WorkOutcome.swift                     # NEW — the five values, their wording, their group
│   ├── Agent.swift                           # + report, + outcomeAsked; coder, needsAPerson
│   ├── AgentGroup.swift                      # + report: in the initialiser; still total
│   ├── TranscriptEntry.swift                 # + .workReported(WorkReport)
│   ├── TranscriptEntry+Coding.swift          # + its wire shape, both directions
│   └── AppTool.swift                         # + reportOutcome name
├── Daemon/DaemonAPI.swift                    # + agents/reportOutcome, + ReportOutcomeRequest
└── Client/AgentsModel.swift                  # group(of:) passes the report through

Packages/AgentsKit/Sources/AgentsKit/         # The daemon's half
├── ACP/Serve/AppService.swift                # + the tool, its schema, its sink
├── ACP/Serve/Briefing.swift                  # + the line that makes agents call it
└── Daemon/
    ├── DaemonCore+AppTools.swift             # + reportOutcome(_:)
    ├── DaemonCore+Dispatch.swift             # + the method case
    ├── DaemonCore+Commands.swift             # finishTurn asks once when nothing was said
    └── DaemonCore+Projects.swift             # counts become report-aware

Daemon/Sources/main.swift                     # The helper relays the fourth tool

App/Sources/                                  # The Mac
├── AgentList/AgentRow.swift                  # description, symbol, tint read the outcome
└── Chat/Transcript.swift                     # draws the report at the end

Remote/Sources/                               # The phone and iPad
├── Projects/AgentCard.swift                  # same three, same words
└── Chat/EntryView.swift                      # draws the report at the end

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/WorkOutcomeTests.swift               # NEW — the table, exhausted
├── Unit/AgentGroupTests.swift                # grows to every (state, report) pair
├── Unit/AppServiceTests.swift                # the tool is offered, refusals read well
├── Unit/BriefingTests.swift                  # the new line is in the block
├── Unit/LegacyRecordTests.swift              # a record without a report still opens
├── Integration/OutcomeReportTests.swift      # NEW — report, group, clear, refuse
├── Integration/UnreportedEndingTests.swift   # NEW — asked once, and only once
└── Live/OutcomeReportLiveTests.swift         # NEW — real runtimes actually call it
```

**Structure Decision**: No new module and no new target. The feature splits along the seam the
codebase already has: everything a phone needs in order to draw an outcome goes in `AgentsKitCore`
(the model, its wording, its grouping, the API shapes), and everything that decides or enforces goes
in `AgentsKit` beside the daemon. The one new file in each is `Model/WorkOutcome.swift` and the test
suites; every other change is an addition to a file that already owns that concern.

## Complexity Tracking

> No Constitution Check violations. Nothing to justify.
