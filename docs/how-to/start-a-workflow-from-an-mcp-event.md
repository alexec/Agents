---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Start an agent when an MCP server reports an event, such as a pull request's checks failing, and see on the workflow's page that it is listening.
---

# Start a workflow from an MCP event

An MCP server can offer events as well as tools and views: "a pull request's checks
failed", "a message arrived". A workflow can run on one of them. This guide uses this
project's own CI watcher, a small MCP server that turns GitHub Actions failures into
`checks.failed` events, and the **Fix failed checks** workflow that starts an agent on each
one.

The app asks servers for events in poll mode, following the MCP events draft
(`experimental-ext-triggers-events`). A server that offers events only by push or webhook
is shown as not supported yet.

## Before you start

- A project with an MCP server that offers events. For the CI watcher you need Node 26 and a
  signed-in `gh` (`gh auth status`). See `Integrations/ci-watcher/README.md` in the repo.
- For every setting, see [Workflow triggers and actions](../reference/workflows.md), and for
  what the event carries, [Events from MCP servers](../reference/events.md#events-from-mcp-servers).

## Start the server

Server events come from servers the project can already use: the project's
`.agents/mcp.json`, your own `~/.agents/mcp.json`, or a plugin. The CI watcher is in this
project's `.agents/mcp.json` as `ci`, at `http://127.0.0.1:8795/mcp`.

1. From the project's main folder, not a worktree, start the server:

   ```sh
   Integrations/ci-watcher/run.sh start
   Integrations/ci-watcher/run.sh status
   ```

   It runs as a LaunchAgent, `com.agents.ci-watcher`, and holds no token of its own: every
   GitHub call goes through your `gh`.
2. In the project's **MCP servers** section, `ci` arrived with the project, so it is
   **waiting for your OK**: choose **Approve**. Until you do, it is asked for nothing, and
   the workflow's page says it is waiting for approval. See
   [Add an MCP server from the registry](add-an-mcp-server-from-the-registry.md).

A local (stdio) server works too: the app runs its own copy of it to ask for events, with
the same environment and secrets an agent gets.

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
Use the `ci` server's `failed_log` to read each failed job. If it is a test known to be
flaky under load, use `rerun_failed`. Otherwise fix it on the PR's branch in a worktree,
push, and use `comment_on_pr` to say what you changed.
```

- Without `server:`, the trigger listens to every server here that offers `checks.failed`.
  Add `server: ci` to listen to that one only, or `server: [github, gitlab]` for a list.
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

- **ci · checks.failed: Checked 20 s ago · last event 25 min ago**: it is listening. A new
  subscription starts from now, so events from before it are not run.
- **Can't reach ci since 12:01 · trying again in 40 s**, in orange: the server is down.
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
its events. To stop the CI watcher itself, run `Integrations/ci-watcher/run.sh stop`.

## See also

- [Events](../reference/events.md#events-from-mcp-servers)
- [Workflow triggers and actions](../reference/workflows.md)
- [Set up a workflow](set-up-a-workflow.md)
- [Pin a page to a project](pin-a-page-to-a-project.md): the CI watcher's board, `ui://ci/board`, can be pinned
