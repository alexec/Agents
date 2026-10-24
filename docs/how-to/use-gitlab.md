---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Connect GitLab with the gitlab.com sign-in or an access token, set up a folder's Tasks, Code review and CI from it, and work with merge requests, issues and pipelines on their pages.
---

# Use GitLab

Agents talks to GitLab through its own `gitlab` connector (an MCP server). It works with
gitlab.com and with a self-managed GitLab. It has tools to read merge requests, pipelines
and issues and to comment on them, events such as `checks.failed`, and three pages:
**Merge requests**, **Issues** and a merge request's page. It uses GitLab's REST API, not
GitLab's own MCP server, and not `glab`.

The Mac window, the Remote on iPhone and iPad, and the web page show the same connection,
the same set-up and the same pages, because the host keeps the state.

## Before you start

- A GitLab account, on gitlab.com or on your own GitLab.
- A folder whose folder has a GitLab remote.

## Connect GitLab

You connect once, and the connection is for every folder on that host. There are two
ways in. The sheet has a picker for them, **gitlab.com** and **Access token**.

Open the sheet from a folder's **Connectors** page with **Connect GitLab…**, or from
**Connectors** (under Activity in the sidebar). On the Mac, choose
**Connect… ▸ GitLab** there. On the Remote and the web page, choose **Connect GitLab…**.

### On gitlab.com: sign in

Use this way on gitlab.com. You make no token, and the host renews the sign-in by itself.

1. Choose **gitlab.com**, then **Continue on gitlab.com**.
2. The sheet shows a code and copies it. Your browser opens GitLab's device page. Type the
   code there, then authorize.
3. The sheet closes by itself when GitLab says yes. If the browser closed, choose
   **Open gitlab.com Again**.

GitLab asks for the `api` scope. Connectors then says "OAuth · renews by itself".

### On any GitLab: an access token

Use this way for a self-managed GitLab, or for gitlab.com without the sign-in.

1. Choose **Access token**.
2. In **GitLab address**, type your GitLab's address, such as `https://gitlab.com`.
3. Choose **Make a Token on GitLab**. GitLab's token page opens with the name `Agents` and
   the `api` scope filled in. Make the token.
4. Paste it in **Access token**, and choose **Connect**. The host checks the token with
   GitLab before it keeps it.

The row on Connectors says the GitLab's host and the token's last day, such as
"Access token · ends 18 Oct 2027". When the token ends, the row says "The access token
ended: connect again with a new one". **Connect Again…** opens the sheet on **Access
token**, with the address filled in.

### Where the token is kept

The host keeps the token, never a log or an answer to a client. The `gitlab` connector
sends it only to the GitLab where you made the connection, so a token for one GitLab never
goes to another.

**Disconnect** on **Connectors ▸ Connections** deletes the host's token. Before it
does, it says which folders lose which slots. To revoke the token on GitLab too, go to
GitLab ▸ Preferences ▸ Applications or Access tokens.

## Set up a folder's tools

A folder's **Connectors** page starts with its set-up, as for GitHub. The folder's git
remote picks the forge. A GitHub remote picks GitHub. With no GitHub remote, a GitLab remote
picks GitLab: one on the GitLab you connected, on gitlab.com, or on a host named `gitlab`.

The GitLab connection fills three slots. Each gets its tick only from one real read, so you
know that it works:

- **Tasks** (GitLab issues) reads the newest issue.
- **Code review** (GitLab merge requests) reads the newest merge request.
- **CI** (GitLab pipelines) reads the last pipeline.

**Skip**, **Set Up**, **Change…** and **Try Again** work as they do for GitHub. When GitLab
refuses a read, the slot says why, such as "GitLab refused: Agents can't see pipelines in
group/app.", and **Open on ‹your GitLab›** opens the folder on GitLab, where you can ask
for access.

When the first slot has read, the page adds the `gitlab` connector to the folder's
`.agents/mcp.json`, approved, once. Its events then reach the folder.

To add it by hand, add **GitLab** from the **Agents** marketplace in the catalogue on the Mac, or
write the entry:

```json
{ "mcpServers": { "gitlab": { "command": "gitlab-mcp", "hosted": true } } }
```

It reads the GitLab connection. Instead, you can set `GITLAB_TOKEN` (an access token with
the `api` scope) and `GITLAB_URL` (your GitLab) in the entry's `env`. When `GITLAB_TOKEN`
is set, it goes first. Keep the token in your own `~/.agents-secrets/secrets.env` and name
it in the entry as `${GITLAB_TOKEN}`, so that it is never in the folder.

## See merge requests, issues and pipelines

An agent shows a page when it calls the tool that feeds it. Ask, for example, "Show the
open merge requests".

- **Merge requests** (`show_merge_requests`): each open merge request with its head
  commit's pipeline, a conflict, the approvals it needs, and auto-merge. A failed pipeline
  has **Retry**, which runs its failed jobs again. Click a title to open its page in the
  same view.
- **Issues** (`show_issues`): each open issue with its labels, its assignees and its
  comment count. Click a row to expand its rich-text description. Click a label to show only
  those issues. **Start Agent** opens the new-agent form for the issue, with its number as the
  label and a new worktree. Nothing starts until you press Start.

To keep a page, choose **Pin to Folder** in the view's menu. See
[Pin a page to a folder](pin-a-page-to-a-folder.md).

## Work on a merge request

A merge request's page has four tabs: **Conversation**, **Discussions on lines**, **Files**
and **Pipeline**.

- **Files**: **Show Diff**, or a file's name, shows the changed lines in the app's own diff.
- **Pipeline**: its jobs. A failed job shows the end of its log. **Retry Failed Jobs** runs
  the failed jobs again.

Under the tabs is a box for your words, and these buttons. Each one acts on GitLab as you:

- **Comment** adds the box's words as a comment.
- **Approve** shows only on someone else's merge request, because an author's own approval
  seldom counts.
- **Merge** merges into the target branch (or squashes, when the merge request says so)
  and deletes the branch. **Auto-merge** shows while the pipeline runs: GitLab merges it
  once the pipeline succeeds. Each one asks you again first. A draft, or a merge request in
  conflict, can't be merged.
- **Ask an Agent** sends the work to the agent on the branch: a failed pipeline, a conflict
  or open discussions, with the box's words. The app asks you before it sends. With no
  agent on that branch, the new-agent form opens on the branch.

Agents can't merge or approve from this page. Those tools are for a view only, so a person
does them. They carry the commit that the page shows. When the merge request has a newer
commit, nothing happens: open the page again.

## Let agents work the dev loop

A folder that pushes to GitLab lists the same three ready-made workflows as GitHub, off,
on its **Workflows** page. One workflow serves both forges, and its agent uses the tools of
the server that the event came from. Open one and turn on its **Enabled** switch.

- **Work an issue** starts when an issue gets the `agent` label. The agent opens a merge
  request with `create_merge_request`.
- **Fix failed checks** starts when a merge request's pipeline fails.
- **Address review comments** starts on `review.comment`, when a line of a merge request
  gets a comment. GitLab has no event for a whole review, so a 10-minute cooldown gathers
  a reviewer's comments into one run.

On GitLab, a merge request is `pr` in an event's data, and its number is its iid (`!12`).
See [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).

## See also

- [Use GitHub](use-github.md)
- [Views in a conversation](../explanation/views.md)
- [Events](../reference/events.md#events-from-mcp-servers)
- [Connector levels](../explanation/connector-levels.md)
