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

Both have `delivery: ["poll"]`. Both names are `noun.verbed`, and neither noun is one the
app reserves, so workflows name them as they are (`checks.failed`), with no prefix. The cursor and paging rules are in
[research R10](../research.md#r10-the-ci-watcher-turning-github-into-events-with-a-cursor).

## Tools

| Tool | Input | Result | Annotations | Visibility |
|---|---|---|---|---|
| `list_prs` | `repo` | `{ prs: [{number, title, branch, url, checks: "passing"\|"failing"\|"running"\|"none", failedRunId?}] }` | `readOnlyHint: true` | `model`, `app`; `_meta.ui.resourceUri: "ui://ci/board"` |
| `failed_log` | `repo`, `runId`, optional `job` | The last 300 lines of each failed job's log, as text | `readOnlyHint: true` | `model` |
| `rerun_failed` | `repo`, `runId` | `{ rerun: true, url }` | none: it changes something | `model`, `app` |
| `comment_on_pr` | `repo`, `number`, `body` | `{ url }` | none | `model` |

## Resource

`ui://ci/board`: one HTML page (`text/html;profile=mcp-app`), with no network
(`_meta.ui.csp` empty).
- It draws `list_prs`'s result as a list: number, title, branch, and a check pill.
- A failing PR has **Rerun**, which calls `rerun_failed` through `tools/call`, and then
  `list_prs` again.
- Links open through `ui/open-link`.
- Because `list_prs` is read-only and `app`-visible, the view can be pinned with
  `{repo: "alexec/Agents"}`.

## Errors

- `gh` missing or not signed in: tools answer `isError: true` with the reason, and
  `events/poll` answers `-32012` with `data.reason: "gh not signed in"`.
- A GitHub rate limit: `-32013` with `retryAfterMs` from GitHub's reset header.
