---
diataxis: how-to
devices: [mac, web]
description: Connect Bitbucket with an Atlassian API token or an access token and add the bitbucket connector, so that agents read and comment on pull requests, checks and issues on Bitbucket Cloud, a workflow or a wait starts on their events, and the Work pages list them.
---

# Use Bitbucket

Agents talks to Bitbucket Cloud through its own `bitbucket` connector (#2828), an MCP
server in the shape of the gitlab one, on Bitbucket's REST API 2.0. Agents Host carries
it, and every Linux host installs it beside agentsd. It is for Bitbucket Cloud
(bitbucket.org) only, not Bitbucket Data Center.

It has tools to read pull requests, their checks and issues, and to comment on them, and
it has events that start a workflow or a wait. With the Bitbucket connection, the Work pages
list a Bitbucket repository's issues and pull requests too (#3786).

## Before you start

- A Bitbucket Cloud workspace with a repository.
- A folder whose git remote is on Bitbucket, such as
  `https://bitbucket.org/acme/app.git` or `git@bitbucket.org:acme/app.git`.

## Connect Bitbucket

Bitbucket has no sign-in page for Agents, so you connect it with a token (#3785).

1. Make a token. Use one of these:
   - **An API token with scopes** (Atlassian account ▸ **Security** ▸ **Create API token
     with scopes**, app **Bitbucket**): read and write on repositories, pull requests and
     issues, read on account and workspace membership, and read and write on pipelines
     (for `failed_log` and `retry_pipeline`).
     It acts as you.
   - **An access token** of the repository, project or workspace (its **Settings ▸
     Access tokens**), with the same scopes. It acts as its own bot user, so
     `review.requested`, `issue.assigned` and `mine` are that bot's.
2. In Agents, open **Your setup ▸ Connectors** and choose **Connect… ▸ Bitbucket** (on the
   web page, **Connect Bitbucket…** on Connections). Or, on a folder whose remote is on
   bitbucket.org, choose **Connect Bitbucket…** on its Connectors page.
3. For an API token, give its **Atlassian email**. For an access token, leave it empty.
   **Make an API Token on Atlassian** opens the page where you make one.
4. Paste the **Token** and choose **Connect**. The machine checks it with Bitbucket (it reads
   the token's account) and keeps it in its own store (the Keychain on a Mac), never in a log.

The connection's row on Connectors says **bitbucket.org · Token**. **Disconnect** deletes the
machine's copy. To revoke the token too, delete it at id.atlassian.com ▸ **Security ▸ API
tokens**, or in the repository's **Access tokens**. An API token ends on the date you gave it;
then the connector says to connect again.

## Set up a folder from its remote

A folder whose git remote is on bitbucket.org gets its set-up from the Bitbucket connection,
as a GitHub, GitLab or Forgejo folder does. A GitHub remote comes first, then a GitLab one,
then Bitbucket, then Forgejo. The slots:

- **Tasks: Bitbucket issues**, proved by the newest issue. A repository with its issue
  tracker off says so: turn it on in its **Repository settings**, or choose another tracker.
- **Code review: Bitbucket pull requests**, proved by the newest pull request.
- **CI: Bitbucket checks**, proved by the statuses of the main branch's head: Pipelines or
  any CI that sets a commit status.

When a read is refused, **Open on bitbucket.org** opens the repository, where you ask for
access. Once a slot has read, the set-up adds the bitbucket connector to the folder, with
its events, once.

## Add the connector by hand

The set-up adds it for you. To add it to another folder:

1. In Agents, open **Settings ▸ Agent Configuration ▸ Connectors** (or a folder's
   **Connectors** page) and choose **Add Connector…**.
2. Choose the **Agents** marketplace, then **Bitbucket**, and add it.
3. It asks for nothing: it reads the Bitbucket connection. Without a connection, name your
   token by hand in the entry's `env` in `.agents/mcp.json`: `"BITBUCKET_TOKEN":
   "${BITBUCKET_TOKEN}"` (and `"BITBUCKET_EMAIL": "${BITBUCKET_EMAIL}"` for an API token),
   with the values in your own `~/.agents-secrets/secrets.env`, never in `mcp.json`.
   `BITBUCKET_TOKEN`, when it is set, is used before the connection.

The connector finds the repository from the folder's git remote (`origin` first). A tool or
an event can name another one with `repo`, as `workspace/name`.

## On the Work pages

With Bitbucket connected, **Work ▸ Issues** and **Work ▸ Pull requests** list the issues and
pull requests of each folder whose remote is on bitbucket.org, beside the other forges', the
last updated first. The repository is a choice in the **Repo** filter. Without the
connection, the list says Bitbucket is not connected.

- **An issue's page:** its description and comments, **Open on Bitbucket**, **Start Agent**
  (the session is labelled `#12`), **Close** (Bitbucket's *resolved*) or **Reopen**,
  **Labels** and a comment box. An issue's labels are its kind and its component: a kind
  added changes its kind, another label is its component. A kind cannot be taken off, only
  changed.
- **A pull request's page:** its description and comments, its checks (the head commit's
  statuses), **Merge** (the target branch's default first; merge, squash or rebase, as the
  branch allows), **Approve**, **Show Diff**, **Close** (decline) and a comment box. A pull
  request has no labels. **Rerun failed** starts each failed Pipelines run again, every step,
  and a check's log is the end of its failed steps' logs; another CI's checks run again and
  show their logs on their own pages.
- **Not on Bitbucket:** *Merge when checks pass* (its API has none) and **Reopen** of a
  declined pull request (Bitbucket cannot reopen one).

Each write is yours, with your token, from the machine that read the item.

## The tools

- `list_pull_requests`, `get_pull_request` (with its description, reviewers, head commit and
  the combined state of its checks), `get_checks` (each status of a commit or a pull
  request's head), `list_issues` and `get_issue` (with its comments).
- `failed_log`: the last 300 lines of each failed step's log in a Bitbucket Pipelines run,
  or of one step by name (`step`). Give it `pipelineId`, the run's build number: `run.id`
  in a `checks.failed` event. So the **Fix failed checks** workflow works on Bitbucket too.
  Another CI's logs are on its own pages; `get_checks` gives their addresses.
- `retry_pipeline`: a new run of a Pipelines run that has ended (`pipelineId`), the same
  pipeline on the same commit, with the same variables. Pipelines cannot run only the
  failed steps again, so every step runs. It refuses a run that has not ended, and one with
  a secured variable, whose value Bitbucket does not give back: run that one from its page.
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
- **The Work pages read Bitbucket on each machine.** The list asks each repository for a
  page, as Bitbucket has no list across repositories. A label or an assignee lists no pull
  requests: they have neither.
- **Not yet:** an epic's plan, the Board filter, and lineage links from a session's `#12`
  label to a Bitbucket issue.

## See also

- [Use GitLab](use-gitlab.md)
- [Use Forgejo or Gitea](use-forgejo.md)
- [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md)
