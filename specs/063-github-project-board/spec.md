# Feature Specification: GitHub Project Issue Board

**Feature Branch**: `063-github-project-board`

**Created**: 2026-09-27

**Status**: Draft

**Input**: User description: "We currently have the ability to show pull requests. Also show the GitHub project for the repo. The goal of this feature is to track which issues agents are working on (\"In progress\" on the board with a branch that relates to a worktree that an agent is working on), and to allow you to assign an issue to an agent (\"Ready\" issues on the board). Start with a wireframe."

## Why this feature exists

People can already see pull requests for a GitHub repository in the project page, and agents can
work in separate worktrees. What is missing is a shared view of the issues the team is ready to
work on and the issues an agent has picked up. Showing the repository's GitHub Project beside
the existing project work lets a person start an agent directly from a Ready issue, then see
which agent, branch and worktree are carrying an In progress issue.

The agreed first version uses the first GitHub Project associated with the repository, shows
only Ready and In progress issues, and starts a fresh agent in an automatically created issue
branch and worktree when an issue is assigned.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See the repository's active issues (Priority: P1)

The person opens a project whose repository is on GitHub. The project page shows the first
GitHub Project associated with that repository, with issues in Ready and In progress. Ready
issues are available to assign. In progress issues show the agent working on them and the
related branch and worktree.

**Why this priority**: The board gives the person one place to see available work and work
already claimed by agents. Assignment is more useful when the board also reflects the work in
progress.

**Independent Test**: Open a GitHub repository with a project containing Ready, In progress,
and completed issues. Confirm the board shows only the first two statuses and that an In
progress issue with an agent worktree identifies its agent, branch and worktree. Confirm that
a non-GitHub project has no issue board.

**Acceptance Scenarios**:

1. **Given** a repository with one associated GitHub Project containing Ready and In progress
   issues, **When** the person opens the repository's project page, **Then** the board shows
   those issues grouped under Ready and In progress.
2. **Given** a repository associated with more than one GitHub Project, **When** the board is
   shown, **Then** it shows the first project returned for that repository.
3. **Given** a board with issues in other statuses, **When** the board is shown, **Then** only
   Ready and In progress issues appear.
4. **Given** an In progress issue assigned to an agent working in a worktree, **When** the
   person views its card, **Then** the card identifies the agent, branch and worktree.
5. **Given** a project that is not associated with a GitHub repository or has no associated
   GitHub Project, **When** the person opens it, **Then** no issue board is shown.
6. **Given** GitHub cannot be reached temporarily and a previously fetched board is available,
   **When** the person opens the project page, **Then** the last available board remains visible
   with an indication that it may be out of date.

### User Story 2 - Assign a Ready issue to a new agent (Priority: P1)

The person chooses Assign to agent on a Ready issue. They choose a runtime and can review or
edit the starting prompt based on the issue title and description. On confirmation, the app
creates a fresh agent in a new worktree on a branch for the issue and starts the agent with
that issue's work. The board reflects the issue as In progress and the card connects the issue
to the agent, branch and worktree.

**Why this priority**: Starting work from a Ready issue closes the gap between the board's
backlog and the agents already running in the app.

**Independent Test**: Assign a Ready issue to a chosen runtime. Confirm a new agent starts in
its own worktree on a branch for that issue, the prompt contains the issue context, and the
board shows the issue as In progress with links to its work.

**Acceptance Scenarios**:

1. **Given** a Ready issue, **When** the person chooses Assign to agent, **Then** the
   assignment flow identifies the issue and offers creation of a fresh agent.
2. **Given** the assignment flow, **When** the person selects a runtime and confirms, **Then**
   a fresh agent starts with the issue title and description as its task context, in a new
   worktree on a branch named for the issue.
3. **Given** an issue is successfully assigned, **When** the board next reflects the change,
   **Then** the issue appears under In progress and its card shows the new agent, branch and
   worktree.
4. **Given** the person cancels before confirming, **When** the assignment flow closes,
   **Then** no agent or worktree is created and the issue remains Ready.
5. **Given** worktree creation or agent startup fails, **When** the failure is reported,
   **Then** the person sees why, no untracked partial assignment is presented as successful,
   and the issue remains available under Ready.
6. **Given** the agent starts but GitHub cannot update the issue's board status, **When** the
   assignment result is shown, **Then** the issue remains linked to that agent and worktree,
   the board status update is marked as needing retry, and retrying does not start another
   agent.

### Edge Cases

- The repository has no associated GitHub Project: do not show an empty or misleading board.
- The repository has multiple associated projects: consistently choose the first one returned.
- The board has no issues in either supported status: show the two empty status groups without
  completed or other-status issues.
- An In progress issue has no corresponding agent or worktree known to this app: show the issue
  and its available GitHub branch information without inventing an agent association.
- A branch exists for an issue but is not checked out in an agent worktree: do not claim that
  an agent is working on it.
- Two assignments request the same issue branch: do not start two agents in the same new
  worktree; explain the conflict and leave the issue available for resolution.
- A project board is unavailable or GitHub access is missing: explain the issue and provide a
  way to retry, while keeping unrelated project page content usable.
- GitHub status update fails after agent startup: preserve the active agent and issue link,
  clearly mark the board update as unsynchronized, and retry only the status update.
- The selected project has no Status field or no In Progress option: show why assignment is
  unavailable rather than starting work that cannot be reflected on the board.
- The project page is too narrow for side-by-side columns: present Ready and In progress in a
  readable stacked layout.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The project page MUST show an issue board for a GitHub repository when an
  associated GitHub Project can be read.
- **FR-002**: When more than one GitHub Project is associated with the repository, the app
  MUST show the first project returned.
- **FR-003**: The board MUST show issues in the Ready and In progress statuses only.
- **FR-004**: Each issue card MUST identify the issue by its number and title, and MUST show
  its description and available labels when present.
- **FR-005**: A Ready issue MUST offer an Assign to agent action.
- **FR-006**: Assigning an issue MUST create a fresh agent; the person MUST be able to choose
  the runtime before starting it.
- **FR-007**: Before starting the agent, the assignment flow MUST let the person review the
  task context based on the issue title and description.
- **FR-008**: A confirmed assignment MUST create a new branch and worktree for the issue and
  start the new agent in that worktree.
- **FR-009**: The assignment MUST associate the issue's In progress board entry with the
  created agent, branch and worktree.
- **FR-010**: The In progress issue card MUST show the associated agent's current state and
  identify its branch and worktree.
- **FR-011**: The person MUST be able to open the issue on GitHub and navigate from an
  associated issue card to its agent and worktree in the app.
- **FR-012**: Cancelling assignment MUST leave the issue, agent list and worktrees unchanged.
- **FR-013**: If branch/worktree creation or agent startup fails, the app MUST explain the
  failure and MUST NOT present the issue as successfully assigned.
- **FR-014**: The issue board MUST provide a way to retry loading or refreshing its content.
- **FR-015**: When a previously loaded board cannot be refreshed, the app MUST distinguish
  its cached content from current GitHub data.
- **FR-016**: A project without a readable associated GitHub Project MUST NOT show fabricated
  issue data; it MUST explain an actionable access or availability problem when one exists.
- **FR-017**: If an agent starts but the GitHub status update fails, the app MUST preserve the
  issue-to-agent association, identify the status update as unsynchronized, and offer a retry
  that does not create another agent or worktree.
- **FR-018**: The app MUST disable issue assignment when the selected project has no Status
  field or no In Progress option, and MUST explain what board configuration is missing.

### Key Entities

- **GitHub Project**: The board associated with the repository; the first associated project
  is selected for display.
- **Issue**: A GitHub issue with an identifier, title, description, labels, board status, and
  optional branch and agent association.
- **Agent assignment**: The relationship between one issue and a fresh agent started to work
  on it.
- **Worktree**: The isolated checkout and branch in which the assigned agent works on the
  issue.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a repository with a readable GitHub Project, a person can identify all
  visible Ready and In progress issues from the project page without opening GitHub.
- **SC-002**: A person can start work on a Ready issue using the assignment flow in no more
  than three decisions after opening that issue's assignment action: choose runtime, confirm
  task context, and assign.
- **SC-003**: Every successful assignment is traceable from the issue card to exactly one
  newly started agent and its issue branch/worktree.
- **SC-004**: In a board containing other statuses, 100% of the displayed issue cards belong
  to Ready or In progress.
- **SC-005**: If assignment fails, the person can identify the failure reason and the issue
  remains available for another attempt.

## Docs *(mandatory)*

- `docs/how-to/assign-a-github-issue.md` — add: show the board and assign a Ready issue to a
  fresh agent working in an issue branch and worktree.
- `docs/explanation/projects-hosts-worktrees.md` — change: explain how issue assignments
  connect GitHub Project issues to agents and worktrees.

## Assumptions

- The repository already has a GitHub identity and pull request support; the feature reuses
  that repository association and access setup.
- GitHub Project board statuses are named Ready and In progress for this first version.
- The first associated project means the first one returned by the existing project lookup.
- The new agent's initial task is populated from the issue title and description and can be
  reviewed before it starts.
- A successful assignment moves or records the issue under In progress in the GitHub Project.
- The board is shown on the Mac project page alongside pull requests; mobile presentation is
  outside this first version.
- The agreed wireframe is at [wireframe.md](../062-github-project-board/wireframe.md).
