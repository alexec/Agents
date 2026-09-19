# Implementation Plan: Agentic Workflows

**Branch**: `008-agentic-workflows` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/008-agentic-workflows/spec.md`

## Summary

A workflow is a Markdown file with YAML front matter in `.agents/workflows/` inside a project. The front matter says what makes it run; the body is the prompt. The daemon watches those folders, holds a scheduler, fires workflows when their trigger matches, and either starts a new agent or picks an existing one back up. It refuses to fire when a run is already going, when a chain has run too deep, or when the workflow is paused, and it records every refusal so the project page can say why nothing happened. Agents manage their project's workflows through a tool the app serves them, with writes gated behind a confirmation the daemon raises itself.

Three seams in the existing code carry almost all of it:

- **`DaemonCore.move(_:on:)`** is the single funnel every agent state transition passes through, and `handle(_:agentID:)` is where permission and elicitation requests arrive. Together they are the whole of the lifecycle trigger surface — no new event plumbing, one hook in each.
- **`FolderWatch`** already turns FSEvents into coalesced directory changes for the files pane. Pointing one at each project gives workflow files that are picked up without a restart.
- **`appServer(token:)` / `AppService`** already serves agents an MCP server bound to their own identity, with `FolderScope` deciding what a call may touch. The workflow tool is a third tool on that server, scoped to the calling agent's project.

The one place the existing shape does not fit is permission. `autoAllowed(_:)` currently waves through anything `isTheApps`, which is right for suggestions and for opening a file and wrong for writing a file that starts agents on a timer. Worse, relying on the runtime to ask at all is unreliable — Copilot asks before every tool call, the Claude adapter often does not. So the daemon raises its own confirmation for workflow writes and blocks the tool call on it, reusing the pending-request-and-broadcast pattern that permissions and elicitations already use.

## Technical Context

**Language/Version**: Swift 6.2, strict concurrency

**Primary Dependencies**: Foundation, SwiftUI (app), CoreServices/FSEvents (via the existing `FolderWatch`). No new third-party dependency.

**Storage**: Plain files. Workflow definitions live in the project repository at `.agents/workflows/*.md`. Everything the app remembers about a workflow that does not belong in the repository — paused, standing agent, last outcome, last fired — goes in one JSON file under the daemon's root, following the `projects.json` precedent exactly.

**Testing**: Swift Testing (`import Testing`) in `Packages/AgentsKit/Tests/AgentsKitTests`, split `Unit` / `Integration` / `Live` / `Fake`. The daemon is driven end to end in tests through the injectable `SessionLauncher`, so firing a workflow and watching an agent start needs no CLI, no credential and no network.

**Target Platform**: macOS 27+. `AgentsKitCore` also builds for iOS 27+ and must stay free of `Process`, `posix_spawn` and PTY.

**Project Type**: Desktop app plus a long-lived local daemon, talking JSON-RPC over a unix socket.

**Performance Goals**: A workflow file added to a project is listed within five seconds (SC-001). Scheduled fires land within one minute of their stated time while the app is running (SC-008). Twenty workflows list and scroll as smoothly as the agent list under them (SC-009).

**Constraints**: Workflows fire only while the daemon is running — it already outlives the window, but not a logout. Nothing about a workflow's definition may be written back to the repository as a side effect of running it. The scheduler must survive machine sleep and time-zone changes.

**Scale/Scope**: Tens of projects, tens of workflows per project, a firing rate bounded below by a half-hour granularity and above by the in-flight rule (one live run per workflow).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unmodified template — every principle is an unfilled `[PRINCIPLE_N_NAME]` placeholder. There are no project principles to check against, so the gate passes vacuously in both directions. It is recorded here rather than silently skipped so that a later `/speckit-constitution` knows this feature was never measured against one.

In its place, the design was held to the conventions the codebase actually enforces, which are visible and consistent across the existing packages:

| Convention | How this feature holds to it |
|---|---|
| `AgentsKitCore` is what both platforms can hold; `AgentsKit` is the Mac's half | The workflow model, the trigger vocabulary and the daemon API types go in Core. The parser, the watcher, the scheduler and the store go in AgentsKit. |
| The daemon owns state; windows are views of it | Workflows fire, refuse and record in `DaemonCore`. The project page renders a broadcast summary and has no schedule logic of its own. |
| The record is written before the windows are told | A run or a refusal is persisted, then broadcast, in that order — the same rule `record(_:for:)` follows. |
| Agents are told the truth, in sentences | Every refusal from the workflow tool is a plain-language `JSONRPCError` message, like `showFile`'s refusals. |
| State transitions are pure and exhaustively testable | Whether a fire is allowed is a pure function of workflow, trigger, and current state — decided in one place, tested without a daemon. |

**Post-design re-check**: passes. The design adds no new package, no new process, and no new transport. The one behavioural change to existing code — narrowing `autoAllowed(_:)` — makes the permission surface stricter, not looser.

## Project Structure

### Documentation (this feature)

```text
specs/008-agentic-workflows/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── workflow-file.md     # The front-matter and body format
│   ├── daemon-api.md        # New JSON-RPC methods and notifications
│   └── mcp-tool.md          # The tool agents call
├── checklists/
│   └── requirements.md
└── tasks.md             # Created by /speckit-tasks, not here
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/
│   ├── Workflow.swift              # NEW  Definition: id, name, triggers, mode, prompt
│   ├── WorkflowTrigger.swift       # NEW  The trigger vocabulary, incl. unrecognised
│   ├── WorkflowOutcome.swift       # NEW  Ran / refused, with reason. Pure decision rules.
│   └── AppTool.swift               #  MOD Add the workflow tool's name
└── Daemon/
    └── DaemonAPI.swift             #  MOD workflows/* methods, workflow/changed, new failure codes

Packages/AgentsKit/Sources/AgentsKit/
├── Workflows/
│   ├── WorkflowFile.swift          # NEW  Parse and write one file; front matter ↔ model
│   ├── WorkflowFolder.swift        # NEW  Scan a project's .agents/workflows
│   ├── WorkflowSchedule.swift      # NEW  Next due time from a schedule trigger
│   └── WorkflowStore.swift         # NEW  App-side state: paused, standing agent, last outcome
├── Daemon/
│   ├── DaemonCore+Workflows.swift  # NEW  Fire, refuse, record; the scheduler tick
│   ├── DaemonCore+AppTools.swift   #  MOD The workflow tool handler; narrow autoAllowed
│   ├── DaemonCore.swift            #  MOD Hold the watchers, the ticker, pending confirmations
│   ├── DaemonCore+Commands.swift   #  MOD move() and handle() call into the trigger hook
│   └── DaemonCore+Dispatch.swift   #  MOD Route the new methods
├── ACP/Serve/AppService.swift      #  MOD Advertise and route the third tool
└── Store/StoreLocations.swift      #  MOD Add `workflows` → root/workflows.json

App/Sources/Projects/
├── ProjectAgentsView.swift         #  MOD A workflows section above the agents
├── WorkflowsSection.swift          # NEW  The list, its header, pause-all
└── WorkflowRow.swift               # NEW  Trigger in words, next fire, last outcome, actions

App/Sources/AppModel.swift          #  MOD Hold workflows per project; handle workflow/changed

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/
│   ├── WorkflowFileTests.swift     # NEW  Parsing, round-trip, malformed, unknown keys
│   ├── WorkflowScheduleTests.swift # NEW  Next due, DST, time zones, day sets
│   └── WorkflowOutcomeTests.swift  # NEW  The refusal rules, as a pure table
└── Integration/
    ├── WorkflowFiringTests.swift   # NEW  Schedule and lifecycle triggers start agents
    ├── WorkflowRefusalTests.swift  # NEW  Depth, in-flight, paused, missed, unavailable
    └── WorkflowToolTests.swift     # NEW  List without asking; write behind a confirmation
```

**Structure Decision**: The existing split is followed exactly and no new package is introduced. The dividing line is the one `Package.swift` already states: `AgentsKitCore` is everything a phone could hold — the workflow record, the trigger vocabulary, the outcome rules, the daemon's method names — and `AgentsKit` is the Mac's half, holding the parser that touches the file system, the FSEvents watcher, the scheduler and the store. Putting the model in Core is not speculative: `ProjectSummary` is already there, and showing a project's workflows on the phone later then needs no move.

## Implementation Phasing

Each phase is the whole of one user story and is shippable without the next.

| Phase | Story | What lands | Proves |
|---|---|---|---|
| 1 | US1 (P1) | File format and parser, folder watching, the scheduler, `new` and `standing` modes, the project page section, Run now, pause | A hand-written workflow runs on a schedule and you can see and stop it |
| 2 | US2 (P2) | Lifecycle triggers hooked into `move` and `handle`, `triggering` mode, workflow-completed chaining | Workflows react to agents |
| 3 | US3 (P3) | Chain depth, in-flight refusal, the refusal record, collapsing repeats, the missed-fire heartbeat | Nothing fails quietly |
| 4 | US4 (P4) | The MCP tool, narrowed `autoAllowed`, the daemon-raised confirmation | Agents set up their own workflows |

Phase 3 depends on phase 2 only for the refusals that chaining makes reachable; the in-flight, paused and malformed refusals are testable from phase 1 and should be built with it rather than deferred. Treat phase 3 as *the rest of* the refusal surface plus its presentation.

## Risks and the decisions that answer them

| Risk | Answer | Where |
|---|---|---|
| A workflow that writes workflows, approved once, schedules itself deeper | Writes are confirmed per call, never "always"; chain depth binds the runs regardless | [research.md §4](./research.md), §3 |
| Relying on the runtime to raise the permission means three of four runtimes never ask | The daemon raises its own confirmation and blocks the tool call on it | [research.md §4](./research.md) |
| A long `Task.sleep` across machine sleep or a time-zone change fires at the wrong time, or not at all | A short wall-clock tick comparing `Date()`, never a sleep-until-due | [research.md §2](./research.md) |
| Watching every project's tree costs what a build costs | Coalesced FSEvents, filtered to `.agents`, debounced; the rescan reads one small directory | [research.md §1](./research.md) |
| `shellWillNotStart` and `notConfirmed` are both `-32010` in `DaemonAPI.Failure` today | Pre-existing; not fixed here, but the new codes start at `-32014` and the collision is flagged | [contracts/daemon-api.md](./contracts/daemon-api.md) |
| A refusal every half hour for a fortnight fills the row | Only the latest outcome is kept, with a repeat count | [data-model.md](./data-model.md) |

## Complexity Tracking

No constitution violations to justify — the constitution is an unfilled template. No new projects, packages, processes or dependencies are introduced.
