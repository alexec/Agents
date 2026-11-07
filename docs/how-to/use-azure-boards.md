---
diataxis: how-to
devices: [mac, web]
description: Add the azureboards connector with a personal access token, so that agents read and comment on Azure Boards work items, and a workflow or a wait starts when one is opened, tagged, commented on, closed or assigned to you.
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

## What to know

- **Events are polled once a minute,** from the 50 work items changed last since the poll
  before. A poll that finds more says it is `truncated`.
- **Closed is by category,** read from the project's work item types, so a process of your
  own with other state names works.
- **Not yet:** the Work pages, the Tasks slot of a folder's set-up, a project's board, and a
  **Connect Azure DevOps** sheet with a sign-in.

## See also

- [Use Azure DevOps Repos](use-azure-devops.md)
- [Use Jira issues](use-jira-issues.md)
- [Use Linear issues](use-linear-issues.md)
