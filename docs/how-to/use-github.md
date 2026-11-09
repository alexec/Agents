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

### Which token agents use

The connection's row on **Connectors ▸ Connections** says which kind of token GitHub uses:

- **App user token** (the default): the token from **Continue on github.com**. GitHub lets it
  do only what both you and the `agents-loops` App can do, on the repositories where the App
  is installed. So an agent never has more rights than you. Each issue, comment, pull request
  and review that an agent makes through the github server shows the App's badge. The host
  renews the token before it ends, so a long session gets no error.
- **Personal access token** (the fallback): a token that you made on github.com, for an
  organisation that does not let the App in. It has all the rights that you gave it, and a
  post shows no badge. The row says when it ends. To use one, choose **Personal access
  token** on the **Connect GitHub** sheet, on the Mac or the web page. **Make a Token on
  GitHub** opens github.com's page for a classic token, named Agents, with the `repo` and
  `codespace` scopes. Paste the token (it starts with `ghp` or `github_pat`) and choose **Connect**. The
  host checks the token with github.com and keeps it; the host does not renew it, so make a
  new one when it ends. Agents connects only github.com, not a GitHub Enterprise Server.

The token stays on the host. It never goes to the control plane.

An agent's own `gh` and `git` use the same token (#3926), in a folder whose repository the
App reaches: the `agents-loops` App is installed on it, or your bot is installed on its owner
(then the bot's token). Agents puts its own `gh` first on the agent's PATH, and makes
`agentsd credential` git's only credential helper for `https://github.com`. Both ask the host
for the current token at each call, so a session of any length gets no error. The agent's
environment holds only a grant for that one session, which the host takes back when the
session's runtime ends; no token is in the environment or in a file. In a folder that the App
does not reach, and with a personal access token, the agent's `gh` and `git` use your own
login, as before. A push over SSH always uses your own key.

GitHub lets the App's user token do only what the `agents-loops` App's install may do (#4077).
When the App may not do a thing that you may do, your own login does it:

- When GitHub refuses the agent's `gh` with "Resource not accessible by integration" (for
  example, `gh run rerun` needs the App's **Actions** permission to be read and write), the
  agent's `gh` runs the command again once, with your own `gh` login, and says so. It does
  not run it again when the first run printed a result or read its input from stdin.
- When the App's install on the repository's owner may not write code (its **Contents**
  permission is not read and write), `agentsd credential` gives git no token, and git asks
  your own `gh auth git-credential` next. Git also asks it when the host does not know the
  session's grant, for example after the host restarted.

To make the agents' posts show the App's badge for these too, give the `agents-loops` App
**Contents**, **Pull requests** and **Actions** read and write on github.com, and accept the
new permissions on its install.

The App and the bot have no Workflows permission, so GitHub refuses their push of a change to
`.github/workflows/`. Push such a change from your own terminal.

### Change or end the connection

On **Connectors ▸ Connections**:

- **Repositories on github.com** opens the page where you change which repositories the
  App can see.
- **Disconnect** deletes the host's tokens. Before it does, it says which folders lose
  which slots. To revoke the App too, go to github.com ▸ Settings ▸ Applications.
- When GitHub refuses a renewal, the row says so. Choose **Connect Again…**.

### Make your agents' bot

With only the connection, your agents post on GitHub as you. A bot of their own posts as
`<login>-agents[bot]`. Each comment, issue and pull request ends with a line that names you,
and each commit ends with a `Co-authored-by` trailer for you (#3858).

1. On **Connectors ▸ Connections**, under the GitHub row, choose **Make My Agents' Bot…**.
2. To use the bot on an organisation's repositories, turn on **Organisations can install
   it**. The organisation's owner then approves the install.
3. Choose **Continue on github.com**, then **Create GitHub App** on GitHub.
4. Back in Agents, choose **Install on Repositories…** and select the repositories that
   agents work on.

The bot can read and write code, issues and pull requests, read checks and statuses, and run
workflows again. It can never change workflows, secrets, environments, settings or members
(`specs/3856-agent-identity-github-app/spec.md`). The tools that need those use your own
connection.

GitHub gives the bot's key to the machine that made it. The key stays in that machine's
Keychain, or in `~/.agents-secrets` on Linux. The github server on a machine uses the bot when
the bot is installed on the owner of the folder's repository.

Your other machines get the key from that machine, sealed to each one (#3950). The machine seals
it to the key that your machine lock gives for each of your machines, and signs it. Agents'
servers pass it on and cannot read it, and no app or browser sees it. A machine of another
person never gets it. A machine that is offline gets the key when it and a machine with the key
are both online. The bot's row says which machines have the key. With no machine lock, the key
stays on the machine that made it.

**Forget the Bot…** deletes the key on all your machines and opens the App's page on GitHub,
where you delete the App. A machine that you remove deletes its key when Agents' servers tell
it that it was removed. A removed machine that is not honest can keep a copy: when you remove a
machine that you do not trust, also make a new private key for the App on its GitHub page, and
delete the old one.

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

## Approve a waiting deploy

A deploy that a GitHub environment holds for its required reviewers (for example a
`release.yml` job with `environment: production`) shows in **Needs You** as a **Deploy** row,
when you are one of its reviewers. The row says the tag or branch, and what it waits for:
*Release to production · v0.17.0 waits for your approval*.

- Choose the row to see what ships: the run, the environment, its reviewers, the commit,
  and, for a version tag, each commit since the version tag before it.
- **Approve** lets the run go on. **Reject** stops it. Both act on GitHub as you, so
  GitHub keeps who answered, with the comment "Approved in Agents" or "Rejected in Agents".
  The Mac and the Remote also have both in the row's menu.
- The gate is GitHub's. Agents adds none of its own, and an agent can't answer one: only
  a window or a device can. GitHub refuses an answer from a person who is not a reviewer.
- Agents reads the waiting runs every two minutes. A workflow can wait on the github
  server's `deploy.waiting` event instead.

A release to the App Store is one of these (#3657): the **app-store** workflow waits at its
`app-store` environment, and Approve sends the version to App Review
([Release Agents Host](release-agents-host.md)). The version is then on the release's Work
page as **App Store 0.17.0**, after its TestFlight build.

To approve here, the GitHub App `agents-loops` must have the **Deployments** permission
(read and write), and the installation must accept it (github.com/settings/installations).
Without it, the row still shows, but GitHub refuses Approve and the app shows an error (#3932
makes the error say why).

## Make a new app's repository

Ask an agent for a new app, and it can make the app's repository for you (#3708): a
private repository in your GitHub account, or in an organisation you name, with a starter
(an iPhone app or a web service) as its first commit. The agent's machine clones it beside
your other clones and adds it as a folder, so it shows in the session list on every client.
When a step fails, ask again: each step that is done already is skipped.

The agent follows the ready-made skill `start-a-new-app` (#3712), in voice mode or typed,
from the first question to the first deploy. It asks the kind of app (an iPhone app, a web
service, or both) and its name, makes the repository and the deploy gates with you as their
reviewer, then does Apple, Google Cloud and Sentry as the app needs them. Each step that
needs your hands is a card, and each secret is a form for this session only, which goes
into the repository's CI. Then it tags `v0.1.0`, and you approve the deploy in **Needs
You**. When you answer **Can't do it**, it stops and says what is left; ask again later,
and it goes on from there.

To make a repository, the GitHub App `agents-loops` must have the **Administration**
permission (read and write), and be installed on **All repositories**, so that it can push
to the new one. Without them, GitHub refuses, and the agent says so.

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
