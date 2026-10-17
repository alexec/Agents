---
diataxis: how-to
devices: [mac]
description: Give a project's agents the Linear workspace's issues, and start an agent when an issue is opened, labelled, commented on or closed.
---

# Use Linear issues

Agents ship a small `linear` MCP server, `linear-mcp`. It gives agents three read-only
tools and four events from your Linear workspace:

- **Tools:** `list_issues`, `get_issue` (with its description and comments) and
  `list_teams`. They only read. To change an issue, use Linear, or Linear's own MCP server.
- **Events:** `issue.opened`, `issue.labelled`, `issue.commented` and `issue.closed`. A
  workflow or a wait can use them. See
  [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).

Agents Host carries `linear-mcp`, and every Linux host installs it beside agentsd.

## Before you start

- A Linear workspace that you can sign in to.
- A personal API key. In Linear, go to **Settings ▸ Security & access ▸ Personal API keys**
  and make a key. The key reads what you can read.

## Add the server

1. Put the key in your own `~/.agents-secrets/secrets.env`, not in the project:

   ```sh
   LINEAR_API_KEY=lin_api_…
   ```

2. Add the server to the project's `.agents/mcp.json`. The entry names the secret, not its
   value:

   ```json
   { "mcpServers": { "linear": { "command": "linear-mcp", "hosted": true,
       "env": { "LINEAR_API_KEY": "${LINEAR_API_KEY}" } } } }
   ```

3. In **Project Settings ▸ Agent Configuration ▸ MCP servers**, choose **Approve** on
   `linear`. See [Add an MCP server by hand](add-an-mcp-server-by-hand.md).

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

Read the issue in the event's data with get_issue, and find where the bug is.
```

Give `server: linear`: a github server offers events with the same names.

The server asks Linear once a minute. A personal key can make 1500 requests an hour, and
each wait costs one request a minute.

## When it does not work

- **"Linear is not signed in"**: `LINEAR_API_KEY` is not set for the server. Check
  `secrets.env` and the `env` of the entry.
- **"Linear refused LINEAR_API_KEY"**: the key was revoked. Make a new key.
- **"Linear's rate limit is reached"**: too many waits use the one key. The server waits as
  long as Linear says.
