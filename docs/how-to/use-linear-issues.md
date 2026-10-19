---
diataxis: how-to
devices: [mac]
description: Give a project's agents Linear's tools, and start an agent when a Linear issue is opened, labelled, commented on or closed.
---

# Use Linear issues

Two connectors (MCP servers) work together:

- **Tools** come from Linear's own MCP server, `https://mcp.linear.app/mcp`. Agents use it
  to find, read and change issues.
- **Events** come from `linear-mcp`, a small server that Agents ships: `issue.opened`,
  `issue.labelled`, `issue.commented` and `issue.closed`. A workflow or a wait can use them.
  See [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).
  `linear-mcp` has no tools.

Agents Host carries `linear-mcp`, and every Linux host installs it beside agentsd.

## Before you start

- A Linear workspace that you can sign in to.
- For the events, a personal API key. In Linear, go to **Settings ▸ Security & access ▸
  Personal API keys** and make a key with the **Read** permission.

## Add Linear's tools

Add Linear's own server from the registry, or by hand with the URL
`https://mcp.linear.app/mcp`. It signs in with OAuth in your browser. See
[Add a connector from the registry](add-an-mcp-server-from-the-registry.md) and
[Sign in to a connector](sign-in-to-an-mcp-server.md).

## Add the events

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

3. In **Project Settings ▸ Agent Configuration ▸ Connectors**, choose **Approve** on
   `linear`. See [Add a connector by hand](add-an-mcp-server-by-hand.md).

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

The server asks Linear once a minute. A personal key can make 1500 requests an hour, and
each wait costs one request a minute.

## When it does not work

- **A label or a close made just after an issue was created is not an event.** Linear keeps
  no history of the changes in an issue's first few minutes, and labels and closes are read
  from that history. `issue.opened` has the issue's labels as they are when it is seen.

- **"Linear is not signed in"**: `LINEAR_API_KEY` is not set for the server. Check
  `secrets.env` and the `env` of the entry.
- **"Linear refused LINEAR_API_KEY"**: the key was revoked. Make a new key.
- **"Linear's rate limit is reached"**: too many waits use the one key. The server waits as
  long as Linear says.
