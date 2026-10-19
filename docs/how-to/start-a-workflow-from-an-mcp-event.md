---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Start an agent when a connector reports an event, such as a pull request's checks failing, and see on the workflow's page that it is listening.
---

# Start a workflow from an MCP event

A connector (an MCP server) can offer events as well as tools and views: "a pull request's checks
failed", "a message arrived". A workflow can run on one of them. This guide uses this
project's `github` server, GitHub's official MCP server with events added (it turns
GitHub Actions failures into `checks.failed` events, among others), and the **Fix failed checks** workflow that starts an agent on each
one.

The app asks servers for events in poll mode, following the MCP events draft
(`experimental-ext-triggers-events`). A server that offers events only by push or webhook
is shown as not supported yet.

## Before you start

- A project with a connector that offers events. The github server (`github-mcp`) ships
  with Agents Host and the Linux host, and needs a signed-in `gh` (`gh auth status`) on the
  host. See `Go/README.md` in the repo.
- For every setting, see [Workflow triggers and actions](../reference/workflows.md), and for
  what the event carries, [Events from MCP servers](../reference/events.md#events-from-mcp-servers).

## Start the server

Server events come from servers the project can already use: the project's
`.agents/mcp.json`, your own `~/.agents/mcp.json`, or a plugin. The github server is in
this project's `.agents/mcp.json` as `github`, a local server the app hosts:

```json
{ "mcpServers": { "github": { "command": "github-mcp", "hosted": true } } }
```

1. In **Project Settings ▸ Agent Configuration ▸ Connectors**, `github` arrived with the project, so it is
   **waiting for your OK**: choose **Approve**. Until you do, it is asked for nothing, and
   the workflow's page says it is waiting for approval. See
   [Add a connector from the registry](add-an-mcp-server-from-the-registry.md).
2. There is nothing to start. The app runs one copy of it on the host, the first time a
   workflow or an agent asks it something, and every agent shares that copy. It holds no
   token of its own: it asks your `gh` for one (`gh auth token`). See
   [Share one copy of a local connector](share-one-copy-of-a-local-mcp-server.md).

A local server without `"hosted": true` works too: the app runs its own copy of it to ask
for events, with the same environment and secrets an agent gets, and each agent runs
another for its tools.

## Write the workflow

A server's event is named the way the app's own are, `noun.verbed`, with no prefix. Under
the name, the keys are the event's own filters, sent to the server:

```markdown
---
name: Fix failed checks
on:
  - checks.failed:
      repo: alexec/Agents
agent: new
cooldown: 5m
labels: [ci]
---

A pull request's checks failed. The event's data says which PR, branch and jobs.
Use the `github` server's `get_job_logs` (with `run_id` and `failed_only: true`) to read
each failed job. If it is a test known to be flaky under load, use `actions_run_trigger`
with `method: rerun_failed_jobs`. Otherwise fix it on the PR's branch in a worktree, push,
and use `add_issue_comment` on the PR to say what you changed.
```

- Without `server:`, the trigger listens to every server here that offers `checks.failed`.
  Add `server: github` to listen to that one only, or `server: [github, gitlab]` for a list.
- The `github` server's `checks.failed`, `pr.merged`, `pr.closed` (closed without merging) and
  `pr.conflicted` (began to conflict with its base, #712) all take `repo`, `branch` (only that PR branch) and `pr` (only that pull request, by
  number). Left out, `repo` is the one the project's folder pushes to (#702). Given
  together, each must hold: `{pr: 551}` hears only PR 551's failures and merge.
- Its `pr.opened` (#833) is raised when a pull request opens, or when a draft is marked
  ready for review. It takes the same filters and `anyone`. Drafts never raise it. The
  **Review pull requests** workflow in `.agents/workflows/` starts an agent on it that
  reads the diff and leaves one comment.
- Every PR event and the issue events are raised only for the repo's owner, members and
  collaborators, never a bot (#728). A PR event is raised only for a PR from a branch of the
  repo itself, not a fork. `anyone: true` raises them for everyone.
- Its issue events, `issue.opened`, `issue.labelled`, `issue.commented` and `issue.closed`,
  take `repo` (optional, as above) and `label`; all but `issue.opened` also take `issue`, by number.
  On `issue.labelled`, `label` is the label added: `{repo: alexec/Agents, label: bug}` hears
  each issue as it is marked a bug.
- A filter the server's event doesn't take, or a value of the wrong type, shows on the
  workflow's page as an error, naming the filters it does take.
- This project's copy of the workflow arrives with `enabled: false`. Turn it on with its
  **Enabled** switch, and approve it.

Each event starts the workflow once, after its prompt. The agent is told the event's
details and, in a fenced block, the server's data, marked as coming from the server and
not from you. The workflow's prompt and permission mode decide what the agent may do with
it.

## Check it is listening

Open the workflow's page, on the Mac, the iPhone or iPad, or the web page. Under
**Triggers**, a line for each server the trigger listens to says how it is doing:

- **github · checks.failed: Checked 20 s ago · last event 25 min ago**: it is listening. A new
  subscription starts from now, so events from before it are not run.
- **Can't reach github since 12:01 · trying again in 40 s**, in orange: the server is down.
  The app tries again, waiting longer each time up to 5 minutes, and the line comes back by
  itself once the server answers.
- A line in red says why it stopped: the server no longer offers the event, refused it, or
  doesn't take its filters. It is asked again once the file or the server's events change.
- **Events may have been missed since 09:14**: the app was away longer than the server keeps
  events. Events it did get still run. **Clear** takes the line away.

Each event is also on the **Events** page, under the name `checks.failed`, with the run it
started.

## Turn it off

Turn the workflow off with its **Enabled** switch, and the app stops asking the server for
its events. The github server itself stops once nothing uses it: no agent's session has it open
and no workflow listens for its events.

## See also

- [Events](../reference/events.md#events-from-mcp-servers)
- [Workflow triggers and actions](../reference/workflows.md)
- [Set up a workflow](set-up-a-workflow.md)
