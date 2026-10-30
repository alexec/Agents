---
diataxis: explanation
description: How the app draws a tool's ui:// view (MCP Apps) on the Mac, the iPhone and iPad, and the web page, what a view may reach, and what its messages do in Agents.
---

# Views in a conversation

A tool can come with a view of its own: a small page, drawn in the conversation where the
tool was called, that shows the result better than text could and that you can work with.
This is MCP Apps ([SEP-1865, 2026-01-26](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx)):
a tool names a `ui://` resource that its server also lists, the resource is HTML, and the view talks to the app over
`postMessage` in JSON-RPC.

If the resource is not listed, the host treats the call as a normal tool call. If a listed
resource cannot be read, the call's result stays visible below the view error.

The app draws views from its own `agents` server, from the `github` server
([The github server's views](#the-github-servers-views)), and from your own connectors (MCP servers)
reached over http or hosted by the app ([Views from your own servers](#views-from-your-own-servers)).
Views from other servers that run on this machine (stdio) aren't shown yet.

## Where a view comes from

No runtime tells the app that a tool has a view (the #186 probe): none passes a tool's
`_meta` on, and Claude replaces a result's text with its `structuredContent`. So the app
does not ask the runtime. The `agents` server is the app's own daemon, which sees every call
of its tools. When an agent calls a tool that has a view, the daemon writes the view into the
conversation twice: once as the call arrives, with its input, and once when it is answered,
with the whole result. If the turn is stopped first, the second entry says the call was
cancelled. Every client draws the view from those entries, so a view looks the same whichever
runtime called the tool.

A view is drawn where its call began, at every turn level, like a reply.

## What a view may reach

Each view is drawn under a policy built from what its server declared in the resource's
`_meta.ui.csp`, and nothing else:

- **Nothing undeclared.** With nothing declared, a view has no network at all, and can load
  pictures, styles, fonts and scripts only from itself and `data:`. A declared entry is kept
  only if it is a plain origin, such as `https://api.example.com` or `https://*.cdn.example.net`.
  Anything wider (`*`, `https:`, a keyword, a path) is dropped, and the drop is logged.
- **No frames or plugins.** No frames unless frames were declared, never `<object>`, no
  form posting, and no moving the page's base.
- **Nothing of the app's.** A view runs in a sandboxed frame with an origin of its own and no
  storage that outlasts it. It cannot read the app's cookies, storage or tokens, and it
  cannot navigate anywhere. It opens a link only by asking.
- **Logged.** The daemon's log has each view's policy as it is read, every log line the view
  sends, and any tool a view asked for and was refused.

How each client enforces it:

| Client | How the view is held |
|---|---|
| Mac, iPhone, iPad | A web view of its own with nothing kept. The view is in a `sandbox="allow-scripts"` frame inside a page of the app's. The policy is on that page and again at the top of the view. A WebKit content-blocking list blocks every load except the declared origins. The bridge runs in a script world of the app's own, which the view cannot see. |
| Web page | The spec's sandbox proxy. The page is at `localhost`; the proxy is served only at `127.0.0.1` on the same port, so it has a different origin. The proxy is drawn under the view's own policy (the control plane rebuilds that policy from the domains in its address, using the same rules) and can be framed only by the page. It holds the view in a `sandbox="allow-scripts"` frame of its own. |

## What its messages do in Agents

| Message | What the app does |
|---|---|
| `ui/initialize` | Answers with the host's context: theme, `platform` (`desktop` on the Mac, `mobile` on the Remote, `web` on the page), container size, locale, time zone, safe-area insets, and the app's colours and fonts as the spec's CSS variables, in `light-dark()`. |
| `ui/notifications/initialized` | Sends `tool-input` with the call's arguments, and then `tool-result` or `tool-cancelled` once the call has one. |
| `tools/call` | Calls the tool on the `agents` server for the conversation the view is in. Only a tool whose `visibility` includes `app` can be called this way. A tool that only a view may call is never offered to the agent. |
| `resources/read` | Reads a `ui://` resource of the same server. |
| `ui/open-link` | Opens an `http`, `https` or `mailto` link in your browser. Any other kind of link is refused. |
| `ui/message` | **Asks you first.** Under the view: "The view asks to send this as your message", with **Send** and **Don't Send**. Send sends it as your own prompt, exactly as if you had typed it. A view never speaks for you without you. |
| `agents/start-agent` | **Our extension (#834).** Opens the new-agent form in the view's folder, filled in with the view's `prompt`, its `labels` and, when it names one, a new `worktree` of that name. You start the agent, or don't: a view never starts one. From a pinned view, it opens the form in the pin's folder. A `branch` instead puts the agent in a new worktree on that branch (#837). |
| `agents/message-agent` | **Our extension (#837). Asks you first.** Sends the view's `text` to the session whose worktree is on the view's `branch`, in the view's folder (the latest active one not archived). Under the view: "The view asks to send this to "*session*" as your message", with **Send** and **Don't Send**. It works from a pinned view too. With no such session, the answer is error `-32001`, and the view can offer a new agent instead. |
| `tools/call` of `agents_lineage` | **Our extension (#2941).** Answered by the host itself, from its own record (`lineage/walk` and `lineage/cost`), and never passed to the server. Only a view of the `github`, `gitlab` or `linear` server may ask, with an issue's or a pull request's `url`; another server's view is refused and logged, since the record names your sessions and what they cost. The answer is the Lineage section's words: who worked on it, each session's cost, tokens and time, and each pull request's end and cost. |
| `agents/open-diff` | **Our extension (#1341).** Draws the view's `files`, each as its hunks of context, added and removed lines, in the app's own diff (the Review page's, #1472): over the view, as a sheet on the Mac, the iPhone and the iPad, and over the chat or the pin on the web page. Unified, or Side by Side on a wide one. Each file's path and counts, a break between hunks, long unchanged runs folded, and **Open on GitHub** for the view's `url`. At most 3000 files and 20,000 lines. It works from a pinned view too. |
| `ui/update-model-context` | Keeps what the view said, and tells the agent with **your next message**: before your words, not in your bubble, in the same way the app tells an agent that a wait ended. Only the last context from each view is kept, and it is used once. A line under the view says what the agent will be told, with **Don't Tell** to take it back. It is kept in memory only, so a daemon restart forgets it. |
| `ui/request-display-mode` | `inline` or `fullscreen`. Full screen draws the same view in the chat's place, as a pinned page opens, with **Back to the chat**. You can also go full screen from the button beside the view's name. |
| `ui/notifications/size-changed` | The view's height in the chat, up to 640 points. |
| `notifications/message` | A line in the daemon's log. |
| `ui/resource-teardown` | Sent before a view goes: when you open another conversation, or when more than eight views are open in one chat. The app waits up to two seconds for the answer. |

## A server's list views in the sidebar

A connected server's **list views** show under each folder by themselves, with no pin
(#2032), on the Mac, the Remote and the web page. A list view is one that a read-only tool
a view may call feeds with no required argument: the `github` server's
`ui://github/pulls` and `ui://github/issues`, but not `ui://github/pr`, which needs a
pull request's number. **This is our extension of MCP Apps (SEP-1865)**, as pins are.

- **Where.** In the folder's group, after its pinned pages and before its sessions.
- **Its name.** The service, then the view: **GitHub · Pull requests**, **GitHub · Issues**,
  **Linear · Issues**. The service is the catalogue's title for a connector Agents makes, else
  the server's own (`serverInfo.title`), else its name in `mcp.json`. A view title that
  starts with the service's ("Linear issues") loses it.
- **Which servers.** Each server set up and approved for the folder that can show views
  here, as for a pin. A server waiting for approval, missing a secret or run over stdio shows
  no row. The GitHub connector's views show only in a folder whose `origin` is on
  github.com, and GitLab's only where it is on another host.
- **Opening one.** As a pinned view opens: the host calls the feeding tool afresh.
- **Its count.** The row ends in a grey count, such as **GitHub · Issues 23** (#2033). The
  host calls each shown view's feeding tool every 2 minutes, once for every client, and
  shows the `count` in its answer's `structuredContent` (or `_meta`). A server may also say
  `attention`, how many of them want you (the GitHub connector: your pull requests whose
  checks fail). A failed call keeps the last count, and its tooltip says when it was read.
  A hidden view is not called. The GitHub, GitLab and Linear connectors send the count of
  what the view lists: open pull requests, issues and merge requests.
- **Hide.** The row's menu, or **Hide** at the top of the view, takes it out of the sidebar.
  The hidden addresses are kept in `.agents/pins.json` as `hidden_views` (at most 50).
  **Show Hidden Views** in the folder's menu puts them back.
- **Pinned.** A list view that is pinned shows as its pin only. List views do not count
  towards the 10 pins.

## Pinning a view

A view can be pinned under a folder, beside its pinned pages, on the Mac,
the Remote and the web page. **This is our extension of MCP Apps (SEP-1865).** The spec
ties a view to a tool call the model made. A pin is the host making that call itself.

- **What a pin names.** The server, the view's `ui://` address, the tool that feeds it,
  and that tool's arguments (at most 2 KB of JSON). It is kept in `.agents/pins.json`
  beside the Markdown and HTML pins, and shared through git, so the arguments never hold a
  secret. A folder has at most 10 pins, pages and views together.
- **Its name.** The title the server gives the view, such as **Test view** for
  `ui://agents/test-view`, kept with the pin when it is pinned (#905). When the server gives none,
  the last part of the address.
- **Opening it.** The host calls the feeding tool (`views/call` with `feed: true`) and
  draws the view full page with that call's input and result. Each time it is opened the
  call is made again, so the view is as of then. It does not update while open.
- **Which tools can feed a pin.** Only a tool a view may call (`visibility` includes
  `app`) that is marked as changing nothing (`annotations.readOnlyHint`), because opening
  a pin calls it. Anything else is refused.
- **Which servers.** The `agents` server's, and your own http and hosted servers' (#191, #1341). A pin this
  host can't draw shows as missing, with why: *server not set up here*, *waiting for
  approval*, *a secret is missing*, *needs a sign-in*, *views from local servers aren't
  shown yet* or *no such view*. Each host says for itself, since each has its own servers. That is the way a pinned file shows as missing until its
  branch lands.
- **No agent.** A pinned view is on a folder's page with no
  conversation. Its `ui/message` and `ui/update-model-context` are refused, and the refusal
  goes in the daemon's log.
- **How to pin one.** **Pin to Folder** in the view's menu, beside its name in the chat
  or in full screen, when the server says the call can feed a pin. Only you pin one:
  agents have no pin tools.

## Views from your own servers

A tool of one of your own connectors — in a folder's `.agents/mcp.json`, your own
`~/.agents/mcp.json`, or a plugin — can have a view too (#191). The server is reached over
http, or is one the app hosts (`"hosted": true`, #1341). The app draws it in the turn
that called the tool and as a pin, on the Mac, the Remote and the web page, in the same
sandbox as the app's own views.

- **How the app knows.** The runtime connects to your server, not the app, and no runtime
  says a tool has a view (#186). So the daemon reads which server and tool were called from
  how the runtime describes the call (by its shape, never by the runtime's name), and checks
  that the server's own list of tools says the tool has a view. The app never calls a tool
  again to get its result: the view gets what the runtime passed on.
- **Where the connection runs.** The daemon makes a connection of its own to the server, on
  the host that runs the folder, with the secrets filled from `secrets.env` as for a
  session. A hosted server's views go through the host's one copy of it, the copy that the
  sessions use; the views keep it running for 2 minutes after their last request. It reads the server's tools and `ui://` resources (kept in `<root>/mcp-views/`, a
  day at most), the view's HTML, and the tools the view calls. Clients never connect to your
  server. At most 4 such connections are open on a host, the least recently used goes
  first, and each ends after 2 minutes unused.
- **http and hosted only, for now.** A server that runs on this machine (stdio) and that the
  app does not host would need a second copy of it beside the runtime's, so its views aren't
  shown yet, and its pin says *views from local servers aren't shown yet*. The old sse
  transport shows no views.
- **Approval, and Show.** A server waiting for approval shows nothing, nor does one missing
  a secret or wanting a sign-in. The first time a server's view is to be drawn, it asks in
  the view's place: "*server* wants to show a view here", with **Show** and **Don't Show**.
  It asks again whenever the view changes (its address, type, HTML or `_meta.ui`), and it
  asks for your own servers too, since it is about drawing their HTML, not about running
  them. The answers are kept beside the approvals in `<root>/mcp-approvals.json`. **Ask
  Again** on the server's row in the folder's Connectors forgets them.
- **What it may reach.** Exactly what it declared in its `_meta.ui.csp`, as above. Its
  `tools/call` reaches only its own server, and only a tool whose `visibility` includes
  `app`. A view of one server asking for another's tool, or for the `agents` server's, is
  refused and logged. Its `resources/read` is its own server's.
- **The caption** names the server: "get-time · basic-vanillajs".
- **Which runtimes draw it in the chat.** Claude (walked), Codex and Copilot (by the shapes
  the #186 probe recorded). OpenCode passes only text, so its calls' views are not drawn in
  the chat; pin them instead. A runtime whose call is named only by a joined title
  (Copilot, OpenCode) is drawn once it has answered.
- **A tool only a view may call** (`visibility: ["app"]`) is not offered to an agent by a
  hosted server: the host leaves it out of the sessions' `tools/list`, and refuses a
  session's call of it (#1341). An http server's is still offered to the model, since every
  runtime lists that server's tools itself and none filters them. Nothing on the app's side
  can hide it. Nor can the app hide it when it has no room to host the server, and the
  runtime runs a copy of its own.
- **Logged.** The server's name, the view's address, its policy and words such as
  *connected*, *ended* or *refused*. Never its command, URL, headers, environment or any
  body.

## The github server's views

The `github` server (`Go/internal/githubmcp`, #1341) has three views, each fed by a
read-only tool, so each can be pinned. This folder pins the first two in its
`.agents/pins.json`; another folder with the `github` server pins them with **Pin to
Folder**.

- **Pull requests** (`ui://github/pulls`, from `show_pull_requests`): the open pull
  requests, each with its checks, review, conflict, auto-merge and CodeRabbit's status
  (*CodeRabbit reviewing* or *CodeRabbit reviewed*), and **Rerun** on a failing one. A title opens the pull request's page in the same view.
- **Issues** (`ui://github/issues`, from `show_issues`): the open issues, with their labels
  and assignees. A label narrows the list. Click a row to expand its rich-text description
  and linked pull requests. **Start Agent** opens the new-agent form for the issue.
- **Lineage** (#2941): an issue's expanded row, and a pull request's **Lineage** tab, say
  what worked on it: the sessions on it and on its pull requests, and the helpers they
  started, each with its cost, tokens and time; each pull request with its end (merged,
  closed, open) and cost; and the total and the waste. The gitlab server's Issues and merge
  request page, and the linear server's Issues, have the same section (`lineage.js`, copied).
- **A pull request's page** (`ui://github/pr`, from `show_pull_request`): the description
  and the conversation, the comments on lines of code, the files, and the checks, where a
  failed check shows the end of its log (`failed_log`). An app's words are marked *bot*;
  CodeRabbit's are marked *CodeRabbit* (#1344). **Comment**, **Approve** and **Request Changes** (on someone else's
  pull request), **Merge** and **Auto-merge** (each asked again), and **Ask an Agent**: to
  the agent on the branch, or the new-agent form on it. **Show Diff**, or a file's name,
  reads its hunks (`show_pull_request_diff`) and asks the app to draw them
  (`agents/open-diff`).
- **CodeRabbit on a pull request's page** (#1344): when CodeRabbit is on the pull request, the
  Conversation tab starts with its block: its status on the last commit, its last review's
  state, and its summary (the one comment it edits after each review). **Ask CodeRabbit
  Again** (only while the last commit is not reviewed: CodeRabbit does not review a commit
  twice) and **Full Review** post `@coderabbitai review` and `@coderabbitai full review`;
  **Resolve Its Comments** posts `@coderabbitai resolve` while it has open threads. On the
  Review comments tab, **Reply to CodeRabbit** answers its thread with the box's words. These
  are the tools `coderabbit_review`, `coderabbit_resolve` and `coderabbit_reply`, which agents
  may call too.

Merge, review and comment are tools that only a view may call (`merge_pr`, `review_pr`,
`comment_on_pr`): a person does them, from the page. Only the copy of `github-mcp` that the
host runs has them (it sets `AGENTS_MCP_HOSTED=1`), and the host leaves them out of an
agent's list. When the host has no room for another copy, a session runs its own, without
them. `gitlab-mcp` does the same with `merge_merge_request` and `approve_merge_request`, which
also carry the head commit that the page shows (`sha`, from `headSha`). The
server reads GitHub as the
person, with the host's GitHub connection (#1335). Merge, auto-merge and review carry the
head commit that the page shows (`sha`, from `headSha`). When the pull request has a newer
commit, the server does nothing and says so: open the page again to see it. The diff is of
that commit too.

## The test view

The `agents` server has a test view, `ui://agents/test-view`, for proving all of this on
every device. An agent can draw it with `show_test_view`. Its **Count** button calls
`test_view_count`, which only a view may call. Inside, the view tries to reach `example.com`,
which it never declared, and says in the view and in the daemon's log that it was blocked.
It is offered to agents only when the daemon is started with `AGENTS_TEST_VIEWS=1`, so the
agents you work with are not handed a tool for testing the app. `show_test_view` is
read-only, so the test view can be pinned; `test_view_count` is not, so it can't feed one.
