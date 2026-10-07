---
diataxis: explanation
description: How the app draws a tool's ui:// view (MCP Apps) on the Mac, the iPhone and iPad, and the web page, what a view may reach, and what its messages do in Agents.
---

# Views in a conversation

A tool can come with a view of its own: a small page, drawn in the conversation where the
tool was called, that shows the result better than text could and that you can work with.
This is MCP Apps ([SEP-1865, 2026-01-26](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx)):
a tool names a `ui://` resource, the resource is HTML, and the view talks to the app over
`postMessage` in JSON-RPC.

The app draws views from its own `agents` server, and from your own MCP servers reached over
http ([Views from your own servers](#views-from-your-own-servers)). Views from servers that
run on this machine (stdio) aren't shown yet.

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
| `ui/update-model-context` | Keeps what the view said, and tells the agent with **your next message**: before your words, not in your bubble, in the same way the app tells an agent that a wait ended. Only the last context from each view is kept, and it is used once. A line under the view says what the agent will be told, with **Don't Tell** to take it back. It is kept in memory only, so a daemon restart forgets it. |
| `ui/request-display-mode` | `inline` or `fullscreen`. Full screen draws the same view in the chat's place, as a pinned page opens, with **Back to the chat**. You can also go full screen from the button beside the view's name. |
| `ui/notifications/size-changed` | The view's height in the chat, up to 640 points. |
| `notifications/message` | A line in the daemon's log. |
| `ui/resource-teardown` | Sent before a view goes: when you open another conversation, or when more than eight views are open in one chat. The app waits up to two seconds for the answer. |

## Pinning a view

A view can be pinned under a project, beside its pinned pages, on the Mac,
the Remote and the web page. **This is our extension of MCP Apps (SEP-1865).** The spec
ties a view to a tool call the model made. A pin is the host making that call itself.

- **What a pin names.** The server, the view's `ui://` address, the tool that feeds it,
  and that tool's arguments (at most 2 KB of JSON). It is kept in `.agents/pins.json`
  beside the Markdown and HTML pins, and shared through git, so the arguments never hold a
  secret. A project has at most 10 pins, pages and views together.
- **Opening it.** The host calls the feeding tool (`views/call` with `feed: true`) and
  draws the view full page with that call's input and result. Each time it is opened the
  call is made again, so the view is as of then. It does not update while open.
- **Which tools can feed a pin.** Only a tool a view may call (`visibility` includes
  `app`) that is marked as changing nothing (`annotations.readOnlyHint`), because opening
  a pin calls it. Anything else is refused.
- **Which servers.** The `agents` server's, and your own http servers' (#191). A pin this
  host can't draw shows as missing, with why: *server not set up here*, *waiting for
  approval*, *a secret is missing*, *needs a sign-in*, *views from local servers aren't
  shown yet* or *no such view*. Each host says for itself, since each has its own servers. That is the way a pinned file shows as missing until its
  branch lands.
- **No agent.** A pinned view is on a project's page with no
  conversation. Its `ui/message` and `ui/update-model-context` are refused, and the refusal
  goes in the daemon's log.
- **How to pin one.** **Pin to Project** in the view's menu, beside its name in the chat
  or in full screen, when the server says the call can feed a pin. An agent pins one with
  `pin_page` and `view` (`server`, `uri`, `tool`, `arguments`). `unpin_page` and `move_pin`
  take the view's `ui://` address as its `path`.

## Views from your own servers

A tool of one of your own MCP servers — in a project's `.agents/mcp.json`, your own
`~/.agents/mcp.json`, or a plugin — can have a view too (#191). The app draws it in the turn
that called the tool and as a pin, on the Mac, the Remote and the web page, in the same
sandbox as the app's own views.

- **How the app knows.** The runtime connects to your server, not the app, and no runtime
  says a tool has a view (#186). So the daemon reads which server and tool were called from
  how the runtime describes the call (by its shape, never by the runtime's name), and checks
  that the server's own list of tools says the tool has a view. The app never calls a tool
  again to get its result: the view gets what the runtime passed on.
- **Where the connection runs.** The daemon makes a connection of its own to the server, on
  the host that runs the project, with the secrets filled from `secrets.env` as for a
  session. It reads the server's tools and `ui://` resources (kept in `<root>/mcp-views/`, a
  day at most), the view's HTML, and the tools the view calls. Clients never connect to your
  server. At most 4 such connections are open on a host, the least recently used goes
  first, and each ends after 2 minutes unused.
- **http only, for now.** A server that runs on this machine (stdio) would need a second
  copy of it beside the runtime's, so its views aren't shown yet, and its pin says *views
  from local servers aren't shown yet*. The old sse transport shows no views.
- **Approval, and Show.** A server waiting for approval shows nothing, nor does one missing
  a secret or wanting a sign-in. The first time a server's view is to be drawn, it asks in
  the view's place: "*server* wants to show a view here", with **Show** and **Don't Show**.
  It asks again whenever the view changes (its address, type, HTML or `_meta.ui`), and it
  asks for your own servers too, since it is about drawing their HTML, not about running
  them. The answers are kept beside the approvals in `<root>/mcp-approvals.json`. **Ask
  Again** on the server's row in the project's MCP servers forgets them.
- **What it may reach.** Exactly what it declared in its `_meta.ui.csp`, as above. Its
  `tools/call` reaches only its own server, and only a tool whose `visibility` includes
  `app`. A view of one server asking for another's tool, or for the `agents` server's, is
  refused and logged. Its `resources/read` is its own server's.
- **The caption** names the server: "get-time · basic-vanillajs".
- **Which runtimes draw it in the chat.** Claude (walked), Codex and Copilot (by the shapes
  the #186 probe recorded). OpenCode passes only text, so its calls' views are not drawn in
  the chat; pin them instead. A runtime whose call is named only by a joined title
  (Copilot, OpenCode) is drawn once it has answered.
- **A known limit.** A tool only a view may call (`visibility: ["app"]`) is still offered to
  the model, since every runtime lists the server's tools itself and none filters them.
  Nothing on the app's side can hide it.
- **Logged.** The server's name, the view's address, its policy and words such as
  *connected*, *ended* or *refused*. Never its command, URL, headers, environment or any
  body.

## The test view

The `agents` server has a test view, `ui://agents/test-view`, for proving all of this on
every device. An agent can draw it with `show_test_view`. Its **Count** button calls
`test_view_count`, which only a view may call. Inside, the view tries to reach `example.com`,
which it never declared, and says in the view and in the daemon's log that it was blocked.
It is offered to agents only when the daemon is started with `AGENTS_TEST_VIEWS=1`, so the
agents you work with are not handed a tool for testing the app. `show_test_view` is
read-only, so the test view can be pinned; `test_view_count` is not, so it can't feed one.
