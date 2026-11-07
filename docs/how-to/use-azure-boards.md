---
diataxis: how-to
devices: [mac, web]
description: Add the azureboards connector with a personal access token, so that agents read and comment on Azure Boards work items, a workflow or a wait starts when one is opened, tagged, commented on, closed or assigned to you, and the Work pages list and change them.
---

# Use Azure Boards work items

Agents talks to Azure Boards through its own `azureboards` connector (#3804), an MCP server
in the shape of the jira and linear ones: Azure Boards is a tracker. It works with Azure
DevOps Services (`dev.azure.com`) and with your own Azure DevOps Server. Agents Host carries
it, and every Linux host installs it beside agentsd.

It is a connector of its own, not part of the azuredevops one, so you can use Azure Boards
with a repository on GitHub, or Azure DevOps Repos with Jira. Pull requests and builds are
the [azuredevops connector](use-azure-devops.md)'s.

A work item is an issue to Agents: its tags are the issue's labels, and its id is the
issue's key.

## Before you start

- An Azure DevOps organization with a project, or your own Azure DevOps Server 2022.1 or
  later.

## Add the connector

1. In Azure DevOps, open **User settings ▸ Personal access tokens** and make a token for
   your organization with **Work Items: Read & write**. If you use the azuredevops connector
   too, add Work Items to its token: the two connectors share `AZURE_DEVOPS_TOKEN`.
2. In Agents, open **Settings ▸ Agent Configuration ▸ Connectors** (or a folder's
   **Connectors** page) and choose **Add Connector…**.
3. Choose the **Agents** marketplace, then **Azure Boards**, and add it.
4. Fill in:
   - `AZURE_DEVOPS_TOKEN`: the token.
   - `AZURE_DEVOPS_URL`: leave it out for Azure DevOps Services. For your own server, give
     the address of its collections, such as `https://server/tfs`.
   - `AZURE_BOARDS_PROJECT`: the project, as `organization/project` (on a server,
     `collection/project`), such as `acme/Web App`. Leave it out when the folder's git
     remote is on Azure DevOps Repos: the connector then uses that remote's project.

   The values go in your own `~/.agents-secrets/secrets.env`, never in `mcp.json`.

## The tools

- `list_work_items`: the project's work items, changed last first, at most 50. Open ones
  by default (`state` is `open`, `closed` or `all`); `label` (a tag), `type` (as `Bug`),
  `area` (an area path and those under it) and `mine` (assigned to you) narrow it.
- `get_work_item`: one work item, with its description and its newest 50 comments.
- `comment_on_work_item`: a comment, in Markdown.

A work item's state and its assignee are a person's to change, in Azure Boards.

## The events

The events have the jira and linear connectors' names, so a workflow made for an issue
tracker works here too:

- `issue.opened`: a work item was created.
- `issue.labelled`: a tag was added to a work item, one event per tag.
- `issue.commented`: a comment was left on a work item.
- `issue.closed`: a work item moved to a state of the Completed or Removed category (as
  Closed, Done or Removed). A Resolved state is not closed.
- `issue.assigned`: a work item was assigned to you, the token's owner, by anyone.

Each takes `area`, `type` and `label`; all but `issue.opened` take `issue` (a work item's
id). Unless `anyone` is true, a bot (a build service, a service account or a group) never
counts.

## On the Work pages

Work ▸ Issues lists the work items of the projects a folder names (#3815), beside its GitHub,
GitLab, Linear and Jira issues. Name them in the folder's `.agents/folder.json`:

```json
{ "azureBoardsProjects": ["acme/Web App"] }
```

Each project is `organization/project` (on a server, `collection/project`). The Work pages
use the connector's `AZURE_DEVOPS_TOKEN` and `AZURE_DEVOPS_URL`.

- **A row** says the work item's state (as Active), in the colour of open or closed, and its
  tags. **Azure Boards · acme/web app** is a choice in the Repo filter.
- **A work item's page** shows its description and its comments as Markdown, Open on Azure
  Boards, Start Agent, Labels (its tags), a comment box, and a state menu in place of Close
  and Reopen: the other states of its type.
- **Its plan** is its children (its Child links), each in the step after its predecessors
  (its Predecessor links). Add child makes a new work item of the level's type (User Story,
  Product Backlog Item, Requirement or Issue for a story or a spike; Task; Bug), or moves
  one that is there (give `12`, `AB#12` or its page) under it. Blocked by adds or takes off
  a predecessor in the same organization.
- **Lineage:** Start Agent labels the session `AB#12`. A session labelled `AB#12`, and a pull
  request whose title or branch says `AB#12` (as Azure Boards itself links them), count
  towards the work item of the folder's first project.

Every write is your own click, made with your token: no approval card.

## What to know

- **Events are polled once a minute,** from the 50 work items changed last since the poll
  before. A poll that finds more says it is `truncated`.
- **Closed is by category,** read from the project's work item types, so a process of your
  own with other state names works.
- **Not yet:** the Tasks slot of a folder's set-up, a project's board, a view of the
  connector's own, and a **Connect Azure DevOps** sheet with a sign-in.

## See also

- [Use Azure DevOps Repos](use-azure-devops.md)
- [Use Jira issues](use-jira-issues.md)
- [Use Linear issues](use-linear-issues.md)
