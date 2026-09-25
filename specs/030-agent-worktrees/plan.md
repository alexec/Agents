# Implementation Plan: An Agent Can Work in a Worktree of Its Own

**Branch**: `030-agent-worktrees` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/030-agent-worktrees/spec.md`

## Summary

`agents/start` gains an optional `worktree` choice: `new`, or an existing worktree of the same
repository. For `new`, the daemon does the following:
1. Names the worktree from the prompt.
2. Makes sure `.agents/worktrees/` is in the clone's local exclude file.
3. Runs `git worktree add -b agents/<name>` from the project folder's HEAD.
4. Launches the runtime with the worktree as both the process folder and the `session/new` cwd.

No runtime's own worktree option is used: over ACP only Claude's works, and the other three
either work in the wrong folder or don't start (research R1).

The agent record gains an optional `worktree`, and a computed `projectFolder`. About 14 call
sites that file an agent under a project switch from `cwd` to `projectFolder`, so an agent in a
worktree stays in its project, its costs and its 028 limit. Everything that means *where it works*
stays on `cwd`, so the files pane, terminal and resume follow the worktree without any other
change.

The Mac start bar gets a **Worktree** capsule, and the project page a **Worktrees** section with
Remove. The phone and the Mac show a badge on the agent's row. Three new daemon methods list,
check and remove worktrees. `start_agent` gets the same choice. Nothing new is stored: the app's
worktrees are recognised from git by path and branch prefix.

See [research.md](research.md) for the decisions, [data-model.md](data-model.md) for the record
and wire types, and [contracts/worktrees.md](contracts/worktrees.md) for the methods, the tool and
the UI.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), SwiftUI

**Primary Dependencies**:
- AgentsKit / AgentsKitCore (in-repo package)
- The person's own `git` through `GitProcess` (027)
- ACP runtimes over stdio

**Storage**: One optional field on agent records (`worktree`). Worktrees themselves are git's. The
only file written outside the worktree is one line in `<git-common-dir>/info/exclude`.

**Testing**:
- swift-testing in `Packages/AgentsKit`: Unit, plus Integration with fake runtimes and real
  temporary git repositories.
- xcodebuild for both schemes.
- The run-app skill for end-to-end checks.
- One live run per runtime (quickstart §3).

**Target Platform**: The macOS app and the `agentsd` daemon. The iOS Remote app only reads it (the
row badge).

**Project Type**: Desktop app with a daemon, plus a companion iOS app

**Performance Goals**:
- A new worktree adds git's checkout time, plus one fresh runtime start in place of the draft
  (R2).
- `worktrees/list` is one `git worktree list`, run on demand and never polled.

**Constraints**:
- Names stay unique when starts run at the same time (SC-003).
- Nothing tracked by the project is edited (FR-010).
- Old records and old phone builds still decode.
- Nothing is removed without a check made by the daemon itself.

**Scale/Scope**:
- One model file, one daemon extension, three methods, four failure codes.
- A one-word change at about 14 call sites.
- One capsule, one badge, one project-page section.
- One tool property.

## Constitution Check

The constitution (`.specify/memory/constitution.md`) is still the unfilled template, so there are
no gates to check. This plan follows the working rules the repo does have:
- **Settle the UX before depth**: the Worktree capsule and the row badge are the new UI. Phase 3
  builds them against a daemon that can only make worktrees, and they're screenshotted with the
  run-app skill before listing, removal and `start_agent` are built.
- **One path, not two**: starting keeps using `start` and `freshSession`. The worktree only
  changes the `cwd` they're given. Filing goes through the single `projectFolder`.
- **Prove it running**: quickstart §3 checks each of the four runtimes for real, and §4 runs
  through the app on a scratch daemon.

Re-checked after design: still no violations.

## Project Structure

### Documentation (this feature)

```text
specs/030-agent-worktrees/
├── spec.md
├── plan.md              # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── worktrees.md
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/AgentWorktree.swift        # NEW: AgentWorktree, WorktreeChoice, WorktreeName.from(prompt:)
├── Model/Agent.swift                # worktree field, projectFolder
├── Model/Draft.swift                # StartDraft.worktree
├── Model/HelperLimit.swift          # projectFolder
├── Model/AppTool.swift              # start_agent's worktree property text
├── Client/AgentsModel.swift         # projectFolder; worktrees(in:) cache for the chooser
└── Daemon/DaemonAPI.swift           # StartRequest/StartHelperRequest.worktree; 3 methods; WorktreeSummary; RemovalCheck; 4 failures

Packages/AgentsKit/Sources/AgentsKit/
├── Projects/GitWorktrees.swift      # NEW: the R10 commands on GitProcess, porcelain parsing
├── ACP/Serve/AppService.swift       # start_agent schema property
└── Daemon/
    ├── DaemonCore+Worktrees.swift   # NEW: prepare (name, reserve, exclude, add), list, check, remove
    ├── DaemonCore+Commands.swift    # start: resolve choice → cwd before freshSession; liveSession: worktreeMissing
    ├── DaemonCore+Helpers.swift     # worktree choice through startHelper; projectFolder
    ├── DaemonCore+Projects.swift    # projectFolder (:20, :150)
    ├── DaemonCore+Attention.swift   # projectFolder (:91, :121)
    ├── DaemonCore+Workflows.swift   # projectFolder (:704)
    ├── DaemonCore+AppTools.swift    # projectFolder (:349)
    ├── DaemonCore+Dispatch.swift    # 3 cases
    └── DaemonCore.swift             # reservedWorktreeNames; projectChanged(projectFolder)

Daemon/Sources/main.swift            # relay start_agent's worktree argument

App/Sources/
├── AppModel.swift                   # draftWorktree, reset after start, worktree list fetch, projectFolder (:699)
├── Chat/PromptBar.swift             # Worktree SelectCapsule
├── AgentList/AgentRow.swift         # badge; projectFolder (:89)
├── Projects/ProjectAgentsView.swift # Worktrees section
├── Projects/WorktreeRow.swift       # NEW: row + Remove… flow
└── Projects/WorkflowPage.swift      # projectFolder (:382)

Remote/Sources/
├── RemoteModel.swift                # projectFolder (:370)
└── Projects/AgentCard.swift         # badge

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/WorktreeNameTests.swift             # NEW
├── Unit/AgentWorktreeRecordTests.swift      # NEW: worktree round trip; old record decodes; projectFolder
├── Unit/GitWorktreesTests.swift             # NEW: porcelain parsing
└── Integration/WorktreeStartTests.swift     # NEW: real git, fake runtime: make, file, list, resume, remove, concurrency, helper
```

**Structure Decision**: The existing layout. There are four new files:
- `AgentWorktree.swift`, beside `Agent.swift`.
- `GitWorktrees.swift`, beside `GitClone.swift`, which owns `GitProcess`.
- `DaemonCore+Worktrees.swift`, following the `DaemonCore+Area` split.
- `WorktreeRow.swift`, beside `WorkflowRow.swift`.

Plus four test files.

## Phases (for /speckit-tasks)

1. **Record and naming**:
   - `AgentWorktree`, `WorktreeChoice`, `Agent.worktree` and `projectFolder`.
   - `WorktreeName` with its tests.
   - The switch from `cwd` to `projectFolder` at every site listed in R5, with tests showing an
     agent in a worktree is filed under its project.
   - No UI yet.
2. **Daemon: making and starting (US1, P1)**:
   - `GitWorktrees` and `prepare`, with reservation and exclude.
   - `StartRequest.worktree` and `start` resolving it before `freshSession`.
   - The first chat line.
   - `worktreeMissing` on resume.
   - The integration tests.
   - **Then quickstart §3 against all four runtimes**. It's a gate: if a runtime doesn't work
     in the worktree, stop and bring it to Alex before any UI.
3. **Mac UI for US1**:
   - The Worktree capsule (Project folder / New worktree only) and the reset after a start.
   - The row badge.
   - Run-app screenshots of the capsule and the row. That's where to settle the layout with Alex
     before going further.
4. **Existing worktrees (US2, P2)**: `worktrees/list`, the listed choices in the capsule, and
   `existing` in `start`.
5. **Cleanup (US3, P2)**: `worktrees/check` and `worktrees/remove`, and the project page's
   Worktrees section with the Remove… flow.
6. **Agents (US4, P3)**: `start_agent`'s `worktree` property, relayed by `main.swift` and resolved
   in `startHelper`.
7. **Phone and proof**: the phone badge and `RemoteModel`, both builds, quickstart §4 with
   screenshots, and a phone screenshot.

## Risks

- **A runtime that obeys its process folder over the session's, or the other way round.** R2
  starts both in the worktree, so this can only bite a reused draft, which only happens for
  `existing`. Phase 2's gate checks `new` for real. If `existing` shows a problem, the fix is to
  never reuse a draft whose process folder differs.
- **Checkout time on a large repository.** `worktree add` checks out every tracked file. On this
  repo that takes well under a second. On a big monorepo it could take several seconds while the
  person waits after pressing send. The first chat line appears only after it finishes. If that
  proves slow, the next step is showing the agent as starting before git finishes. That's not
  planned now.
- **Missing untracked setup.** A new worktree has no `node_modules`, `.env` or build output (spec
  Assumptions). The first run of an agent there may spend a turn setting up. That's accepted and
  said in the spec, not solved here.
- **`.agents/worktrees` nested inside the project.** Tools that ignore git's exclude rules will see
  the nested copies. Alex chose this location knowing that. The exclude line covers git status and
  ripgrep, and the app's @-mention search already skips hidden folders.
- **The phone may not recognise a worktree agent.** An older phone build doesn't know the field
  and won't show the badge, but it takes its projects from the daemon, so filing is still right.
  Only the badge is missing.

## Complexity Tracking

None. No constitution gates, and nothing is added beyond what the spec asks for.
