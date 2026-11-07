---
diataxis: how-to
devices: [mac, web]
description: Add the azuredevops connector with a personal access token, so that agents read and comment on pull requests and their Azure Pipelines builds on Azure DevOps Repos or your own Azure DevOps Server, and a workflow or a wait starts on their events.
---

# Use Azure DevOps Repos

Agents talks to Azure DevOps Repos through its own `azuredevops` connector (#2829), an MCP
server in the shape of the gitlab one. It works with Azure DevOps Services
(`dev.azure.com` and the older `*.visualstudio.com` addresses) and with your own Azure DevOps
Server. Agents Host carries it, and every Linux host installs it beside agentsd.

It has tools to read pull requests and their builds, to read a failed build's log, and to
comment, and it has events that start a workflow or a wait. It has no pages yet: the Work
pages do not list an Azure DevOps repository.

Work items (Azure Boards) are not in this connector. They are the tracker's, as Linear's
and Jira's issues are: see [Use Azure Boards work items](use-azure-boards.md).

## Before you start

- An Azure DevOps organization with a project and a Git repository, or your own Azure
  DevOps Server 2022.1 or later.
- A folder whose git remote is on it, such as
  `https://dev.azure.com/acme/Web%20App/_git/app` or
  `git@ssh.dev.azure.com:v3/acme/Web%20App/app`.

## Add the connector

1. In Azure DevOps, open **User settings ▸ Personal access tokens** and make a token for
   your organization with **Code: Read & write** and **Build: Read**.
2. In Agents, open **Settings ▸ Agent Configuration ▸ Connectors** (or a folder's
   **Connectors** page) and choose **Add Connector…**.
3. Choose the **Agents** marketplace, then **Azure DevOps**, and add it.
4. Fill in:
   - `AZURE_DEVOPS_TOKEN`: the token.
   - `AZURE_DEVOPS_URL`: leave it out for Azure DevOps Services. For your own server, give
     the address of its collections, such as `https://server/tfs`.

   The values go in your own `~/.agents-secrets/secrets.env`, never in `mcp.json`.

The connector finds the repository from the folder's git remote (`origin` first). A tool or
an event can name another one with `repo`, as `organization/project/name` (on a server,
`collection/project/name`). A project's name can have spaces: `acme/Web App/app`.

## The tools

- `list_pull_requests`, `get_pull_request` (with its description, head commit, reviewers
  and their votes, and the combined state of its builds), and `get_checks` (the newest build
  of each pipeline of a branch or a pull request, and the statuses other services set on a
  pull request).
- `get_build_log`: a failed build's failed steps, their errors and the end of each log.
- `comment_on_pull_request`: a comment in a new thread.
- For the ready-made workflows: `create_pull_request`, `list_pull_request_comments` (the
  comments on lines of the diff, with each one's `threadId`) and
  `reply_to_pull_request_comment` (an answer in that thread).

Merging and approving are a person's, as on GitHub: `merge_pull_request` (complete, or
auto-complete) and `approve_pull_request` (a vote of approved) are only on the copy the host
runs for your own windows and devices, never offered to an agent.

## The events

The events have the gitlab connector's names, so a workflow made for GitHub or GitLab works
here too:

- `checks.failed`: an active pull request's checks failed at its head commit: a build of the
  pull request, a build of its branch at that commit (a CI trigger), or the newest status that
  another service set on it. `run.id` is the first failed build's id, for `get_build_log`
  (0 when only a status failed).
- `checks.passed`: one of those passed at the head commit, one event per build or status.
- `pr.opened`, `pr.merged` (completed), `pr.closed` (abandoned), `pr.conflicted`.
- `review.requested`: for you, the token's owner: you are a reviewer and have not voted.
- `review.comment`: a comment on a line of a pull request's diff. `comment.threadId` is
  the thread to answer in.

Unless an event's `anyone` is true, a bot (a build service) and a pull request from a fork
never count. Azure DevOps lets only a project's members open a pull request or comment on
one, so every other person counts.

## What to know

- **Comments are read for the 50 newest active pull requests,** and those closed since the
  last poll. Azure DevOps has no list of a repository's comments.
- **Checks are builds and statuses.** Statuses are read for the 50 newest active pull
  requests, the newest of each context, at the pull request's newest push. A build of a branch
  that no active pull request is from (`main`, a tag) raises no event.
- **Not yet:** the Work pages, a **Connect Azure DevOps** sheet with a sign-in, and the
  set-up of a folder's Code review and CI from an Azure DevOps remote.

## See also

- [Use GitLab](use-gitlab.md)
- [Use Forgejo or Gitea](use-forgejo.md)
- [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md)
