---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: See a folder's open Jira issues on a page with Start Agent, give its agents Atlassian's tools, and start an agent when a Jira issue is opened, labelled, commented on or assigned to you.
---

# Use Jira issues

Two connectors (MCP servers) work together:

- **Tools** come from Atlassian's own MCP server, `https://mcp.atlassian.com/v1/mcp`. Agents
  use it to find, read and change issues.
- **The Jira issues page and the events** come from `jira-mcp`, a small server that Agents
  ships. Its tools feed the **Jira issues** page: the open issues, narrowed by project, status
  or label, with **Start Agent** on each. Click a row to expand its description and its
  Lineage section. Its events are `issue.opened`, `issue.labelled`, `issue.commented` and
  `issue.assigned`. A workflow or a wait can use them. See
  [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).

Agents Host carries `jira-mcp`, and every Linux host installs it beside agentsd. It works with
Jira Cloud and with Jira Data Center.

## Before you start

- A Jira site that you can sign in to, such as `https://example.atlassian.net`.
- On Jira Cloud, an API token: go to **id.atlassian.com ▸ Security ▸ API tokens** and choose
  **Create API token**.
- On Jira Data Center, a personal access token: go to your profile ▸ **Personal Access
  Tokens** and choose **Create token**.

## Add Atlassian's tools

Add Atlassian's own server from the registry, or by hand with the URL
`https://mcp.atlassian.com/v1/mcp`. It signs in with OAuth in your browser. See
[Add a connector from the registry](add-a-connector-from-the-registry.md) and
[Sign in to a connector](sign-in-to-a-connector.md).

## Add the page and the events

1. Add **Jira** from the **Agents** marketplace in the catalogue. It asks for three secrets,
   which it keeps in your own `~/.agents-secrets/secrets.env`, not in the folder:

   | Secret | What it is |
   |--------|------------|
   | `JIRA_URL` | The site, such as `https://example.atlassian.net` |
   | `JIRA_EMAIL` | The email you sign in to Jira Cloud with |
   | `JIRA_API_TOKEN` | The API token |

   Or add it by hand in the folder's `.agents/mcp.json`:

   ```json
   { "mcpServers": { "jira": { "command": "jira-mcp", "hosted": true,
       "env": { "JIRA_URL": "${JIRA_URL}", "JIRA_EMAIL": "${JIRA_EMAIL}", "JIRA_API_TOKEN": "${JIRA_API_TOKEN}" } } } }
   ```

   **On Jira Data Center**, put the personal access token in `JIRA_API_TOKEN` and remove the
   `JIRA_EMAIL` line from the entry. With no email, the server sends the token as a bearer
   token.

2. In **Folder Settings ▸ Agent Configuration ▸ Connectors**, choose **Approve** on `jira`.
   See [Add a connector by hand](add-a-connector-by-hand.md).

3. To keep the page in the sidebar, pin it in the folder's `.agents/pins.json`:

   ```json
   { "pins": [ { "pinned_by": { "person": true }, "title": "Jira issues",
       "view": { "server": "jira", "tool": "show_issues", "uri": "ui://jira/issues",
                 "arguments": { "project": "PROJ" } } } ] }
   ```

   Or pin the page from the app, as any other page. The sidebar row shows how many issues are
   assigned to you.

**Start Agent** opens the new-agent form for the issue. The prompt tells the agent to put the
issue's key (such as `PROJ-12`) in its branch and pull request title, so that Jira's
development panel links the pull request to the issue.

## Work a Jira issue with an agent

A folder that pushes to GitHub lists the ready-made workflow **Work a Jira issue**, off. Turn
it on in the folder's Workflows. Then, when a Jira issue gets the `agent` label, a new agent
reads it with Atlassian's server, takes it, works on a branch `agent/PROJ-12`, opens a pull
request whose title starts with `PROJ-12`, and comments on the issue with the link. With the
GitHub for Jira app on the site, the pull request shows on the issue. The agent never merges.

The GitHub **Work an issue** workflow takes only the `github` and `gitlab` servers'
`issue.labelled`, so one label starts one agent.

## Start an agent on an event

Each event takes these arguments. All of them are optional:

| Argument | What it does |
|----------|--------------|
| `project` | Only issues of this project, by its key, such as `PROJ`. |
| `label` | Only issues with this label. For `issue.labelled`, only when this label is added. |
| `issue` | Only this issue, such as `PROJ-12`. Not for `issue.opened`. |
| `anyone` | `true` also counts customers and apps. Without it, only the site's own users count. Not for `issue.assigned`, which counts anyone. |

For example, a workflow that starts an agent for each new bug in the `PROJ` project:

```markdown
---
name: Look at new bugs
on:
  - issue.opened:
      server: jira
      project: PROJ
      label: bug
agent: new
---

Read the issue in the event's data with Atlassian's tools, and find where the bug is.
```

Give `server: jira`: the github, gitlab and linear servers offer events with the same names.

The server asks Jira once a minute. Jira's webhooks would need a Jira admin, so it polls.

## When it does not work

- **"Jira is not signed in"**: `JIRA_URL` or `JIRA_API_TOKEN` is not set for the server. Add
  them as secrets (above).
- **"Jira refused the token"**: the token was revoked, or `JIRA_EMAIL` is not the token's
  account. Make a new token. On Data Center, check that the entry has no `JIRA_EMAIL`.
- **"Jira's rate limit is reached"**: too many waits use the one token. The server waits as
  long as Jira says.
- **"… does not exist for the field 'project'"**: the `project` key is wrong, or the token's
  account cannot see that project.
