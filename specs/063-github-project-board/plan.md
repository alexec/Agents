# Implementation Plan: GitHub Project Issue Board

**Branch**: `063-github-project-board` | **Date**: 2026-09-27 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/063-github-project-board/spec.md`

The agreed wireframe is the companion artifact in
[`specs/062-github-project-board/`](../062-github-project-board/README.md). This 063 directory is
the single canonical feature spec and implementation plan.

## Summary

Add a daemon-owned GitHub Projects v2 issue board to the project page, following the existing
pull-request query, cache, and refresh pattern. The daemon reads the first Project v2 linked to
the repository and its Ready and In progress issue items. A Ready issue can be assigned to a
fresh agent through a confirmation flow. Assignment creates a named issue branch/worktree,
starts the agent through the existing start path, records a durable issue-to-agent association,
and moves the project's status field to In progress. If the GitHub status write fails after the
agent starts, retain the agent and association, show that the board update is pending, and let
the person retry.

## Technical Context

**Language/Version**: Swift 6.0 in the app; Swift tools 6.2 package, strict concurrency
**Primary Dependencies**: SwiftUI; AgentsKit/AgentsKitCore; existing `gh` CLI GraphQL wrapper
**Storage**: Daemon-owned JSON cache and assignment records under its existing root
**Testing**: AgentsKit unit tests and manual Mac app walk; no tests run as part of this plan
**Target Platform**: macOS 27 app and daemon; iOS board UI out of scope
**Project Type**: macOS app plus Swift packages and daemon
**Performance Goals**: Load a previously cached board immediately; one refresh should fetch a
  single linked project and its board data, with pagination where required
**Constraints**: Use the person's existing `gh` authentication. Project reads require GitHub
  Projects read permission; changing status requires Projects write permission. Never store a
  GitHub token in app or daemon records. Do not claim an issue is assigned until a new agent
  exists. If status mutation fails after launch, preserve and show the successful local work and
  offer a status-sync retry.
**Scale/Scope**: One linked Project v2 per repository, first in GitHub's returned connection
  order; only Ready and In progress issue items; a fresh agent for each assignment.

## Constitution Check

The checked-in `.specify/memory/constitution.md` contains only the unfilled template, so it
defines no ratified project principles or gates. The plan follows the repository's documented
Spec Kit workflow, reuses the existing GitHub authentication and agent-start paths, and keeps
the first release to two statuses and one selected project.

**Gate result**: Pass; no substantive constitution constraints are present to violate.

## Project Structure

### Documentation (this feature)

```text
specs/063-github-project-board/
├── plan.md
├── research.md
├── data-model.md
├── contracts/
│   ├── daemon-api.md
│   └── github-projects.md
├── quickstart.md
└── tasks.md                 # generated in the next Spec Kit phase
```

### Source Code (repository root)

```text
App/Sources/Projects/
├── ProjectAgentsView.swift          # board placement and first load
└── GitHubProjectBoardSection.swift  # board, refresh/error/empty states, assignment sheet

App/Sources/AppModel.swift           # board cache and assignment actions

Packages/AgentsKitCore/Sources/AgentsKitCore/
├── Model/GitHubProjectBoard.swift   # board, issue, assignment identity
├── Model/AgentWorktree.swift        # add a named new-worktree choice
└── Daemon/DaemonAPI.swift           # board list/refresh/assign contracts

Packages/AgentsKit/Sources/AgentsKit/
├── GitHub/GitHubProjectQuery.swift  # Projects v2 GraphQL queries/decoding
├── GitHub/GitHubProjectStore.swift  # daemon cache and issue associations
└── Daemon/DaemonCore+GitHubProjects.swift

Packages/AgentsKit/Tests/AgentsKitTests/Unit/
└── GitHubProjectQueryDecodingTests.swift
```

**Structure Decision**: Follow the existing two-part package boundary: portable board and
daemon protocol models live in AgentsKitCore; `gh`, process execution, persistence, GitHub
queries, and assignment orchestration live in AgentsKit/daemon. SwiftUI reads daemon results
through AppModel and renders the board beside existing project sections. Assignment uses the
existing daemon start path with an added named-new-worktree choice rather than creating a
second runtime launch path.

## Design Decisions

1. **Project lookup and board loading**: Query the repository's linked `projectsV2` connection,
   use the first result in its returned order, then load project items and field metadata. Do
   not search all of a user's or organization's projects.
2. **Status interpretation**: Find the single-select Status field and its option identifiers by
   their labels. Show only items whose option is Ready or In Progress. Disable assignment with
   an explanatory state if the project has no matching In Progress option or the user cannot
   write project fields.
3. **Issue-agent relationship**: Persist issue identity (host, repository, issue node ID/number,
   project/item identity) with the started agent ID and worktree/branch. Do not infer assignment
   from a branch name alone. Use the existing worktree record for current branch and path.
4. **Branch naming**: Add a named-new-worktree choice. Generate a safe, bounded name from
   `issue-<number>-<title-slug>` and pass it through the existing worktree creation guard and
   collision handling. The app's existing `agents/` namespace and `.agents/worktrees` folder
   remain in effect.
5. **Assignment and status update**: Start the agent/worktree first, record its issue link, then
   update the GitHub Project item to In Progress. If that final mutation fails, retain the
   running agent and local association; show the issue as assigned with an explicit GitHub
   status-sync error and retry action. Never silently roll back or stop working agent state.
6. **Authentication**: Reuse `GitHubCLI.graphql` and the user's `gh` session. Explain that read
   access needs `read:project` and assignment/status updates need `project` scope (or equivalent
   fine-grained permissions). Do not ask the app to capture or store credentials.
7. **Refresh/cache**: Keep board cache daemon-owned and keyed by normalized project folder.
   Return the last good board immediately, mark it stale on refresh failure, and publish a
   board-changed notification after refresh or assignment updates.

## Complexity Tracking

No constitution violations or project-boundary additions are proposed.

## Post-design Constitution Check

The model keeps Project items owned by GitHub, keeps runtime/worktree state owned by the
existing daemon, and adds only the smallest durable issue association needed to connect them.
No token storage or additional client/server platform is introduced. The agreed two-lane and
first-project scope is preserved.

**Gate result**: Pass; the design remains within the stated scope and no ratified constitution
rule applies.
