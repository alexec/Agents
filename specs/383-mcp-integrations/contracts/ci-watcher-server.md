# Contract: the CI watcher MCP server

> **Removed (#1231).** The `ci` server and `Packages/MCPServers/Sources/CIWatcher` are gone.
> The github MCP server in Go (`Go/cmd/github-mcp`, #1232) raises the same events with the
> same names, filters, data and `eventId`s, and GitHub's official tools take the place of the
> tools below. Its views (the board, the issues view and the PR page) went with it. This
> contract is kept as the record of what the events mean.

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
| `list_issues` | `repo`, optional `label` | `{ issues: [{number, title, author, labels, url, assignees, comments, updatedAt}] }` (`assignees`: logins, #905), open issues newest updated first, at most 100 | `readOnlyHint: true` | `model`, `app`; `_meta.ui.resourceUri: "ui://ci/issues"` |
| `failed_log` | `repo`, `runId`, optional `job` | The last 300 lines of each failed job's log, as text | `readOnlyHint: true` | `model` |
| `rerun_failed` | `repo`, `runId` | `{ rerun: true, url }` | none: it changes something | `model`, `app` |
| `comment_on_pr` | `repo`, `number`, `body` | `{ url }` | none | `model`, `app` (the PR page's **Comment**, #837) |
| `get_pr` (#837) | `repo`, `number`, optional `diff` | `{number, title, branch, base, url, author, state: "open"\|"merged"\|"closed", draft, body, createdAt, additions, deletions, checks, failedRunId?, conflicts?, review?: "approved"\|"changes_requested"\|"review_required", autoMerge, checkRuns: [{name, state: "passing"\|"failing"\|"running"\|"skipped", url}], files: [{path, additions, deletions, patch?}], diffTruncated?, comments: [{author, body, at, url?, review?}], viewer?}`. `viewer` is the signed-in login, left out when gh can't say. `comments` are the PR's comments and its reviews with words or a verdict, oldest first; line comments are not in it. With `diff: true`, each file's hunks are its `patch`, at most 2000 lines in all; a file past that has none, and `diffTruncated` is true | `readOnlyHint: true` | `model`, `app`; `_meta.ui.resourceUri: "ui://ci/pr"` |
| `merge_pr` (#837) | `repo`, `number`, optional `auto` | `{ merged, auto, url }`: `gh pr merge -R repo --squash --delete-branch` (`--auto` with `auto`). `-R` keeps gh off the server's folder, so only the branch on GitHub is deleted | none | `app` only: a person merges, never the model |
| `review_pr` (#837) | `repo`, `number`, `event`: `approve`\|`request_changes`, `body` (needed to request changes) | `{ event, url }`: `gh pr review N -R repo --approve`\|`--request-changes [-b body]`. GitHub refuses either on the signed-in person's own PR | none | `app` only: a person reviews, never the model |
| `list_branches` (#837) | `repo` | `{ base, branches: [{name, updatedAt, headline}] }`: branches pushed in the last 14 days with no open or merged PR, not the base, newest first (one GraphQL query of the newest 100) | `readOnlyHint: true` | `app` |
| `fill_pr` (#837) | `repo`, `branch` | `{ base, title, body, commits }`, as `gh pr create --fill` writes them from the commits ahead of the base: one commit gives its first line and the rest; more give the branch's name and a list of first lines. An error when none are ahead | `readOnlyHint: true` | `app` |
| `create_pr` (#837) | `repo`, `branch`, `title`, optional `body`, `draft` | `{ number, url }`: `gh pr create -R repo --head branch --base <default> --title --body [--draft]` | none | `app` only: a person creates it |

## Resources

`ui://ci/board`: one HTML page (`text/html;profile=mcp-app`), with no network
(`_meta.ui.csp` empty).
- It draws `list_prs`'s result as a list: number, title, branch, a check pill, and a **Conflicts** pill on a PR that conflicts with its base (#712).
- A failing PR has **Rerun**, which calls `rerun_failed` through `tools/call`, and then
  `list_prs` again.
- A PR's title opens its page (below) in the same view, with **‹ Pull requests** back to a
  fresh list (#837).
- Under the PRs, **Branches without a pull request** (`list_branches`, shown only when there
  are some): each branch, its last commit's first line and how long ago, and **Create**.
  Create opens a form in the page's place, filled in by `fill_pr`: a title, a description, and
  **Open it as a draft**. **Create Pull Request** calls `create_pr`, and the new PR's page opens
  (#837).
- Links open through `ui/open-link`.
- Because `list_prs` is read-only and `app`-visible, the view can be pinned with
  `{repo: "alexec/Agents"}`.

`ui://ci/issues` (#682): the same kind of page, drawing `list_issues`'s result.
- A row is number, title, who it is assigned to (`@login`, a green pill: an issue is taken
  by assigning it, #905), author, comment count, how long since it changed, and its labels.
  The header counts the open issues and how many of them are assigned.
- A label calls `list_issues` again with that `label`; the chosen label in the header, with
  ✕, calls it without. A pin's `label` argument starts it narrowed.
- **Start Agent** on a row (#834) asks the app for its new-agent form, filled in
  (`agents/start-agent`, an Agents extension of MCP Apps): the prompt "Work on GitHub issue
  #n (`gh issue view n --repo R`): title", then a line telling the agent to assign the issue
  to itself (`gh issue edit n --repo R --add-assignee @me`); the label `#n`; and a new
  worktree named from "n title". The person starts the agent from the form.

`ui://ci/pr` (#837): one pull request's page, drawing `get_pr`'s result. The board draws the
same page when a title is clicked.
- A header with **GitHub ↗** and **Refresh**; `#n` and the title; pills for the state (merged,
  closed, draft), the checks, **Conflicts**, the review decision and **Auto-merge on**; the
  branch, its base, the author, its age, `+a −d` and the file count.
- Three tabs. **Conversation**: the description and the comments and reviews, as text (never
  HTML). **Files**: one fold a file with its counts; the first time it is opened, `get_pr` is
  called again with `diff: true` and each fold holds its hunks. **Checks**: each check with its
  pill and a link to it, and **Rerun Failed** on a failing PR.
- On an open PR: a text box, **Comment** (`comment_on_pr`), **Ask the Agent to Fix** and
  **Merge**. **Ask the Agent to Fix** sends `agents/message-agent` (`branch`: the PR's, `text`:
  what is to be fixed — the failing checks, changes asked for, a conflict — and the box's words)
  to the session working on the branch; the host asks the person before it is sent, from a chat
  or a pin. When no session works on it (error `-32001`), it sends `agents/start-agent` with the
  same words, the label `P#n` and `branch`, so the new-agent form opens on that branch. A host
  that does not know `agents/message-agent` (`-32601`) gets `ui/message` into its chat. **Merge** asks again in the page,
  "Squash and merge #n into main and delete *branch*?", before `merge_pr`; with checks still
  running it is **Auto-merge** (`auto: true`). It is off in conflict, on a draft, and while
  auto-merge is already on.
- On an open PR whose author is not `viewer`: **Approve** and **Request Changes** (`review_pr`),
  with the box's words as the review's body; Request Changes needs words. On one's own PR they
  are not shown, as GitHub refuses them there.

## Errors

- `gh` missing or not signed in: tools answer `isError: true` with the reason, and
  `events/poll` answers `-32012` with `data.reason: "gh not signed in"`.
- A GitHub rate limit: `-32013` with `retryAfterMs` from GitHub's reset header.
