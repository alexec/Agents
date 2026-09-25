# Implementation Plan: An Agent Can Run a Few Agents of Its Own

**Branch**: `028-agents-manage-agents` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/028-agents-manage-agents/spec.md`

## Summary

Add four app tools, `start_agent`, `stop_agent`, `archive_agent` and `list_my_agents`, to the MCP
server every agent already has. The helper binary relays them to four new daemon methods, as it
does for `manage_workflows`. The daemon does all the deciding, using the caller's session token.
The caller's project is its own `cwd`. A target is manageable only if its new `startedByAgent`
field names the caller. A project holds at most three agent-started agents that are not archived.
That is counted from the agent records plus in-memory reservations taken before the first `await`,
so concurrent starts can't exceed it. Helpers aren't offered the tools (a helper-process flag) and
are refused if they call them anyway (a daemon check).

Starting reuses the workflow path for runtime, model and permission mode. Stopping and archiving
reuse `DaemonCore.stop` and `archive` with a new `by:` cause. That adds two state-table events,
`stoppedByAgent` and `archivedByAgent`, so the row never says "Stopped by you" for something the
person didn't do. The person sees helpers as ordinary agents, marked with who started them, on
the Mac row, the phone card and the chat's first line.

See [research.md](research.md) for each decision, [data-model.md](data-model.md) for the
record changes, and [contracts/agent-tools.md](contracts/agent-tools.md) for the tool and
wire shapes.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), SwiftUI

**Primary Dependencies**: AgentsKit / AgentsKitCore (in-repo package), ACP runtimes over stdio, the app's own MCP server (`AppService`)

**Storage**: Agent records as JSON through the existing `store`, gaining one optional field. No new files.

**Testing**: swift-testing in `Packages/AgentsKit` (Unit + Integration with fake runtimes), xcodebuild for both schemes, and the run-app skill for end to end

**Target Platform**: macOS app + `agentsd` daemon. The iOS Remote app only reads (row mark).

**Project Type**: Desktop app with a daemon, plus a companion iOS app

**Performance Goals**: No new work on hot paths. The limit check is one pass over `agents` for each start.

**Constraints**: The limit must hold under concurrent starts (SC-002). Records must stay readable by older phone builds.

**Scale/Scope**: At most 3 helpers per project. Four tools, four daemon methods, one field, two events, two enum cases, one briefing line, and two small view changes.

## Constitution Check

The constitution (`.specify/memory/constitution.md`) is still the unfilled template, so there are
no gates to check. This plan follows the working rules the repo does have:
- **Settle the UX before depth**: the only UI is a row mark and a transcript line, both copying
  the workflow mark, so there is nothing new to settle.
- **One path, not two**: stop and archive go through the existing functions (FR-007), and start
  settings go through the workflow's resolver (FR-003).
- **Prove it running**: quickstart §3 runs it on a scratch daemon rather than leaving a walk for Alex.

Re-checked after design: still no violations.

## Project Structure

### Documentation (this feature)

```text
specs/028-agents-manage-agents/
├── spec.md
├── plan.md              # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── agent-tools.md
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/AppTool.swift              # four new names
├── Model/Agent.swift                # startedByAgent; ArchivedReason.byAgent
├── Model/AgentState.swift           # AgentEvent.stoppedByAgent / .archivedByAgent rows
├── Model/EndedReason.swift          # .stoppedByAgent + summary
├── Model/HelperLimit.swift          # NEW: perProject = 3, and the placesInUse counting rule
└── Daemon/DaemonAPI.swift           # 4 methods, 3 request types, Failure.notYours

Packages/AgentsKit/Sources/AgentsKit/
├── ACP/Serve/AppService.swift       # 4 tool schemas + dispatch; managesAgents init flag
├── ACP/Serve/Briefing.swift         # helpers line, only for agents that have the tools
└── Daemon/
    ├── DaemonCore+Helpers.swift     # NEW: startHelper/stopHelper/archiveHelper/listHelpers, reservations
    ├── DaemonCore+AppTools.swift    # appServer(token:managesAgents:)
    ├── DaemonCore+Commands.swift    # freshSession/connect pass the flag; stop/archive take `by:`
    ├── DaemonCore+Workflows.swift   # settings→StartRequest extracted; chain depth falls back to the starter
    ├── DaemonCore+Dispatch.swift    # 4 cases
    └── DaemonCore.swift             # reservedStarts

Daemon/Sources/main.swift            # parse --no-agent-tools; relay the 4 tools

App/Sources/AgentList/AgentRow.swift          # started-by-agent mark
Remote/Sources/Projects/AgentCard.swift       # same mark on the phone

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/AgentStateTests.swift                               # new rows
├── Unit/AppServiceTests.swift                              # tools/list with and without
├── Unit/BriefingTests.swift                                # line present / absent
└── Integration/HelperAgentTests.swift                      # NEW: limit, scope, concurrency, restart, one level
```

**Structure Decision**: The existing layout. The only new files are `DaemonCore+Helpers.swift`,
following the `DaemonCore+Area` split, `HelperLimit.swift` (the counterpart of `WorkflowLimit`, which lives in `WorkflowOutcome.swift`), and one
integration test file.

## Phases (for /speckit-tasks)

1. **Record and table**: `startedByAgent`, the two enum cases, the two events, and table tests. No behaviour change yet.
2. **Daemon (US1 + US2, P1)**: `startHelper` with reservation and limit, a `by:` cause on stop/archive, the scope checks, dispatch, and the integration tests for limit, scope, concurrency and restart.
3. **Tools and one level (US2)**: `AppService` schemas, the helper flag through `appServer` and `connect`, `main.swift` relays, and the daemon-side refusal for helpers.
4. **Stop, archive, list (US3 + US4, P2)**: the stop/archive tool texts and `listHelpers`.
5. **Seen by the person**: the row mark, the phone card mark, the "Started by" first note, and the briefing line.
6. **Proof**: both builds and the run-app pass from the quickstart, with screenshots.

## Risks

- **The socket route stays open.** Any agent shell can still ignore all of this over
  `daemon.sock` (research R9). The spec treats that as a follow-up. This feature is the sanctioned
  path, not a boundary.
- **Runtimes may ask the person before an MCP tool runs.** Whether `start_agent` goes through
  without a prompt depends on each runtime's own MCP permission policy. The live pass should
  record what each runtime does. Changing their policy isn't part of this plan.
- **Helpers add cost.** Each one is a full agent. The existing daily and per-agent cost limits
  apply to each helper as they do to any agent, and `start` already refuses when the day's limit
  is reached.

## Complexity Tracking

None. No constitution gates, and nothing is added beyond what the spec asks for.
