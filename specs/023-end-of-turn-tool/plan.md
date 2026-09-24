# Implementation Plan: One Call to End a Turn

**Branch**: `023-end-of-turn-tool` | **Date**: 2026-09-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/023-end-of-turn-tool/spec.md`

## Summary

Agents get one tool to end a turn with, `finish_turn`, and it takes the place of two. It carries the
outcome and message that `report_outcome` takes today and, optionally, the one to four prompts that
`suggest_next_prompts` takes. It lands on the daemon as one method, `agents/finishTurn`, which runs
the outcome's refusals first and then sets the report and the chips on the agent in one change, so
a call refused for a pending permission shows nothing and a call that lands is one record and one
broadcast.

The two old tools do not go. They stay in `tools/list` with a one-line description pointing at the
new one, their handlers stay in `AppService`, and their daemon methods stay untouched. A
conversation briefed last week calls what it was told and it works. Nothing else in the tree knows
the old names exist except the places that already do, and each of those is a one-line removal
when the time comes.

The briefing's `suggestions` and `outcome` lines become one line, `finish`, and the block drops from
six lines to five. The once-only ask a silent agent gets names the new tool. The "use this instead"
sentence for a runtime's removed suggestion tool names the new tool. The transcript suppresses the
new call the way it suppresses the two old ones.

No stored field changes. `Agent.report` and `Agent.suggestedPrompts` are exactly what they were;
this feature changes how they arrive, not what they are.

## Technical Context

**Language/Version**: Swift 6, strict concurrency

**Primary Dependencies**: Foundation, the in-house `JSONRPCConnection` for MCP and the daemon
socket. No new dependency.

**Storage**: None new. The agent record's `report` and `suggestedPrompts` fields are unchanged, so
no record written by this build looks any different to an older one.

**Testing**: `swift-testing` in `Packages/AgentsKit/Tests/AgentsKitTests`, split
`Unit` / `Integration` / `Live`. `swift test --package-path Packages/AgentsKit`. The live suites run
under `AGENTS_LIVE=1 AGENTS_MCP_HELPER=<agentsd>` and are the only thing that can answer SC-004.

**Target Platform**: The `agentsd` daemon and its MCP helper (`Daemon/`), shared code in
`Packages/AgentsKit`. The Mac app and the remote change only where they recognise the app's own
tool calls, which is one predicate in `AgentsKitCore`.

**Project Type**: Desktop app plus mobile remote over a local daemon; this feature is daemon-side.

**Performance Goals**: One fewer JSON-RPC round trip per turn per agent. Nothing to measure.

**Constraints**:

- The old names must keep working with their existing arguments and rules, because the briefing
  lives in runtime history (spec, Story 2). The existing integration suites for both old tools are
  the proof and must pass unchanged (SC-007).
- Every place that recognises an app tool call by name must recognise three names for the
  end-of-turn act, matched on the suffix (FR-020). Those places are `PermissionRequest`,
  `TranscriptDisplay`, and `AppService.handle`.
- The briefing block must get shorter, not longer. `BriefingTests.itStaysShortEnoughToBeRead`
  tightens rather than loosens.
- Three lanes share one working tree. `TranscriptDisplay.swift` and `AgentsModel.swift` were in
  022's uncommitted diff this morning; check `git status` before touching them and build in a
  detached worktree if the tree will not compile.

**Scale/Scope**: One new tool, one new daemon method, one new request type, one briefing line in
place of two, one predicate, two alias entries. About ten source files and five test suites.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unedited template, so as in 014 the gates are the
conventions the tree holds itself to:

| Standing convention | How this design stands |
|---|---|
| A tool's name lives in `AppTool` and nowhere else is it spelled | `AppTool.finishTurn` is added; the old two stay as they are. Every site reads the constant. |
| App tool calls are matched on the end of the name, never whole | The new name and both old names are suffix-matched in the three places that match. |
| An agent is told, in a sentence, what happened to anything it asked for | `finishTurn` replies with the outcome sentence and the chips sentence joined; every refusal is a sentence. |
| A refusal happens before any side effect, so nothing half-lands | `finishTurn` runs every check before it writes the report or the chips. |
| Wording an agent depends on is generated from one place (`RemitCategory.instead`, `Briefing.lines`) | The briefing line, the ask, and the `instead` sentence all read `AppTool.finishTurn`. |
| The briefing is a budget: an agent told six things follows the first two | Six lines become five. The ceiling in `BriefingTests` comes down. |
| The record is forward and backward compatible | No record change at all. |

**Result**: pass. Nothing for Complexity Tracking.

**Re-checked after Phase 1 design**: still passing. The one decision that pushed on a convention
was where to merge. Merging in the helper, by relaying two existing daemon calls, would have let a
call half-land, which the refusal-before-side-effect row forbids. So the merge is one daemon method.
See Research R2.

## Project Structure

### Documentation (this feature)

```text
specs/023-end-of-turn-tool/
├── plan.md              # This file
├── research.md          # Phase 0: the name, where to merge, the aliases, the briefing line
├── data-model.md        # Phase 1: nothing stored changes; the wire shapes that do
├── quickstart.md        # Phase 1: how to prove it
├── contracts/
│   ├── agent-tool.md    # finish_turn as the agent sees it, and the two aliases
│   ├── daemon-api.md    # agents/finishTurn
│   └── briefing.md      # The one line in place of two, and the ask
├── checklists/
│   └── requirements.md  # Written by /speckit-specify; all items pass
└── tasks.md             # Written by /speckit-tasks — NOT created here
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/
│   ├── AppTool.swift                         # + finishTurn; the old two annotated as aliases
│   ├── PermissionRequest.swift               # + isFinishingTurn; isTheApps includes it
│   └── TranscriptDisplay.swift               # suppresses the new call as it does the old two
├── Runtimes/ToolPolicy.swift                 # RemitCategory.suggestions.instead names finish_turn
└── Daemon/DaemonAPI.swift                    # + Method.agentsFinishTurn, + FinishTurnRequest

Packages/AgentsKit/Sources/AgentsKit/
├── ACP/Serve/
│   ├── AppService.swift                      # + finishTurnTool, + FinishSink, aliases listed last
│   └── Briefing.swift                        # suggestions + outcome → finish; lines() drops one
└── Daemon/
    ├── DaemonCore+AppTools.swift             # + finishTurn(_:); reportOutcome shares its checks
    ├── DaemonCore+Dispatch.swift             # + the method case
    └── DaemonCore+Commands.swift             # askForOutcome names finish_turn

Daemon/Sources/main.swift                     # The helper relays the fifth sink

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/AppServiceTests.swift                # listing order, schema, refusals, prefix, aliases
├── Unit/BriefingTests.swift                  # one line, names the tool, shorter ceiling
├── Unit/ToolPolicyTests.swift                # instead sentence names finish_turn
├── Unit/TranscriptDisplayTests.swift         # the new call is not drawn
├── Integration/FinishTurnTests.swift         # NEW — one call, refusals, replacement, alias interplay
├── Integration/OutcomeReportTests.swift      # unchanged, must pass (SC-007)
├── Integration/SuggestedPromptTests.swift    # unchanged, must pass (SC-007)
├── Integration/UnreportedEndingTests.swift   # the ask names the new tool
└── Live/FinishTurnLiveTests.swift            # NEW — do the runtimes call it (SC-004)
```

**Structure Decision**: No new module, no new file outside tests. Everything is an addition to a
file that already owns that concern, and the alias handling is confined to `AppService` and the
helper so that removing it later is a matter of deleting entries rather than finding them.

## Complexity Tracking

> No Constitution Check violations. Nothing to justify.
