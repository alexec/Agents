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
- To connect with a token: on Jira Cloud, an API token (**id.atlassian.com ▸ Security ▸ API
  tokens ▸ Create API token**); on Jira Data Center, a personal access token (your profile ▸
  **Personal Access Tokens ▸ Create token**).

## Connect Jira

Connect Jira once, for every folder on the machine. The one Atlassian connection serves
Confluence too (the Docs slot). On the Mac, open a folder's **Connectors** page and choose
**Jira…** in the Tasks slot, or **Connectors ▸ Connect… ▸ Jira and Confluence**. On the web
page, choose **Connect Jira…** in the Tasks slot or on **Settings ▸ You ▸ Connectors**.

- **Atlassian Cloud** signs in on atlassian.com, where you choose the site. The machine keeps
  the token and renews it. Atlassian has no public apps, so the machine needs the Agents app's
  client ID and secret from the Atlassian developer console, in your
  `~/.agents-secrets/secrets.env` as `ATLASSIAN_CLIENT_ID` and `ATLASSIAN_CLIENT_SECRET`. The
  app has the callback `https://oauth.agentloops.dev/oauth/callback` and these scopes:
  `read:jira-work`, `read:jira-user`, `read:confluence-content.all`,
  `read:confluence-space.summary`, `search:confluence`, `read:me` and `offline_access`. Without
  them, the sheet says to connect with an API token.
- **API token** takes the site, the email (Jira Cloud only) and the token. The machine checks
  them with the site. On Data Center, leave the email empty: the token goes as a bearer token.

Either way, the sheet ends on the site's newest issue, the one real read that proves the
connection. **Connectors ▸ Connections** shows it, with **Disconnect**. The tokens stay on the
machine, never in a log.

## Add Atlassian's tools

Add Atlassian's own server from the registry, or by hand with the URL
`https://mcp.atlassian.com/v1/mcp`. It signs in with OAuth in your browser. See
[Add a connector from the registry](add-a-connector-from-the-registry.md) and
[Sign in to a connector](sign-in-to-a-connector.md).

## Add the page and the events

1. Add **Jira** from the **Agents** marketplace in the catalogue. It asks for no secret: it
   reads your Atlassian connection (above). Or add it by hand in the folder's
   `.agents/mcp.json`:

   ```json
   { "mcpServers": { "jira": { "command": "jira-mcp", "hosted": true } } }
   ```

   **Without the connection**, give the server a token by hand. It goes before the connection.
   Keep the values in `~/.agents-secrets/secrets.env`, and name them in the entry:

   ```json
   { "mcpServers": { "jira": { "command": "jira-mcp", "hosted": true,
       "env": { "JIRA_URL": "${JIRA_URL}", "JIRA_EMAIL": "${JIRA_EMAIL}", "JIRA_API_TOKEN": "${JIRA_API_TOKEN}" } } } }
   ```

   `JIRA_URL` is the site, `JIRA_EMAIL` the email you sign in to Jira Cloud with, and
   `JIRA_API_TOKEN` the API token. **On Jira Data Center**, put the personal access token in
   `JIRA_API_TOKEN` and remove the `JIRA_EMAIL` line.

2. In **Project Settings ▸ Agent Configuration ▸ Connectors**, choose **Approve** on `jira`.
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

- **"Jira is not signed in"**: there is no Atlassian connection, and `JIRA_URL` or
  `JIRA_API_TOKEN` is not set for the server. Connect Jira (above).
- **"This machine has no Agents app on Atlassian"**: `ATLASSIAN_CLIENT_ID` and
  `ATLASSIAN_CLIENT_SECRET` are not in the machine's secrets. Connect with an API token.
- **"Jira refused the token"**: the token was revoked, or `JIRA_EMAIL` is not the token's
  account. Make a new token. On Data Center, check that the entry has no `JIRA_EMAIL`.
- **"Jira's rate limit is reached"**: too many waits use the one token. The server waits as
  long as Jira says.
- **"… does not exist for the field 'project'"**: the `project` key is wrong, or the token's
  account cannot see that project.
