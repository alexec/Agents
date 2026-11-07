---
diataxis: how-to
devices: [mac, web]
description: Connect Forgejo with an access token and add the forgejo connector, so that agents read and comment on pull requests, checks and issues on Codeberg or your own Forgejo or Gitea, a workflow or a wait starts on their events, the Work pages list them, and the connector's own pages show them.
---

# Use Forgejo or Gitea

Agents talks to Forgejo and Gitea through its own `forgejo` connector (#1753), an MCP
server in the shape of the gitlab one. Forgejo and Gitea have the same REST API, so one
connector is for both: Codeberg, your own Forgejo, or your own Gitea. Agents Host carries
it, and every Linux host installs it beside agentsd.

It has tools to read pull requests, their checks and issues, and a failed job's log, and to
comment on them, and it has events that start a workflow or a wait. With the Forgejo
connection, the Work pages list a Forgejo repository's issues and pull requests too (#3753).
It also has three pages of its own (#3838): **Pull requests**, **Issues** and a pull
request's page. The Mac window, the Remote on iPhone and iPad, and the web page show the same
pages.

## Before you start

- An account on Codeberg, or on your own Forgejo or Gitea.
- A folder whose git remote is on that Forgejo, such as `https://codeberg.org/acme/app.git`
  or `git@codeberg.org:acme/app.git`.

## Connect Forgejo

Forgejo has no sign-in page for Agents, so you connect it with an access token (#3752).

1. On your Forgejo, open **Settings ▸ Applications** and make an access token with
   **Read and write** on **repository** and **issue**, and **Read** on **user** and
   **organization**.
2. In Agents, open **Your setup ▸ Connectors** and choose **Connect… ▸ Forgejo** (on the web
   page, **Connect Forgejo…** on Connections). Or, on a folder whose remote is on a Forgejo,
   choose **Connect Forgejo…** on its Connectors page.
3. Fill in the **Forgejo address**: leave it empty for Codeberg, or give your own Forgejo's
   or Gitea's, such as `https://git.example.com`. **Make a Token on Forgejo** opens that
   Forgejo's Applications page.
4. Paste the **Access token** and choose **Connect**. The machine checks the token with that
   Forgejo and keeps it in its own store (the Keychain on a Mac), never in a log.

The connection's row on Connectors says the Forgejo's host and **Access token**. A Forgejo
token does not end; **Disconnect** deletes the machine's copy. To revoke it too, delete it on
Forgejo, in **Settings ▸ Applications**.

The token counts only on the Forgejo it was made on. A folder on another Forgejo waits for a
connection there.

## Set up a folder from its remote

A folder whose git remote is on Codeberg, on the connected Forgejo, or on a host with
`forgejo`, `gitea` or `codeberg` in its name gets its set-up from the Forgejo connection, as a
GitHub or GitLab folder does. A GitHub remote comes first, then a GitLab remote. The slots:

- **Tasks: Forgejo issues**, proved by the newest issue.
- **Code review: Forgejo pull requests**, proved by the newest pull request.
- **CI: Forgejo checks**, proved by the combined status of the default branch's head.

When a read is refused, **Open on** the Forgejo's host opens the repository, where you ask for
access. Once a slot has read, the set-up adds the forgejo connector to the folder, with its
events, once.

## Add the connector by hand

The set-up adds it for you. To add it to another folder:

1. In Agents, open **Settings ▸ Agent Configuration ▸ Connectors** (or a folder's
   **Connectors** page) and choose **Add Connector…**.
2. Choose the **Agents** marketplace, then **Forgejo**, and add it.
3. It asks for nothing: it reads the Forgejo connection. Without a connection, name your
   token by hand in the entry's `env` in `.agents/mcp.json`: `"FORGEJO_TOKEN":
   "${FORGEJO_TOKEN}"` (and `"FORGEJO_URL": "${FORGEJO_URL}"` for your own Forgejo or Gitea),
   with the values in your own `~/.agents-secrets/secrets.env`, never in `mcp.json`.
   `FORGEJO_TOKEN`, when it is set, is used before the connection.

The connector finds the repository from the folder's git remote (`origin` first). A tool or
an event can name another one with `repo`, as `owner/name`.

## On the Work pages

With Forgejo connected, **Work ▸ Issues** and **Work ▸ Pull requests** list the issues and pull
requests of each folder whose remote is on the connected Forgejo, beside the other forges',
the last updated first. The repository is a choice in the **Repo** filter. A folder on another
Forgejo is left out, and the list says why: the token counts only on its own Forgejo.

- **An issue's page:** its description and comments, **Open on Forgejo**, **Start Agent**
  (the session is labelled `#12`), **Close** or **Reopen**, **Labels** (the repository's) and a
  comment box.
- **A pull request's page:** the same, and its checks (the head commit's statuses), **Merge**
  (the repository's default method first; merge, squash or rebase, as the repository allows;
  and *Merge when checks pass*), **Approve** and **Show Diff**. Forgejo's API cannot run a
  check again or give its log, so **Rerun failed** and a check's log say to open the check on
  Forgejo.

Each write is yours, with your token, from the machine that read the item.

## See pull requests and issues on the connector's pages

An agent shows a page when it calls the tool that feeds it. Ask, for example, "Show the open
pull requests on Forgejo".

- **Pull requests** (`show_pull_requests`): the 50 newest open pull requests, each with its
  head commit's checks, a conflict and its review. Click a title to open its page in the same
  view.
- **Issues** (`show_issues`): the 50 newest open issues, each with its labels, its assignees
  and its comment count. Click a row to expand its rich-text description. Click a label to
  show only those issues. **Start Agent** opens the new-agent form for the issue, with its
  number as the label and a new worktree. Nothing starts until you press Start.

Each list is in sections: **Needs you** (asked to review it, assigned to you, or your own pull
request with failed checks, a conflict or changes requested), **Yours**, **Team** (the
repository's collaborators with write access or more, and bots) and **Others**.

A folder's own repository is on the Work pages, so its sidebar has no row for these lists. A
project whose Tasks or Code review slot names another Forgejo repository gets a row for that
repository. To keep a page, choose **Pin to Folder** in the view's menu. See
[Pin a page to a folder](pin-a-page-to-a-folder.md).

### Work on a pull request

A pull request's page has five tabs: **Conversation**, **Line comments**, **Files**,
**Checks** and **Lineage**.

- **Files**: **Show Diff**, or a file's name, shows the changed lines in the app's own diff.
- **Checks**: the head commit's statuses. A failed Forgejo Actions run has **Show Log**, the
  end of its failed jobs' logs (`failed_log`: Forgejo 16 or Gitea 1.25 or later). Another
  CI's check opens on its own page.

Under the tabs is a box for your words, and these buttons. Each one acts on Forgejo as you:

- **Comment** adds the box's words as a comment.
- **Approve** shows only on someone else's pull request.
- **Merge** merges into the target branch (or squashes, when the repository's default is
  squash) and deletes the branch. **Auto-merge** shows while the checks run: Forgejo merges
  it once they succeed. Each one asks you again first. A draft, or a pull request in
  conflict, can't be merged.
- **Ask an Agent** sends the work to the agent on the branch: failed checks, a conflict or
  open line comments, with the box's words. The app asks you before it sends. With no agent
  on that branch, the new-agent form opens on the branch.

Agents can't merge or approve from this page. Those tools are for a person only. They carry
the commit that the page shows. When the pull request has a newer commit, nothing happens:
open the page again.

### An epic's plan and features

Forgejo has no sub-issues, so an epic's children are the issues it **depends on** (Forgejo's
issue dependencies, *This issue depends on*), and a child waits for the issues it depends on
in turn. An issue labelled `epic` has a **Plan** on its page, its children step by step, as on
GitHub. **Add child** makes the epic depend on a new issue (with its level and the epic's
`feature:<name>` label) or on one that is there (`#12`, `owner/repo#12` or its address on the
connected Forgejo); **Blocked by** makes a child depend on another child, or no longer.
Forgejo keeps an issue with open dependencies from being closed, so an epic closes after its
children.

**Work ▸ Features** counts a Forgejo epic under its `feature:<name>` label, as it counts the
other forges' epics.

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
- For the pages: `show_pull_requests`, `show_issues`, `show_issue_details`,
  `show_pull_request` and `show_pull_request_diff`.
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
- **The Work pages read Forgejo on each machine.** The list asks each repository for a page,
  as Forgejo has no list across chosen repositories.
- **The Pull requests page reads each pull request's checks and reviews.** Forgejo has no list
  of many commits' statuses, so the page reads four pull requests at a time.
- **Lineage links Forgejo's issues and pull requests (#3834).** A session's `#12` or `P#12`
  label in a folder on Forgejo works on that issue or pull request. A pull request's events
  link it to the sessions on its branch and to the issues its description closes. A folder
  is on Forgejo when its `origin` is on the connected Forgejo, or on a host whose name says
  Codeberg, Forgejo or Gitea.
- **Lineage asks the connected Forgejo (#3844),** with the Forgejo connection, about the
  repositories of the folders on it: an issue's, a pull request's and a milestone's title
  and state, an issue's milestone, a version tag's pull requests (from `(#12)` at the end of
  a squash commit's title, or else the commit's pull request) and the milestone whose title
  starts with its version, and the cost comment on a merged pull request (when the folder's
  `prCostComment` says so). Forgejo has no parent issues, so an issue has none. An issue's
  address on the connected Forgejo is read in a filed issue's output. A doc's address is
  `/src/HEAD/<path>`, which Forgejo sends on to the default branch.
- **The forgejo server's pages have a Lineage section (#3850).** An issue's row and a pull
  request's Lineage tab name the sessions that worked on it, its pull requests or issues, and
  what they cost, as on GitHub and GitLab, also for a Forgejo whose host's name does not say
  Forgejo.
- **An issue filed with `tea` or `fj` is linked (#3850).** A session that runs
  `tea issues create` (Gitea's CLI) or `fj issue create` (Forgejo's) opens the issue it
  made. `tea` prints the issue's address. `fj` prints only `created issue #12`, so the issue
  is on the repository its `--repo` names, or else on the folder's Forgejo repository.
- **The Board filter has no Forgejo board.** Forgejo has project boards, but its API (11)
  cannot read them, so a list narrowed to a board lists no Forgejo items.
- **Not yet:** Retry on the pages (#3842).

## See also

- [Use GitLab](use-gitlab.md)
- [Use GitHub](use-github.md)
- [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md)
