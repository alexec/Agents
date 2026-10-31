---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Connect GitHub once, set up a folder's Tasks, Code review and CI from it, see its pull requests and issues on pages, act on a pull request, start an agent on an issue, and work with CodeRabbit.
---

# Use GitHub

Agents talks to GitHub through its own `github` connector (an MCP server). The connector
has the tools of GitHub's official MCP server, events such as `checks.failed`, and three
pages: **Pull requests**, **Issues** and a pull request's page. It does not use `gh`. It
reads GitHub as you, with one connection that the host keeps.

The Mac window, the Remote on iPhone and iPad, and the web page show the same connection,
the same set-up and the same pages, because the host keeps the state.

## Before you start

- A GitHub account.
- A folder whose folder has a GitHub remote. The set-up reads the repository from the git
  remote.

## Connect GitHub

You connect once, and the connection is for every folder on that host. Agents uses the
GitHub App `agents-loops`. You choose on github.com which repositories it can see.

1. Open the connection sheet:
   - On a folder's **Connectors** page (the **Connectors** row under the folder in the
     sidebar), choose **Connect GitHub…**.
   - Or open **Connectors** (under Activity in the sidebar; on the Mac also
     **View ▸ Connectors**). On the Mac, choose **Connect… ▸ GitHub**. On the Remote
     and the web page, choose **Connect GitHub…**.
2. The sheet lists what Agents will be able to do: read and write issues, pull requests
   and reviews, read checks and Actions runs, and read and push code. Choose
   **Continue on github.com**.
3. The sheet shows a code and copies it. Your browser opens github.com/login/device. Type
   the code there, then approve.
4. The sheet closes by itself when GitHub says yes. If the browser closed, choose
   **Open github.com Again**.

If the Agents app is not installed on the folder's repository, the sheet stays open. It
says "The Agents app is not installed on ‹repository›, so agents can't write there."
Choose **Install on github.com**, pick the repository, and come back.

The host keeps the token: on a Mac in the Keychain, on a Linux host in
`~/.agents-secrets/connections.json`, readable only by you. The token never goes in a log,
an error or an answer to a client. The host renews it by itself before it ends.

### Change or end the connection

On **Connectors ▸ Connections**:

- **Repositories on github.com** opens the page where you change which repositories the
  App can see.
- **Disconnect** deletes the host's tokens. Before it does, it says which folders lose
  which slots. To revoke the App too, go to github.com ▸ Settings ▸ Applications.
- When GitHub refuses a renewal, the row says so. Choose **Connect Again…**.

## Set up a folder's tools

A folder's **Connectors** page starts with its set-up. It shows four slots: **Tasks**,
**Code review**, **CI** and **Where agents run**. The heading counts the slots that are
done, such as "Set up · 3 of 4".

Each GitHub slot comes with the connection. A slot gets its tick only from one real read,
so you know that it works and not only that it is configured:

- **Tasks** reads the newest issue.
- **Code review** reads the newest pull request.
- **CI** reads the last workflow run.
- **Where agents run** is this Mac. Other places are set up in Providers.

Each slot shows what it read, such as "Newest: #12 Fix the walk". What you can do on a slot:

- **Skip** turns the slot off. Agents will not use it here, and nothing is turned on.
  **Set Up** takes it back.
- **Change…** opens the slot in place. On the Mac, **Tasks** can use Linear instead
  (**Use Linear instead…**, or **Linear…**), or a tracker **From a catalogue…**. On the
  Remote and the web page, Linear connects there, and other trackers are added on the Mac.
- When GitHub refuses a read, the slot shows **Grant on github.com** and **Try Again**. A
  slot that has read once keeps its tick when GitHub can't be reached, so a network
  problem does not undo the set-up.

With no GitHub remote, the page says so, and **Tasks** says **Choose a tracker**.

### Events

When the first slot has read, the page adds the `github` connector to the folder's
`.agents/mcp.json`, approved, once. Its events then reach the folder. The page shows
them, such as `issue.* pr.* checks.*`, and the workflows that start on them.

To add the connector by hand, add **GitHub** from the **Agents** marketplace in the catalogue on the
Mac, or write the entry yourself:

```json
{ "mcpServers": { "github": { "command": "github-mcp", "hosted": true } } }
```

Then choose **Approve** on its row on the folder's **Connectors** page. See
[Add a connector by hand](add-a-connector-by-hand.md).

## See pull requests and issues

The `github` connector has two list pages. An agent shows one when it calls the tool that
feeds it. Ask, for example, "Show the open pull requests" or "Show the open issues".

- **Pull requests** (`show_pull_requests`): each open pull request with its checks, its
  review, a **Conflicts** pill when it conflicts with its base, **Auto-merge on**, and
  CodeRabbit's status. A failing one has **Rerun**, which runs its failed jobs again.
  Click a title to open the pull request's page in the same view.
- **Issues** (`show_issues`): each open issue with its labels, its assignees and its
  comment count. Click a row to expand its rich-text description and linked pull requests.
  Click a label to show only the issues with that label. Click the label again to show all of them.

To keep a page, choose **Pin to Folder** in the view's menu, beside its name. The pin sits
under the folder in the sidebar. Each time you open it, the host reads GitHub again, so it
is up to date when it opens. It does not update while it is open: use **Refresh**. See
[Pin a page to a folder](pin-a-page-to-a-folder.md).

## Work on a pull request

A pull request's page has four tabs: **Conversation**, **Review comments**, **Files** and
**Checks**. An app's comments are marked *bot*, and CodeRabbit's are marked *CodeRabbit*.

- **Files**: choose **Show Diff**, or a file's name, to see the changed lines in the app's
  own diff. On the Mac, the iPhone and the iPad it opens as a sheet over the view. On the
  web page it opens over the chat or the pin.
- **Checks**: a failed check has **Show Log**, which shows the end of the failed jobs' logs.
  **Rerun Failed Jobs** runs them again.

Under the tabs is a box for your words, and these buttons. Each one acts on GitHub as you:

- **Comment** adds the box's words as a comment.
- **Approve** approves the pull request, with the box's words if any. **Request Changes**
  needs words in the box. Both show only on someone else's pull request, because GitHub
  does not let you review your own.
- **Merge** squashes the pull request into its base and deletes its branch.
  **Auto-merge** turns on auto-merge, so GitHub merges it once its checks pass. Each one
  asks you again first, and says when the checks fail or still run. A draft, or a pull
  request in conflict, can't be merged: rebase it first.
- **Ask an Agent** sends the work to the agent on the pull request's branch. The message
  names what is wrong (failing checks, changes asked for, a conflict, open review
  comments), adds the box's words, and tells the agent to push to the same branch. The app
  asks you before it sends. With no agent on that branch, the new-agent form opens on the
  branch instead, and you press Start.

Agents can't merge, approve or comment from this page. These are tools that only a view
can call, so a person does them. Merge, auto-merge and a review carry the commit that the
page shows. When the pull request has a newer commit, nothing happens and the page says so.
Open it again to see the new commit.

## Open a pull request

Agents open pull requests with the connector's `create_pull_request` tool. Ask the agent
to open one when its work is pushed. The ready-made **Work an issue** workflow does this by
itself (see below).

## Start an agent on an issue

On the **Issues** page, choose **Start Agent** on an issue. The new-agent form opens in the
view's folder, filled in:

- The prompt says to work on the issue, and first to assign it to yourself.
- The label is the issue's number, such as `#12`.
- The agent works in a new worktree named from the issue's number and title.

Nothing starts until you press Start. A page can't start an agent by itself. From a pinned
page, the form opens in the pin's folder.

## Work with CodeRabbit

Agents works with CodeRabbit through the `github` connector. It needs no CodeRabbit
account in Agents. Install the CodeRabbit GitHub App on the repository first. Agents knows
CodeRabbit by its GitHub App, not by a name that a person could take.

When CodeRabbit is on a pull request, the **Conversation** tab starts with its block: its
status on the last commit, the state of its last review, links to its review and its
summary, and the summary itself. The block has:

- **Ask CodeRabbit Again**, which posts `@coderabbitai review`. It shows only while the
  last commit is not reviewed, because CodeRabbit does not review a commit twice.
- **Full Review**, which posts `@coderabbitai full review`.
- **Resolve Its Comments**, with the number of its open threads, which posts
  `@coderabbitai resolve`.

On the **Review comments** tab, **Reply to CodeRabbit** answers its thread with the box's
words. On the **Pull requests** page, each row shows *CodeRabbit reviewing*,
*CodeRabbit reviewed* or *CodeRabbit failed*.

Agents can do the same with the tools `coderabbit_review`, `coderabbit_reply` and
`coderabbit_resolve`. The events `review.posted` (CodeRabbit finished a review of the head
commit) and `review.comment` (each comment of CodeRabbit's) can start a workflow.

## Let agents work the dev loop

A folder that pushes to GitHub lists three ready-made workflows on its **Workflows**
page, off. Open one and turn on its **Enabled** switch:

- **Work an issue** starts when an issue gets the `agent` label. Make that label in the
  repository first.
- **Fix failed checks** starts when a pull request's checks fail.
- **Address review comments** starts when CodeRabbit finishes a review.

See [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md) for what
each one does and how to change it.

## See also

- [Views in a conversation](../explanation/views.md)
- [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md)
- [Events](../reference/events.md#events-from-mcp-servers)
- [Use GitLab](use-gitlab.md)
- [Use Linear issues](use-linear-issues.md)
- [Connector levels](../explanation/connector-levels.md)
