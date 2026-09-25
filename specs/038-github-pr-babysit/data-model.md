# Data Model: My Pull Requests, Babysat

Types in `AgentsKitCore` are read by both the daemon and the Mac app. The ones marked *daemon* live
in `AgentsKit` and never go over the wire.

## GitHubRepository (Core, new)

Read from a project's `origin` (FR-001).

| Field | Type | Notes |
|---|---|---|
| `host` | String | Lowercased. From `GitRemote.host`. |
| `owner` | String | The first part of `GitRemote.path`. |
| `name` | String | The second part, with `.git` removed. |

- `init?(remote: GitRemote)` returns nil unless `host.contains("github")` and the path has exactly
  two parts.
- `webURL` is `https://<host>/<owner>/<name>`.

## PullRequest (Core, new)

One of the viewer's open pull requests on the repository, as last fetched.

| Field | Type | Notes |
|---|---|---|
| `number` | Int | Its identity within the project. |
| `title`, `url` | String, URL | |
| `isDraft` | Bool | |
| `createdAt` | Date | Sort key, newest first (FR-004). |
| `headBranch`, `headOid` | String | |
| `baseBranch`, `baseOid` | String | |
| `headRepositoryURL` | URL | Where `push_pull_request` pushes (R7). |
| `isFromFork` | Bool | |
| `checks` | `PullRequestChecks` | `.passing`, `.failing([FailedCheck])`, `.running`, `.none` |
| `review` | `PullRequestReview` | `.approved`, `.changesRequested`, `.commented`, `.none` |
| `conflicts` | `PullRequestConflicts` | `.clean`, `.conflicting`, `.unknown` |
| `countableComments` | `[ReviewItem]` | Only the ones that pass FR-011a, newest last. |
| `worktree` | `AgentWorktree?` | The matched worktree (R4), or nil. The project folder counts. |
| `babysitting` | `BabysittingStatus` | See below. |

`FailedCheck`: `id`, `name`, `logURL`.

`ReviewItem`: `id` (Int, GitHub's databaseId), `kind` (`.review`, `.threadComment` or
`.conversationComment`), `author`, `body`, `path?`, `line?`, `createdAt`, `url`.

## BabysittingStatus (Core, new)

What the pull request's row says about babysitting (FR-019, FR-023).

| Field | Type | Notes |
|---|---|---|
| `lastRun` | `WorkflowOutcome?` | For this pull request, across its workflows. `.ran` leads to the agent. |
| `lastRunWorkflowID` | String? | Which workflow that was. |
| `consecutiveRuns` | Int | 0–3. |
| `isStopped` | Bool | True at the limit, until reset (R8). Shows Resume. |
| `isRunning` | Bool | A run is in flight on it. |

## PullRequestList (Core, new)

The whole section for one project, sent whole like `WorkflowSummary`.

| Field | Type | Notes |
|---|---|---|
| `folder` | URL | The project. |
| `repository` | `GitHubRepository` | |
| `viewer` | String? | The signed-in login, once known. |
| `pullRequests` | `[PullRequest]` | Sorted by `createdAt`, newest first. |
| `fetchedAt` | Date? | When the list was last good. |
| `problem` | `PullRequestProblem?` | `.noCLI`, `.notSignedIn(host)`, `.cannotSee(host, repo)`, `.unreachable(String)`. It has a `message` giving FR-003's one line (R1). |
| `babysitterWorkflowID` | String? | A workflow here with a pull-request trigger, if any (US4-2). |

A project that is not on GitHub has no `PullRequestList`, so the section is absent (SC-006).

## WorkflowTrigger (Core, changed)

Three new cases. The file spelling is used for the name.

| Case | File name | `summary` |
|---|---|---|
| `.pullRequestChecksFailed` | `pull-request-checks-failed` | "When checks fail on one of my pull requests" |
| `.pullRequestReviewComments` | `pull-request-review-comments` | "When one of my pull requests gets review comments" |
| `.pullRequestConflicts` | `pull-request-conflicts` | "When one of my pull requests conflicts with its base" |

- `isPullRequest` is true for all three.
- The type gets hand-written `Codable`, and the new cases are written as `.unrecognised` would be
  (R11).

## WorkflowRefusal (Core, changed)

| Case | `message` | `needsAPerson` |
|---|---|---|
| `.noWorktree(pr: Int)` | "#n has no local worktree" | no |
| `.worktreeDirty(pr: Int)` | "#n's worktree has uncommitted changes" | no |
| `.worktreeBusy(pr: Int)` | "an agent is already working in #n's worktree" | no |
| `.noPullRequest` | "nothing says which pull request" (Run now on a workflow whose only triggers are pull-request ones) | no |
| `.babysittingStopped(pr: Int, runs: Int)` | "babysitting #n stopped after 3 tries in a row" | **yes** |

`isSameReason` compares the case and the pull request number, so repeats collapse for each pull
request.

## WorkflowRun (Core, changed)

- New: `pullRequest: PullRequestRef?`. `PullRequestRef` has `number`, `headBranch`, `worktree:
  URL` and `changeKey: String`.
- The in-flight key is `workflow.id`, with `#<number>` appended when `pullRequest` is set (R9).

## WorkflowState (daemon, changed)

- New: `standingAgentIDs: [Int: UUID]`, for `standing` mode, one agent for each pull request
  (FR-017). Decoded with `decodeIfPresent`, defaulting to empty.

## PullRequestRecord (daemon, new), in `pull-requests.json`

One for each (project folder, pull request number).

| Field | Type | Notes |
|---|---|---|
| `folder`, `number` | URL, Int | Key. |
| `firedKeys` | `[String: String]` | Keyed by `"<workflowID>/<trigger name>"`, holding the last change key fired (R6). |
| `commentWatermark` | `[String: Int]` | Keyed by workflow ID, holding the newest countable item id fired on. |
| `consecutiveRuns` | Int | R8. |
| `stoppedAt` | Date? | |
| `lastRunStartedAt` | Date? | |
| `lastOutcome` | `WorkflowOutcome?` | With `lastOutcomeWorkflowID`. |
| `pushedOids` | `[String]` | The last 20 (R8). |
| `postedCommentIDs` | `[Int]` | The last 50. |

`PullRequestRecords` also keeps `lists: [PullRequestList]`, the last good list for each project
(FR-009), and `lastAttemptAt: [String: Date]`, keyed by folder path (R3).

When a pull request drops out of the list (merged or closed), its record is removed on the next
good refresh (US1-5).

## State transitions: one pull request, one workflow

```
            change key new ──► checks (R9 order) ──refused──► record refusal (collapses)
                  ▲                    │
                  │                    ▼ ok
   refresh ───────┘              run in flight ──── changes meanwhile: key left unfired
                                       │
                                       ▼ run ends
                         consecutiveRuns += 1 (at start) ; refresh due ≥1 min later
                                       │
                 consecutiveRuns == 3 ─┴─► next fire refused .babysittingStopped
                                              │
          foreign push / countable comment / Resume ──► consecutiveRuns = 0
```
