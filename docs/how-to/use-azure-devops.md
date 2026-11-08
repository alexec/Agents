---
diataxis: how-to
devices: [mac, web]
description: Add the azuredevops connector with a personal access token, so that agents read and comment on pull requests and their Azure Pipelines builds on Azure DevOps Repos or your own Azure DevOps Server, a workflow or a wait starts on their events, the Work pages list the pull requests, and the connector's own pages show them.
---

# Use Azure DevOps Repos

Agents talks to Azure DevOps Repos through its own `azuredevops` connector (#2829), an MCP
server in the shape of the gitlab one. It works with Azure DevOps Services
(`dev.azure.com` and the older `*.visualstudio.com` addresses) and with your own Azure DevOps
Server. Agents Host carries it, and every Linux host installs it beside agentsd.

It has tools to read pull requests and their builds, to read a failed build's log, and to
comment, and it has events that start a workflow or a wait. With the Azure DevOps connection
(#3802), the Work pages list and act on the pull requests (#3803). It also has two pages of
its own (#4098): **Pull requests** and a pull request's page. The Mac window, the Remote on
iPhone and iPad, and the web page show the same pages.

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
   your organization with **Code: Read & write** and **Build: Read**. To run a build's
   failed jobs again (`retry_build`, **Retry**), give it **Build: Read & execute**.
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
- `retry_build`: a finished build's failed jobs run again, in the same build.
- For the pages: `show_pull_requests`, `show_pull_request` and `show_pull_request_diff`.
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
- `run.completed`: a build of any trigger finished, whatever its result, as the github
  connector's: for a build no pull request owns, such as `main`'s or a tag's release, or one
  started by hand. `pipeline` (its name), `branch` (a branch or tag, as `main` or `v0.16.0`)
  and `run` (a build's id) narrow it. `run.conclusion` is Azure DevOps's result
  (`succeeded`, `failed`, `canceled`, `partiallySucceeded`); a build run again is a new event.
- `pr.opened`, `pr.merged` (completed), `pr.closed` (abandoned), `pr.conflicted`.
- `review.requested`: for you, the token's owner: you are a reviewer and have not voted.
- `review.comment`: a comment on a line of a pull request's diff. `comment.threadId` is
  the thread to answer in.

Unless an event's `anyone` is true, a bot (a build service) and a pull request from a fork
never count. Azure DevOps lets only a project's members open a pull request or comment on
one, so every other person counts.

## See pull requests on the connector's pages

An agent shows a page when it calls the tool that feeds it. Ask, for example, "Show the open
pull requests on Azure DevOps".

**Pull requests** (`show_pull_requests`) lists the 50 newest active pull requests. Each one
has its checks (its builds and other services' statuses), a conflict, its review and
**Auto-complete** when that is on. A pull request whose build failed has **Retry**. Click a
title to open its page in the same view.

The list is in sections: **Needs you** (you are a reviewer who has not voted, or your own pull
request has failed checks, a conflict, or a reviewer who rejected it or waits for you),
**Yours**, **Team** and **Others**. With a control plane, **Team** is its people and bots, by
their Azure DevOps login (see
[Your Azure DevOps login](use-azure-boards.md#your-azure-devops-login)), and a row shows the
name the control plane knows; the rest are **Others**. Without one,
everyone else in the organization is **Team**, as an organization has only its own members.

A folder's own repository is on the Work pages, so its sidebar has no row for this list. To
keep the page, choose **Pin to Folder** in the view's menu. See
[Pin a page to a folder](pin-a-page-to-a-folder.md).

### Work on a pull request

A pull request's page has five tabs: **Conversation**, **Line comments**, **Files**,
**Checks** and **Lineage**.

- **Files**: each file and how it changed. Azure DevOps says no counts of lines here.
  **Show Diff**, or a file's name, shows the changed lines in the app's own diff.
- **Checks**: the newest build of each pipeline and the newest status of each other service.
  A failed build has **Show Log**, the end of its failed steps' logs (`get_build_log`), and
  **Retry Failed Jobs** runs them again (`retry_build`). Another service's status opens on
  its own page.
- **Lineage**: the sessions on the pull request, with what they cost (#3952).

Under the tabs is a box for your words, and these buttons. Each one acts on Azure DevOps as
you:

- **Comment** adds the box's words as a comment, in a thread of its own.
- **Approve** shows only on someone else's pull request: a vote of *approved*.
- **Merge** completes it into the target branch (squashes it, when the branch's *Limit merge
  types* policy allows squash and not a merge) and deletes the branch. It asks you again
  first. A draft, or a pull request in conflict, can't be merged.
- **Auto-merge** shows while its checks run: Azure DevOps's *auto-complete*, which completes
  it once its policies pass.
- **Ask an Agent** sends the work to the agent on the branch: failed checks, a conflict or
  open line comments, with the box's words. The app asks you before it sends. With no agent
  on that branch, the new-agent form opens on the branch.

Agents can't merge or approve from this page. Those tools are for a person only. They carry
the commit that the page shows. When the pull request has a newer commit, nothing happens:
open the page again.

## On the Work pages

With Azure DevOps connected, **Work ▸ Pull requests** lists the pull requests of each folder
whose remote is on Azure DevOps (`dev.azure.com`, `*.visualstudio.com`, or the connected Azure
DevOps Server), beside the other forges', the last opened or closed first. The repository,
`organization/project/repo`, is a choice in the **Repo** filter. Without a token for that Azure
DevOps (the connection, or the connector's `AZURE_DEVOPS_TOKEN` and `AZURE_DEVOPS_URL`), the
list says Azure DevOps is not connected. **Work ▸ Issues** lists Azure Boards work items, not
this connector's: see [Use Azure Boards work items](use-azure-boards.md).

A pull request's page has its description and comments, its checks (the newest Azure
Pipelines build of each pipeline of the pull request, and the newest status of each other
service), **Open on Azure DevOps**, and:

- **Merge:** merge, squash or rebase, as the target branch's *Limit merge types* policy
  allows them (all three with no policy), and **Merge when checks pass**, which is Azure
  DevOps's *auto-complete*. Either deletes the branch.
- **Approve:** a vote of *approved*, at the head commit the page shows.
- **Rerun failed:** each failed Azure Pipelines build runs its failed jobs again. A check's
  log is the end of its build's failed steps. Another service's status runs again on its
  own page.
- **Show Diff:** each file's changes against the merge base with the target. Azure DevOps
  says which lines changed, and the page reads the lines of both commits, so a diff of more
  than 100 files lists the rest with no lines.
- **Labels:** the pull request's tags. Azure DevOps has no list of a repository's tags, so
  the menu offers the tags of its 100 newest pull requests.
- **Close:** abandons the pull request; **Reopen** makes it active again.
- A comment box: a comment is a thread of its own.

## What to know

- **The Pull requests page reads each pull request's builds and statuses.** Azure DevOps
  has no list of many pull requests' builds, so the page reads four pull requests at a time.
- **Comments are read for the 50 newest active pull requests,** and those closed since the
  last poll. Azure DevOps has no list of a repository's comments.
- **Checks are builds and statuses.** Statuses are read for the 50 newest active pull
  requests, the newest of each context, at the pull request's newest push. A build of a branch
  that no active pull request is from (`main`, a tag) raises no event.
- **The Work pages read Azure DevOps on each machine.** The list asks each repository, a
  state at a time, as Azure DevOps has no list across repositories; it filters a tag and
  words itself, as Azure DevOps cannot. A pull request has no time of its last change, so
  the list is in the order each was opened or closed. An assignee lists none: a pull
  request has reviewers, not assignees.
- **The Work pages read one Azure DevOps on a machine:** the first folder's, with a token
  for it. A folder on another lists nothing, and says so when none is read.
- **Lineage links Azure Repos pull requests (#3952).** A session's `P#12` label in a folder
  on Azure DevOps works on pull request 12, and its `#12` label on work item 12 of the
  repository's project on Azure Boards, as Azure DevOps reads `#12` in a description. A pull
  request's events link it to the sessions on its branch and to the work items its
  description closes, and a failed Azure Pipelines build builds it
  (`azuredevops:<org>/<project>/<repo>/builds/<id>`). An Azure Boards work item's Lineage
  section lists the pull requests that fix it.
- **Lineage asks Azure DevOps** with the Azure DevOps connection or `AZURE_DEVOPS_TOKEN`,
  about the repositories of the folders on it: a pull request's title, state (an abandoned
  one is closed) and tags, a version tag's pull requests (from `Merged PR 12:` at the start
  of a merge or squash commit's title, or else the pull request whose merge commit it is),
  and the cost comment on a merged pull request (when the folder's `prCostComment` says so),
  in a closed thread of its own, so a policy that wants comments resolved is not held by it.
  Azure Repos has no milestones. A doc's address is `?path=/<path>`, on the default branch.
- **On an Azure DevOps Server,** a pull request's address names its collection two parts
  before `_git`; a repository named as its project, under a path such as `/tfs/`, is not
  linked from its address.
- **Not yet:** a Microsoft Entra sign-in (a personal access token only).

## See also

- [Use GitLab](use-gitlab.md)
- [Use Forgejo or Gitea](use-forgejo.md)
- [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md)
