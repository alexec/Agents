---
diataxis: how-to
devices: [mac, web]
description: Add the forgejo connector with an access token, so that agents read and comment on pull requests, checks and issues on Codeberg or your own Forgejo or Gitea, and a workflow or a wait starts on their events.
---

# Use Forgejo or Gitea

Agents talks to Forgejo and Gitea through its own `forgejo` connector (#1753), an MCP
server in the shape of the gitlab one. Forgejo and Gitea have the same REST API, so one
connector is for both: Codeberg, your own Forgejo, or your own Gitea. Agents Host carries
it, and every Linux host installs it beside agentsd.

It has tools to read pull requests, their checks and issues, and a failed job's log, and to
comment on them, and it has events that start a workflow or a wait. It has no pages yet: the Work pages do not
list a Forgejo repository.

## Before you start

- An account on Codeberg, or on your own Forgejo or Gitea.
- A folder whose git remote is on that Forgejo, such as `https://codeberg.org/acme/app.git`
  or `git@codeberg.org:acme/app.git`.

## Add the connector

1. On your Forgejo, open **Settings ▸ Applications** and make an access token with
   **Read and write** on **repository** and **issue**, and **Read** on **user** and
   **organization**.
2. In Agents, open **Settings ▸ Agent Configuration ▸ Connectors** (or a folder's
   **Connectors** page) and choose **Add Connector…**.
3. Choose the **Agents** marketplace, then **Forgejo**, and add it.
4. Fill in:
   - `FORGEJO_TOKEN`: the token.
   - `FORGEJO_URL`: leave it out for Codeberg. For your own Forgejo or Gitea, give its
     address, such as `https://git.example.com`.

   The values go in your own `~/.agents-secrets/secrets.env`, never in `mcp.json`.

The connector finds the repository from the folder's git remote (`origin` first). A tool or
an event can name another one with `repo`, as `owner/name`.

## The tools

- `list_pull_requests`, `get_pull_request` (with its description, head commit and the
  combined state of its checks), `get_checks` (each check of a commit or a pull request's
  head), `list_issues` and `get_issue` (with its comments).
- `comment_on_pull_request` and `comment_on_issue`.
- `failed_log`: the last 300 lines of each failed job's log in a Forgejo Actions run, or of
  one job by name. `runId` is the run's number: `run.id` in a `checks.failed` event, or the
  number after `/actions/runs/` in a check's address. On Forgejo 17 or later it gives the
  step that failed (the whole job's log when that step wrote nothing). It needs Forgejo 16
  or later, or Gitea 1.25 or later; an older server, such as Forgejo 11 LTS or Gitea 1.24,
  has no API for it, and the tool says which version it needs and gives the run's address.
  Another CI's logs are on its own pages.
- For the ready-made workflows: `create_pull_request` (a draft's title starts `WIP:`),
  `list_pull_request_comments` (the comments on lines of the diff) and
  `reply_to_pull_request_comment` (an answer in the comment's thread).

Merging and approving are a person's, as on GitHub: `merge_pull_request` and
`approve_pull_request` are only on the copy the host runs for your own windows and devices,
never offered to an agent.

## The events

The events have the gitlab connector's names, so a workflow made for GitHub or GitLab works
here too:

- `checks.failed`: an open pull request's head commit failed its checks. Forgejo Actions,
  Woodpecker and any CI that sets a commit status count. `run.id` is the Forgejo Actions
  run, or 0 for another CI.
- `pr.opened`, `pr.merged`, `pr.closed`, `pr.conflicted`: a draft is a pull request whose
  title starts `WIP:` or `[WIP]`.
- `review.requested` and `issue.assigned`: for you, the token's owner.
- `review.comment`: a comment on a line of a pull request's diff.
- `issue.opened`, `issue.labelled`, `issue.commented`, `issue.closed`.

Unless an event's `anyone` is true, only the repository's own people count: its owner, its
collaborators with write access or more, and the members of the organisation that owns it,
never a bot. A pull request from a fork never counts.

## What to know

- **A conflict takes a minute.** Forgejo says a pull request "cannot merge" while it checks
  it too, so `pr.conflicted` waits until it has said so for a minute at the same commit.
  After the host starts again, a conflict that was already there is raised once more.
- **Checks are read for the 50 open pull requests updated last.** Forgejo has no list of a
  repository's failed checks, so each poll reads the head of each of those.
- **Not yet:** the Work pages, a **Connect Forgejo** sheet with a sign-in, the set-up of a
  folder's Tasks, Code review and CI from a Forgejo remote.

## See also

- [Use GitLab](use-gitlab.md)
- [Use GitHub](use-github.md)
- [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md)
