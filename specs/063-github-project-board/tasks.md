# Tasks: GitHub Project Issue Board

**Input**: Design documents from `specs/063-github-project-board/`

**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, and `contracts/`

**Tests**: No new test tasks are included. Verification follows the requested worktree app
walkthrough and existing build/test commands where applicable.

## Phase 1: Setup

**Purpose**: Establish the selected feature context and implementation locations.

- [X] T001 Confirm the selected feature remains `specs/063-github-project-board` in `.specify/feature.json`
- [X] T002 Confirm the 062 wireframe companion is linked from `specs/063-github-project-board/spec.md` and `specs/062-github-project-board/README.md`

---

## Phase 2: Foundational

**Purpose**: Add shared board/assignment data and the named issue-worktree start path required by both stories.

- [X] T003 [P] Define GitHub Project board, issue, error, and assignment-sync Codable models in `Packages/AgentsKit/Sources/AgentsKitCore/Model/GitHubProjectBoard.swift`
- [X] T004 [P] Add board list/refresh/assign/status-sync methods, request and response DTOs, and changed notification to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`
- [X] T005 Add durable issue assignment storage keyed by repository and issue identity in `Packages/AgentsKit/Sources/AgentsKit/GitHub/GitHubProjectStore.swift` and its location in `Packages/AgentsKit/Sources/AgentsKit/Store/StoreLocations.swift`
- [X] T006 Add a named new-worktree choice and bounded issue-number/title slug naming in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentWorktree.swift`
- [X] T007 Implement named-worktree preparation through existing path/collision checks in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Worktrees.swift`

**Checkpoint**: Models, socket contract, assignment persistence, and deterministic branch naming are ready for story work.

---

## Phase 3: User Story 1 — See the repository's active issues (Priority: P1)

**Goal**: Load the first linked Projects v2 board and show Ready/In Progress issues and any known local agent/worktree association.

**Independent Test**: Open a GitHub project repository; see only Ready and In Progress cards. Confirm cached/stale/error/empty states, first-linked project choice, and existing assignment links. A non-GitHub project has no board section.

- [X] T008 [P] Implement Projects v2 GraphQL query, status option decoding, and paginated issue decoding in `Packages/AgentsKit/Sources/AgentsKit/GitHub/GitHubProjectQuery.swift`
- [X] T009 Implement daemon board lookup, refresh/cache, permission failures, stale results, and changed notifications in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+GitHubProjects.swift`
- [X] T010 Add AppModel board cache, initial load, refresh, and notification handling in `App/Sources/AppModel.swift`
- [X] T011 [P] Render the board section, two status lanes, issue cards, open-on-GitHub action, responsive stacking, and loading/empty/error/stale states in `App/Sources/Projects/GitHubProjectBoardSection.swift`
- [X] T012 Place the board beside Pull requests on the project page and trigger initial loading in `App/Sources/Projects/ProjectAgentsView.swift`

---

## Phase 4: User Story 2 — Assign a Ready issue to a new agent (Priority: P1)

**Goal**: Confirm a fresh agent/runtime/task context, start it in a new issue branch/worktree, link it to the issue, then synchronize GitHub status to In Progress with a retry path.

**Independent Test**: Assign a Ready issue. Confirm a new agent runs in an issue-named worktree, GitHub moves the existing item to In Progress, and the card links its issue, agent, branch, and worktree. Force status-write failure and confirm retry does not start another agent; cancel and confirm no work is created.

- [X] T013 Implement the assignment sheet with runtime choice, editable issue-derived prompt, branch preview, and cancel/confirm actions in `App/Sources/Projects/GitHubProjectBoardSection.swift`
- [X] T014 Implement daemon validation, duplicate-request protection, fresh agent start with named worktree, and persisted issue association in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+GitHubProjects.swift`
- [X] T015 Implement ProjectV2 Status/In Progress mutation and idempotent status-only retry in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+GitHubProjects.swift`
- [X] T016 Connect Ready card assignment and In Progress card agent/worktree navigation, live agent state, and status-sync retry in `App/Sources/Projects/GitHubProjectBoardSection.swift` and `App/Sources/AppModel.swift`
- [X] T017 Document GitHub Project setup, permissions, and issue assignment in `docs/how-to/assign-a-github-issue.md`
- [X] T018 Explain issue-agent/worktree relationships in `docs/explanation/projects-hosts-worktrees.md`

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Complete and validate the feature against the two numbered design artifacts and the user requirements.

- [ ] T019 Verify board and assignment behavior against `specs/063-github-project-board/quickstart.md` using the scratch app workflow
- [X] T020 Review localization, VoiceOver labels, narrow-window layout, and actionable GitHub permission copy in `App/Sources/Projects/GitHubProjectBoardSection.swift`
- [X] T021 Confirm the canonical spec, plan, and tasks remain in `specs/063-github-project-board/` and the companion wireframe remains linked from `specs/062-github-project-board/README.md`

## Dependencies

```text
T001–T002 → T003–T007 → T008–T012 (US1) → T013–T018 (US2) → T019–T021
```

US2 depends on US1's board data and card identity. Within the foundational phase, T003 and T004
can proceed in parallel; T006 can proceed in parallel with them. T005 and T007 depend on the
shared models/worktree contract. In US1, T008 and T011 can proceed in parallel after T003/T004;
T009 follows T008 and T005, while T010/T012 follow the API contract. US2's sheet (T013) can
proceed alongside daemon assignment work (T014/T015); UI wiring (T016) follows both.

## Parallel Opportunities

- T003, T004, and T006 touch separate files and can be implemented concurrently.
- T008 (query) and T011 (visual section) can proceed separately once the shared model shape is
  settled.
- T013 (assignment sheet) can proceed while daemon assignment orchestration and status mutation
  (T014–T015) are implemented.
- Documentation tasks T017 and T018 touch separate pages.

## Implementation Strategy

### MVP First

Deliver US1 first: read the first linked project, render Ready/In Progress issues, and handle
cache/error states. Then deliver US2: assign Ready issues, link the new agent/worktree, and
synchronize or retry the GitHub status update.

### Validation

Use the independent test criteria in each user-story phase and the scratch app walkthrough in
`quickstart.md`. Do not use the user's real daemon or agent records.
