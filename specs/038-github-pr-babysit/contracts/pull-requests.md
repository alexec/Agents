# Contract: Pull Requests

Five daemon methods, one notification, two app tools, three workflow-file trigger names, and the
Mac section. The types are in [data-model.md](../data-model.md).

## Daemon methods (`DaemonAPI`)

| Method | Params | Result | Notes |
|---|---|---|---|
| `pullRequests/list` | `{ folder }` | `PullRequestList?` | Cached. Never runs `gh`. `null` when the project is not on GitHub. |
| `pullRequests/refresh` | `{ folder }` | `PullRequestList?` | Runs a refresh unless the last attempt was under 60 s ago (FR-008). Then returns the list. |
| `pullRequests/resume` | `{ folder, number }` | `PullRequestList` | Resets the babysitting count (FR-024). |
| `pullRequests/checkout` | `{ folder, number }` | `PullRequestList` | Makes a worktree on the pull request's branch (R5). Fails with `worktreeExists`, `branchCheckedOut` or `fetchFailed`, each with a message. |
| `pullRequests/addBabysitter` | `{ folder }` | `WorkflowSummary` | Writes the starter (R10). Fails with `overLimit` as `manage_workflows` does, or `babysitterExists` with its workflow id. |

**Notification** `pullRequestsChanged`: `PullRequestList`. Sent after each refresh that changed
something, and after each fire, refusal or run end that involves a pull request.

The phone is not sent any of these (FR-010).

## App tools (served by `AppService`, auto-allowed)

### `push_pull_request`

```json
{ "name": "push_pull_request",
  "description": "Push this worktree's commits to the pull request you were started for. Never force-pushes: if the remote has commits you don't, bring them in first and push again. Only works in a run started for a pull request.",
  "inputSchema": { "type": "object", "properties": {} } }
```

Replies:
- "Pushed <short oid> to <head> (#n)."
- "Git refused: <stderr>". A non-fast-forward, for example, says to pull first.
- "Only a run started for a pull request can push or reply; ask the person to do it."
- "This agent is not in #n's worktree."

### `reply_on_pull_request`

```json
{ "name": "reply_on_pull_request",
  "description": "Reply on the pull request you were started for. Give in_reply_to (a comment id from your prompt) to answer a review comment in its thread; leave it out to comment on the pull request itself.",
  "inputSchema": { "type": "object", "required": ["body"],
    "properties": { "body": { "type": "string" },
                    "in_reply_to": { "type": "integer" } } } }
```

Replies:
- "Replied: <url>".
- "Comment <id> is not on #n."
- The same refusal as for the push.

Neither tool takes a pull request number, a branch or a repository. The daemon takes all three from
the caller's run (R7), and that is what makes FR-022 hold.

## Workflow file

```yaml
on:
  - pull-request-checks-failed
  - pull-request-review-comments
  - pull-request-conflicts
```

- The three names take no settings.
- They may be mixed with other triggers. Only the pull-request ones fire on pull requests.
- `pull-request-review-comments` counts only reviews and comments whose author has write access
  (`authorAssociation` of OWNER, MEMBER or COLLABORATOR, FR-011a). Others never fire and never
  appear in the prompt.
- Run now on a workflow with only pull-request triggers is refused with `.noPullRequest`
  ("nothing says which pull request"). A pull-request run always needs one.

## Mac: the Pull requests section (ProjectAgentsView)

Placed between Sessions and Workflows, and present only when `pullRequests/list` returns a list.

```
Pull requests                                   ↻  Babysit my pull requests
─────────────────────────────────────────────────────────────────────────
#412  Fix login redirect            Draft  ✕ checks  ● changes requested  ⚠ conflicts
      in worktree fix-login-redirect · Babysat 2 min ago →
#398  Paper theme settings card            ✓ checks  ✓ approved
      Check out into a worktree
#377  Retry flaky upload                   ✕ checks
      in project folder · Babysitting stopped after 3 tries · Resume
─────────────────────────────────────────────────────────────────────────
Fetched 3 min ago
```

- Clicking a row opens `url` in the browser (FR-005).
- The worktree text leads to that worktree's agents (FR-006).
- "Babysat …" leads to the run's agent (FR-019).
- Refused runs show as grey text. Only a stopped pull request, like a workflow that needs a person,
  gets colour.
- `problem` replaces the rows with its one line (FR-003). When the failure is `.unreachable` and
  there is a cached list, the rows stay and the footer says "Couldn't reach GitHub · showing
  <time>" (FR-009).
- Babysit my pull requests becomes **Show babysitter** when `babysitterWorkflowID` is set (US4-2).
- The workflow row itself is unchanged, apart from the trigger summaries and refusal lines above.
