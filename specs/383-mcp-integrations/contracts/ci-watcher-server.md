# Contract: the CI watcher MCP server

`Integrations/ci-watcher/`, a stdio server the daemon hosts (#488; until then it was an
http server on `127.0.0.1:8795`). It is set up in the project's `.agents/mcp.json` as `ci`:

```json
{ "mcpServers": { "ci": { "command": "node", "args": ["Integrations/ci-watcher/server.ts"], "hosted": true } } }
```

It listens on no port, and holds no token: every GitHub call is `gh api` (or `gh pr list`) as the signed-in person.

## Capabilities

```json
{ "tools": {}, "resources": {}, "events": { "listChanged": false },
  "extensions": { "io.modelcontextprotocol/ui": {} } }
```

## Events

| Name | `inputSchema` | `data` | `eventId` |
|---|---|---|---|
| `checks.failed` | `repo` (string, `owner/name`, required), `branch` (string, only runs on that PR branch), `pr` (positive integer, only that pull request); given filters must all hold | `{ pr: {number, title, branch, url}, headSha, run: {id, attempt, name, url}, failedJobs: [{name, url}] }` | `checks.failed:{repo}:{runId}:{attempt}` |
| `pr.merged` | `repo` (required), `branch` (string, only the PR from that branch), `pr` (positive integer, only that pull request); given filters must all hold | `{ pr: {number, title, branch, url}, mergedAt, mergeSha }` | `pr.merged:{repo}:{number}` |

| `issue.opened` (#682) | `repo` (required), `label` (only issues opened with it) | `{ issue: {number, title, author, labels, url}, openedAt }` | `issue.opened:{repo}:{number}` |
| `issue.labelled` | `repo` (required), `label` (only when it is the label added), `issue` (positive integer) | `{ issue, label, by, labelledAt }` | `issue.labelled:{repo}:{eventId}` |
| `issue.commented` | `repo` (required), `label` (only issues with it), `issue` | `{ issue, comment: {author, url, body}, commentedAt }`; `body` is cut to 4000 characters | `issue.commented:{repo}:{commentId}` |
| `issue.closed` | `repo` (required), `label` (only issues with it), `issue` | `{ issue, reason: "completed"\|"not_planned", by, closedAt }` | `issue.closed:{repo}:{eventId}` |

All have `delivery: ["poll"]`. Pull requests are never issues here, though GitHub lists them
together. The issue events read `issues` (by created), `issues/comments` and `issues/events`
(GitHub keeps 90 days of those). Every name is `noun.verbed`, and no noun is one the
app reserves, so workflows name them as they are (`checks.failed`), with no prefix. The cursor and paging rules are in
[research R10](../research.md#r10-the-ci-watcher-turning-github-into-events-with-a-cursor).

## Tools

| Tool | Input | Result | Annotations | Visibility |
|---|---|---|---|---|
| `list_prs` | `repo` | `{ prs: [{number, title, branch, url, checks: "passing"\|"failing"\|"running"\|"none", failedRunId?}] }` | `readOnlyHint: true` | `model`, `app`; `_meta.ui.resourceUri: "ui://ci/board"` |
| `list_issues` | `repo`, optional `label` | `{ issues: [{number, title, author, labels, url, comments, updatedAt}] }`, open issues newest updated first, at most 100 | `readOnlyHint: true` | `model`, `app`; `_meta.ui.resourceUri: "ui://ci/issues"` |
| `failed_log` | `repo`, `runId`, optional `job` | The last 300 lines of each failed job's log, as text | `readOnlyHint: true` | `model` |
| `rerun_failed` | `repo`, `runId` | `{ rerun: true, url }` | none: it changes something | `model`, `app` |
| `comment_on_pr` | `repo`, `number`, `body` | `{ url }` | none | `model` |

## Resources

`ui://ci/board`: one HTML page (`text/html;profile=mcp-app`), with no network
(`_meta.ui.csp` empty).
- It draws `list_prs`'s result as a list: number, title, branch, and a check pill.
- A failing PR has **Rerun**, which calls `rerun_failed` through `tools/call`, and then
  `list_prs` again.
- Links open through `ui/open-link`.
- Because `list_prs` is read-only and `app`-visible, the view can be pinned with
  `{repo: "alexec/Agents"}`.

`ui://ci/issues` (#682): the same kind of page, drawing `list_issues`'s result.
- A row is number, title, author, comment count, how long since it changed, and its labels.
- A label calls `list_issues` again with that `label`; the chosen label in the header, with
  ✕, calls it without. A pin's `label` argument starts it narrowed.

## Errors

- `gh` missing or not signed in: tools answer `isError: true` with the reason, and
  `events/poll` answers `-32012` with `data.reason: "gh not signed in"`.
- A GitHub rate limit: `-32013` with `retryAfterMs` from GitHub's reset header.
