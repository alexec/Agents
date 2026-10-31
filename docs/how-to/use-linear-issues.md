---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Connect Linear, see a folder's open Linear issues on a page with Start Agent, give its agents Linear's tools, and start an agent when a Linear issue is opened, labelled, commented on or closed.
---

# Use Linear issues

Two connectors (MCP servers) work together:

- **Tools** come from Linear's own MCP server, `https://mcp.linear.app/mcp`. Agents use it
  to find, read and change issues.
- **The Linear issues page and the events** come from `linear-mcp`, a small server that
  Agents ships. Its tools feed the **Linear issues** page: the open issues, narrowed by team,
  state or label, with **Start Agent** on each. Click a row to expand its rich-text description.
  Its events are
  `issue.opened`, `issue.labelled`, `issue.commented` and `issue.closed`. A workflow or a
  wait can use them. See
  [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).

Agents Host carries `linear-mcp`, and every Linux host installs it beside agentsd.

## Before you start

- A Linear workspace that you can sign in to.

## Connect Linear

On **Connectors**, choose **Connect… ▸ Linear** on the Mac (**Connect Linear…** on the
Remote and the web page), then **Continue on linear.app**. Approve on linear.app; Agents comes
back by itself. The host keeps the tokens and renews them. `linear-mcp` reads this connection,
so it needs no key.

You can use a personal API key in place of the connection: in Linear, go to **Settings ▸
Security & access ▸ Personal API keys**, make a key with the **Read** permission, and set
`LINEAR_API_KEY` for the server (below). The key, when it is set, goes first.

## Add Linear's tools

Add Linear's own server from the registry, or by hand with the URL
`https://mcp.linear.app/mcp`. It signs in with OAuth in your browser. See
[Add a connector from the registry](add-a-connector-from-the-registry.md) and
[Sign in to a connector](sign-in-to-a-connector.md).

## Add the page and the events

1. Add **Linear** from the **Agents** marketplace in the catalogue, or by hand in the folder's
   `.agents/mcp.json`:

   ```json
   { "mcpServers": { "linear": { "command": "linear-mcp", "hosted": true } } }
   ```

   With a personal API key, put the key in your own `~/.agents-secrets/secrets.env`
   (`LINEAR_API_KEY=lin_api_…`), not in the folder, and name it in the entry:
   `"env": { "LINEAR_API_KEY": "${LINEAR_API_KEY}" }`.

2. In **Folder Settings ▸ Agent Configuration ▸ Connectors**, choose **Approve** on
   `linear`. See [Add a connector by hand](add-a-connector-by-hand.md).

3. To keep the page in the sidebar, pin it in the folder's `.agents/pins.json`:

   ```json
   { "pins": [ { "pinned_by": { "person": true }, "title": "Linear issues",
       "view": { "server": "linear", "tool": "show_issues", "uri": "ui://linear/issues",
                 "arguments": { "team": "ENG" } } } ] }
   ```

   Or pin the page from the app, as any other page.

**Start Agent** opens the new-agent form for the issue. The prompt tells the agent to put
the issue's identifier (such as `ENG-12`) in its branch and pull request title, so that
Linear's GitHub integration links the pull request to the issue.

## Work a Linear issue with an agent

A folder that pushes to GitHub lists the ready-made workflow **Work a Linear issue**, off.
Turn it on in the folder's Workflows. Then, when a Linear issue gets the `agent` label, a
new agent reads it with Linear's server, takes it, works on a branch `agent/eng-12`, opens a
pull request whose title starts with `ENG-12`, and comments on the issue with the link. With
Linear's GitHub integration on, the pull request shows on the issue, and `Fixes ENG-12` in its
body closes the issue when it merges. The agent never merges.

The GitHub **Work an issue** workflow takes only the `github` server's `issue.labelled`, so
one label starts one agent.

## Start an agent on an event

Each event takes these arguments. All of them are optional:

| Argument | What it does |
|----------|--------------|
| `team` | Only issues of this team, by its key, such as `ENG`. |
| `label` | Only issues with this label. For `issue.labelled`, only when this label is added. |
| `issue` | Only this issue, such as `ENG-12`. Not for `issue.opened`. |
| `anyone` | `true` also counts guests, apps and integrations. Without it, only the workspace's members count. |

For example, a workflow that starts an agent for each new bug in the `ENG` team:

```markdown
---
name: Look at new bugs
on:
  - issue.opened:
      server: linear
      team: ENG
      label: Bug
agent: new
---

Read the issue in the event's data with Linear's tools, and find where the bug is.
```

Give `server: linear`: a github server offers events with the same names.

The server asks Linear once a minute. A personal key or a connection can make 1500 requests an hour, and
each wait costs one request a minute.

## When it does not work

- **A label or a close made just after an issue was created is not an event.** Linear keeps
  no history of the changes in an issue's first few minutes, and labels and closes are read
  from that history. `issue.opened` has the issue's labels as they are when it is seen.

- **"Linear is not signed in"**: there is no Linear connection on the host, and
  `LINEAR_API_KEY` is not set for the server. Connect Linear on Connectors.
- **"Linear refused the key"**: the connection or the key was revoked. Connect Linear
  again, or make a new key.
- **"Linear's rate limit is reached"**: too many waits use the one key. The server waits as
  long as Linear says.
