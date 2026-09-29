# Data Model: GitHub Project Issue Board

## GitHubProjectBoard

One GitHub Projects v2 board linked to a local project repository.

| Field | Meaning |
|---|---|
| projectFolder | Normalized folder of the app project, used to scope cache and actions |
| repository | GitHub host, owner, repository name, and URL already resolved from `origin` |
| projectID | GitHub node ID of the selected Projects v2 project |
| projectTitle | Name shown in the board heading |
| projectURL | Web URL for opening the full project in GitHub |
| statusFieldID | ID of the project's single-select Status field, when available |
| readyOptionID | Project-specific ID for the Ready status option |
| inProgressOptionID | Project-specific ID for the In Progress status option |
| issues | Items with issue content and status Ready or In Progress |
| fetchedAt | Time of the last successful fetch |
| problem | Most recent unavailable, stale, or permission problem, if any |

**Rules**:

- The board is absent when no readable Project v2 is linked to the repository.
- Only one board is selected: the first linked project in the GitHub connection response.
- Status field and option IDs are read from GitHub; they are not portable between projects.
- When GitHub cannot be reached, retain the last successful board and mark it stale.

## GitHubProjectIssue

An issue in the selected project's Ready or In Progress lane.

| Field | Meaning |
|---|---|
| issueNodeID | Stable GitHub issue identity |
| number | Issue number in the repository |
| title | Issue title |
| body | Issue description used to prepare the agent task |
| labels | Labels shown on the issue card |
| issueURL | GitHub issue page URL |
| projectItemID | Identity of this issue's item in the selected project |
| status | `ready` or `inProgress`, derived from this project's status field |
| assignment | Optional local agent assignment, if this app started one |
| statusSync | Whether local assignment status is reflected in GitHub, or needs retry |

**Rules**:

- An issue without a recognized Ready or In Progress option is not included in the board.
- A branch association alone does not prove an app agent is assigned to an issue.
- Issue identity includes repository/host scope; issue numbers alone are not globally unique.

## GitHubIssueAssignment

The durable relationship created when the person assigns a Ready issue to a fresh agent.

| Field | Meaning |
|---|---|
| repository | GitHub host, owner, and repository |
| projectID | Selected GitHub project node ID |
| projectItemID | GitHub project item whose Status is moved to In Progress |
| issueNodeID / issueNumber | Stable issue reference and user-facing number |
| agentID | ID of the fresh app agent |
| worktree | Agent's recorded worktree name, root and branch |
| taskPrompt | User-reviewed starting task context, excluding any GitHub token |
| requestID | Idempotency identity for a retried assignment request |
| statusSync | `pending`, `synced`, or `failed` with a user-readable reason |
| createdAt / updatedAt | Assignment and last status-sync attempt times |

**Rules and transitions**:

```text
Ready issue
   │ confirm assignment
   ▼
Starting agent + named worktree
   ├── start fails ──> no assignment; issue stays Ready
   ▼
Agent started; local issue association saved
   ├── GitHub status update fails ──> assignment stays active; statusSync = failed
   │                                   show retry and sync problem
   ▼
GitHub status updated to In Progress; statusSync = synced
```

The daemon must not stop an already-running agent to compensate for a GitHub status write
failure. A retry changes only the board status; it does not start another agent or worktree.

## Relationship to existing entities

- A `GitHubIssueAssignment` points to one `Agent` and its existing `AgentWorktree` record.
- Agent state remains owned by the ordinary agent lifecycle; the board reads its current state.
- A GitHub board item remains owned by GitHub. Local cache data is disposable; assignment
  records are retained for reliable issue-to-agent navigation and status retry.
- An issue moved out of the two displayed statuses disappears from the board lanes; its agent
  and worktree continue to appear in the app's ordinary project views.
