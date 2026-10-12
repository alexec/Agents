# Contract: the CI watcher MCP server

`Packages/MCPServers` (`CIWatcher`, the `ci-watcher` binary), a stdio server the daemon hosts
(#488; until then it was an http server on `127.0.0.1:8795`). Since #700 it is a static Swift
binary that Agents Host and the Linux host carry beside `agentsd`; it was `node server.ts`
in `Integrations/ci-watcher/` before. It is set up in the project's `.agents/mcp.json` as `ci`:

```json
{ "mcpServers": { "ci": { "command": "ci-watcher", "hosted": true } } }
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
| `checks.failed` | `repo` (string, `owner/name`; left out, the project folder's repo, #702), `branch` (string, only runs on that PR branch), `pr` (positive integer, only that pull request), `anyone` (boolean, #728); given filters must all hold | `{ pr: {number, title, branch, url}, headSha, run: {id, attempt, name, url}, failedJobs: [{name, url}] }` | `checks.failed:{repo}:{runId}:{attempt}` |
| `pr.opened` (#833) | as `checks.failed` | `{ pr: {number, title, branch, url, author}, openedAt }`; a PR open and not a draft now that was not at the last poll, so a draft marked ready is raised then and a reopened PR again. Drafts never count. The cursor's ids are the open, ready PRs then; a first poll takes those already open as known | `pr.opened:{repo}:{number}:{openedAt}` |
| `pr.merged` | `repo` (optional), `branch` (string, only the PR from that branch), `pr` (positive integer, only that pull request); given filters must all hold | `{ pr: {number, title, branch, url}, mergedAt, mergeSha }` | `pr.merged:{repo}:{number}` |
| `pr.closed` (#702) | `repo` (optional), `branch` (string, only the PR from that branch), `pr` (positive integer, only that pull request); given filters must all hold | `{ pr: {number, title, branch, url}, closedAt }; closed without merging` | `pr.closed:{repo}:{number}:{closedAt}` |
| `pr.conflicted` (#712) | as `pr.closed` | `{ pr: {number, title, branch, url}, conflictedAt }`; a PR open and in conflict now that was not at the last poll. The cursor's ids are the PRs in conflict then; a first poll takes those already in conflict as known; one GitHub has not worked out keeps its state | `pr.conflicted:{repo}:{number}:{conflictedAt}` |

| `issue.opened` (#682) | `repo` (optional), `label` (only issues opened with it), `anyone` | `{ issue: {number, title, author, labels, url}, openedAt }` | `issue.opened:{repo}:{number}` |
| `issue.labelled` | `repo` (optional), `label` (only when it is the label added), `issue` (positive integer), `anyone` | `{ issue, label, by, labelledAt }` | `issue.labelled:{repo}:{eventId}` |
| `issue.commented` | `repo` (optional), `label` (only issues with it), `issue`, `anyone` | `{ issue, comment: {author, url, body}, commentedAt }`; `body` is cut to 4000 characters | `issue.commented:{repo}:{commentId}` |
| `issue.closed` | `repo` (optional), `label` (only issues with it), `issue`, `anyone` | `{ issue, reason: "completed"\|"not_planned", by, closedAt }` | `issue.closed:{repo}:{eventId}` |

All have `delivery: ["poll"]`. Pull requests are never issues here, though GitHub lists them
together. The issue events read `issues` (by created), `issues/comments` and `issues/events`
(GitHub keeps 90 days of those). Every name is `noun.verbed`, and no noun is one the
app reserves, so workflows name them as they are (`checks.failed`), with no prefix. The cursor and paging rules are in
[research R10](../research.md#r10-the-ci-watcher-turning-github-into-events-with-a-cursor).

**Whose doing it is (#728).** On a public repo anyone can open an issue, comment or send a
pull request, and an issue's or comment's body goes into the prompt. So by default an event is
raised only for the repo's own people: GitHub's `author_association` is `OWNER`, `MEMBER` or
`COLLABORATOR`, and the account is not a bot (`type: "Bot"` or a login ending `[bot]`).
That is the issue's author for `issue.opened`, the comment's for `issue.commented`, the PR's
for `checks.failed` (a fork's PR included) and `pr.opened`, and the actor for `issue.labelled` (labelling takes
triage access, so only bots are left out). For `issue.closed` it is the actor, except that an
author outside the repo closing their own issue does not count. `anyone: true` raises them
all. The other `pr.*` events are left as they are: their data is a PR's number, title and branch.

## Tools

| Tool | Input | Result | Annotations | Visibility |
|---|---|---|---|---|
| `list_prs` | `repo` | `{ prs: [{number, title, branch, url, checks: "passing"\|"failing"\|"running"\|"none", failedRunId?, conflicts?: boolean}] }`; `conflicts` is left out while GitHub works it out | `readOnlyHint: true` | `model`, `app`; `_meta.ui.resourceUri: "ui://ci/board"` |
| `list_issues` | `repo`, optional `label` | `{ issues: [{number, title, author, labels, url, comments, updatedAt}] }`, open issues newest updated first, at most 100 | `readOnlyHint: true` | `model`, `app`; `_meta.ui.resourceUri: "ui://ci/issues"` |
| `failed_log` | `repo`, `runId`, optional `job` | The last 300 lines of each failed job's log, as text | `readOnlyHint: true` | `model` |
| `rerun_failed` | `repo`, `runId` | `{ rerun: true, url }` | none: it changes something | `model`, `app` |
| `comment_on_pr` | `repo`, `number`, `body` | `{ url }` | none | `model` |

## Resources

`ui://ci/board`: one HTML page (`text/html;profile=mcp-app`), with no network
(`_meta.ui.csp` empty).
- It draws `list_prs`'s result as a list: number, title, branch, a check pill, and a **Conflicts** pill on a PR that conflicts with its base (#712).
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
