---
diataxis: how-to
devices: [mac, web]
description: Add the bitbucket connector with an Atlassian API token or an access token, so that agents read and comment on pull requests, checks and issues on Bitbucket Cloud, and a workflow or a wait starts on their events.
---

# Use Bitbucket

Agents talks to Bitbucket Cloud through its own `bitbucket` connector (#2828), an MCP
server in the shape of the gitlab one, on Bitbucket's REST API 2.0. Agents Host carries
it, and every Linux host installs it beside agentsd. It is for Bitbucket Cloud
(bitbucket.org) only, not Bitbucket Data Center.

It has tools to read pull requests, their checks and issues, and to comment on them, and
it has events that start a workflow or a wait. It has no pages yet: the Work pages do not
list a Bitbucket repository.

## Before you start

- A Bitbucket Cloud workspace with a repository.
- A folder whose git remote is on Bitbucket, such as
  `https://bitbucket.org/acme/app.git` or `git@bitbucket.org:acme/app.git`.

## Add the connector

1. Make a token. Use one of these:
   - **An API token with scopes** (Atlassian account ▸ **Security** ▸ **Create API token
     with scopes**, app **Bitbucket**): read and write on repositories, pull requests and
     issues, and read on account, workspace membership and pipelines (for `failed_log`).
     It acts as you.
   - **An access token** of the repository, project or workspace (its **Settings ▸
     Access tokens**), with the same scopes. It acts as its own bot user, so
     `review.requested`, `issue.assigned` and `mine` are that bot's.
2. In Agents, open **Settings ▸ Agent Configuration ▸ Connectors** (or a folder's
   **Connectors** page) and choose **Add Connector…**.
3. Choose the **Agents** marketplace, then **Bitbucket**, and add it.
4. Fill in:
   - `BITBUCKET_TOKEN`: the token.
   - `BITBUCKET_EMAIL`: your Atlassian account's email, for an API token. Leave it out
     for an access token.

   The values go in your own `~/.agents-secrets/secrets.env`, never in `mcp.json`.

The connector finds the repository from the folder's git remote (`origin` first). A tool or
an event can name another one with `repo`, as `workspace/name`.

## The tools

- `list_pull_requests`, `get_pull_request` (with its description, reviewers, head commit and
  the combined state of its checks), `get_checks` (each status of a commit or a pull
  request's head), `list_issues` and `get_issue` (with its comments).
- `failed_log`: the last 300 lines of each failed step's log in a Bitbucket Pipelines run,
  or of one step by name (`step`). Give it `pipelineId`, the run's build number: `run.id`
  in a `checks.failed` event. So the **Fix failed checks** workflow works on Bitbucket too.
  Another CI's logs are on its own pages; `get_checks` gives their addresses.
- `comment_on_pull_request` and `comment_on_issue`.
- For the ready-made workflows: `create_pull_request`, `list_pull_request_comments` (the
  comments on lines of the diff) and `reply_to_pull_request_comment` (an answer in the
  comment's thread).

Merging and approving are a person's, as on GitHub: `merge_pull_request` and
`approve_pull_request` are only on the copy the host runs for your own windows and devices,
never offered to an agent.

Atlassian's own Rovo MCP server has Bitbucket Cloud tools too. You can add it from the
marketplace beside this one; it has no events.

## The events

The events have the gitlab connector's names, so a workflow made for GitHub or GitLab works
here too:

- `checks.failed`: a status of an open pull request's head commit is FAILED. Bitbucket
  Pipelines and any CI that sets a commit status count. `run.id` is the Pipelines build
  number, or 0 for another CI.
- `pr.opened`, `pr.merged`, `pr.closed` (declined), `pr.conflicted` (a file of its diff is
  in conflict).
- `review.requested` and `issue.assigned`: for you, the token's owner.
- `review.comment`: a comment on a line of a pull request's diff.
- `issue.opened`, `issue.labelled`, `issue.commented`, `issue.closed`.

Unless an event's `anyone` is true, only the repository's own people count: people with
write access or more, never an app or a bot. A pull request from a fork never counts. A
token without admin on the repository cannot read another person's access, so it counts
the members of the workspace instead.

## What to know

- **Issues have no labels on Bitbucket.** An issue's kind (bug, enhancement, proposal,
  task) and its component are its labels: `label` filters by them, and `issue.labelled` is
  a kind or a component set to a new value.
- **A repository with its issue tracker off has no issue events.**
- **Checks and conflicts are read for the 50 open pull requests updated last.** Bitbucket
  has no list of a repository's failed checks or conflicts, so each poll reads those.
- **Not yet:** the Work pages, a **Connect Bitbucket** sheet with a sign-in, the set-up of a
  folder's Tasks, Code review and CI from a Bitbucket remote, and a failed step's log.

## See also

- [Use GitLab](use-gitlab.md)
- [Use Forgejo or Gitea](use-forgejo.md)
- [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md)
