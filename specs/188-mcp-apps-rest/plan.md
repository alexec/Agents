# Implementation Plan: MCP Apps, the rest (#188, #189, #190, #191)

**Branch**: `agents/build-free-planning-rest` | **Date**: 2026-10-04 | **Spec**: [spec.md](spec.md)

**Input**: issues #188 (Dashboard as `ui://agents/dashboard`), #189 (pin a `ui://` view), #190 (remove
the native tile renderer), #191 (third-party servers' views). It builds on #187 (the host, on
`agents/build-github-issue-187` @ `324ee04d`, going into a merge wave) and #186's probe
([`specs/research/186-mcp-apps-acp-probe.md`](../research/186-mcp-apps-acp-probe.md), commit
`0a78c009`, on `agents/re-mcp-apps-lane`).

Planned without building or running anything (Alex's rule for this session, while #234 has the
machine). Every claim about the code was read from source at `28884102` (main side) or `324ee04d`
(#187), not from a run. Questions for Alex are in [Open questions](#open-questions). The tasks are in
[tasks.md](tasks.md).

## Summary

#187 made the app an MCP Apps host for one kind of view: a tool **an agent called** in a
conversation, on the app's own `agents` server. Everything it built is keyed by that conversation
(`agentID` in every `views/*` request, `AppViewStore` per chat, `ViewLayer` in the transcript).
The four issues left need three new things, and reuse the rest:

1. **A view in a project's place, not a chat's** (#188, then #189). The Dashboard and a pin are
   opened by a person from the sessions column. No agent called anything, so the **host makes the
   call itself**: it calls the view's feeding tool (one a view may call) and hands the view
   `tool-input` and `tool-result` as if a model had. #188 builds this "project place" once for
   the Dashboard; #189 makes it general and stores it in `.agents/pins.json`.
2. **Results that change while the view is open** (#188). The Dashboard is live. The daemon
   already says `dashboard/changed` (at most once a second per project). The host answers it by
   calling the feeding tool again and sending `ui/notifications/tool-result` again. No new
   protocol, no polling.
3. **The app as an MCP client** (#191). A connection of the daemon's own to a third-party server,
   to read its `ui://` resources and pass a view's app-only `tools/call` through, on the host
   where the project runs. The view's input and result in the chat come from the runtime's ACP
   updates, parsed by their shape, since #186 found no runtime passes a tool's `_meta`.

#190 is deletion behind a gate. Its list of what must be true first is under [#190](#190-remove-the-native-tile-renderer).

## Order

```
#187 merged ─▶ #188 Dashboard view ─▶ #189 pins ─────────────▶ #191 third-party views
                     │                                              ▲
                     └─ walked on 4 clients ─▶ #190 remove native   │
                                                                    │
  #191 groundwork (MCP client, catalog, ACP shape parser; daemon only, no UI) ─┘
```

- **#188 first.** It is the base for #189 and #190: the project place, the feeding call, live
  results, the views build pipeline and the in-app link scheme.
- **#189 next**, on #188's project place. It only adds the pin record, the tools and the Pin
  action. Until #191, the app's own server has few views worth pinning (see [Q4](#open-questions)).
- **#190 can run beside #189**, once #188 is walked tile type by tile type on the Mac, iPhone, iPad
  and web. It touches disjoint files (the native renderers) from #189 (pins).
- **#191 last**, as the issue chain says. Its daemon groundwork (client, catalog, ACP shape
  parser) has no UI and nothing that conflicts with #188–#190, so a lane can start it early.

## What each reuses from #187

| #187 piece | Where | #188 | #189 | #190 | #191 |
|---|---|---|---|---|---|
| Renderer (`AppViewHost`, `AppViewRow`, `AppViewFullscreen`, WKWebView shell, `sandbox="allow-scripts"` srcdoc frame, content world, content-blocking rules) | `Shared/UI/AppView/` | as is; a new owner (project store) | as is | Dashboard row opens it | as is |
| Web sandbox proxy (`sandbox.html`, `proxy.ts`, `viewLayer.ts`, `AppView.tsx`) | `Web/src/sandbox/`, `Web/src/views/chat/` | `ViewLayer` gains a page place beside the transcript | same | Dashboard route draws it | as is |
| Bridge (`AppViewBridge.swift` / `appViewBridge.ts`, `AppViewFeed`) | AgentsKitCore, Web | `AppViewFeed` gains "a newer result" (re-send `tool-result`) | same | — | as is |
| Policy (`AppViewPolicy`, strict default, plain origins only) | AgentsKitCore | strict default, nothing declared | same | — | per server from its `_meta.ui.csp`; the proxy's policy-in-the-address carries over |
| Theme (`AppViewTheme`, Paper as `--color-*` in `light-dark()`) | AgentsKitCore | the Dashboard view is drawn only with these variables | same | parity with today's look depends on it | as is |
| Catalog (`AppViewCatalog`), `resources/list`/`read` on `AppService` | AgentsKit | the Dashboard resource and its app-only tools join it | — | — | a per-server copy, made from that server's `tools/list` and `resources/list` |
| `appView` transcript entry (`AppViewCall`), `views/toolCall` | AgentsKitCore | `read_dashboard` writes one (drawn compactly, [Q1](#open-questions)) | Pin in its caption menu | — | written from ACP updates for a third party's tool |
| `views/read`, `views/call`, `views/log`, `views/context` | `AppViewsWire.swift` | gain a project place | same | — | gain a `server` |

## The shared change: a view's place

Today `ViewReadRequest`, `ViewCallRequest`, `ViewLogRequest` and `ViewContextRequest` carry
`agentID: UUID`. They gain a **place**: the conversation, as now, or a project.

```swift
// AgentsKitCore/AppViews/AppViewsWire.swift (sketch)
public enum ViewPlace: Codable, Sendable, Hashable {
    case agent(UUID)                 // #187: a call an agent made, in its chat
    case project(folder: String)     // #188/#189: the Dashboard, a pin
}
```

On the wire it stays backward compatible: `agentID` is kept, and a new optional `project` field is
added. Exactly one of the two must be set. A client built before #188 sends only `agentID`, and
nothing changes for it.

**What a project place may do.**

- `views/read` and `views/call` check the caller's grant for the project, the one grant for every
  client (#111).
- `views/log` is the same as in a chat.
- `ui/message` and `ui/update-model-context` have no agent to go to. They are refused with
  `viewRefused` and a reason, and the refusal is logged ([Q3](#open-questions)).
- The caller of an app-only tool from a project place is **the person**, so the daemon applies
  the person's rules. For the Dashboard: hide, show, remove and arrange, never set a value (074
  FR-027).

**The host makes the call.** A project place holds an `AppViewCall` the host made up itself:
`server`, `tool` (the feeding tool), `resourceURI` and `arguments`, with `state` running and then
done. It is never written to a transcript. `views/call` with `feed: true` makes the feeding call.
That call is allowed only for a tool whose visibility includes `app` and which is marked
read-only (`annotations.readOnlyHint: true`), because opening a page must never change anything.
Live results are the same call made again.

**Stores.**

- Mac and Remote: `AppViewStore` per chat stays. A project store, `AppViewStore(place:
  .project)`, is kept per open project page. Leaving the page tears it down: `ui/resource-teardown`
  first, as now.
- Web: `ViewLayer` gets a page-level slot (`Web/src/views/page/ViewPage.tsx`), not only the
  transcript's.

## #188: the Dashboard as a `ui://` view

### Daemon (AgentsKit)

- **Resource** `ui://agents/dashboard` in `AppViewCatalog`, always offered (not behind
  `AGENTS_TEST_VIEWS`). `_meta.ui.prefersBorder: false`, no `csp`, so the strict default applies:
  no network.
- **Feeding tool** `dashboard_view`, with visibility `["app"]` and `readOnlyHint` set. It answers
  with `structuredContent` = the whole `DashboardSnapshot` as `dashboard/get` gives it: tiles,
  order, staleness inputs, `now`, update state, up to 120 points per number tile, keepers, keeper
  changes and the pins list. Its `content` is one line of text. The view only ever reads from
  this tool.
- **`read_dashboard`** (for the model) carries `_meta.ui.resourceUri: ui://agents/dashboard`, as
  #188 asks. Its `content` text stays exactly as it is now. Its `structuredContent` is the
  **small** form (ids, titles, values, levels, stale flags, no points), because Claude Code shows
  its model the `structuredContent` *instead of* the text (#186). That form must read well on its
  own and stay small ([Q2](#open-questions)).
  - Because it has a view, a call writes an `appView` entry, through #187's `views/toolCall` path.
    `AppService`'s dashboard dispatch moves read_dashboard onto `viewToolSink`.
  - How the chat draws that entry is [Q1](#open-questions). The recommendation is a compact row,
    "Read the Dashboard" with an **Open the Dashboard** button, not the whole page inline in
    every turn that reads it.
- **App-only action tools**, visibility `["app"]`. Each is a thin wrapper over the existing
  handler, so the rules are the ones in force today:

  | Tool | Calls | Rule |
  |---|---|---|
  | `dashboard_update_now` | `updateDashboard` (`DaemonCore+DashboardUpdate.swift` L59) | 5-minute cooldown as now |
  | `dashboard_hide`, `dashboard_show` | `setTileHidden` (L275) | any tile |
  | `dashboard_remove` | `removeTileByPerson` (L312) | any tile; comes back on the keeper's next post |
  | `dashboard_arrange` | `dashboard/arrange` (L294) | whole order, `DashboardOrder.cleaned` |
  | `dashboard_page` | `readPage` for a page tile's file | read-only, 8 KB as now |

  No app-only tool sets a value. These run only from a **project** place; from a chat place they
  are refused, so an agent's inline Dashboard row cannot hide tiles on the person's behalf.
- **Live.** Nothing new in the daemon: `dashboard/changed` and `pages/changed` already reach every
  client. The client re-feeds.
- **Wire.** `DashboardSnapshot` and `TileView` stay the types the view's `structuredContent` is
  encoded from (#190 keeps them). A test pins the JSON shape the view reads, so a Swift rename
  can't break the view without a red test.

### The view itself (one HTML document)

- Source in `Web/src/appviews/dashboard/` (TypeScript and Preact, as the page is). It reuses
  `Web/src/model/dashboard.ts` (sections, summary words, staleness), `dashboardOrderSync.ts`, and
  the Markdown renderer behind `LiveDocument` for note tiles. Tile drawing is **ported from**
  `Web/src/views/Dashboard.tsx` and restyled to the spec's CSS variables only, so it themes
  through `AppViewTheme` on every client.
- **Build.** `Web/build.mjs` gains an `appviews` step that bundles each view into one
  self-contained HTML file (`Web/dist/appviews/dashboard.html`: JS and CSS inline, no external
  loads). `scripts/gen-appviews.sh` writes it into
  `Packages/AgentsKit/Sources/AgentsKit/AppViews/Generated/DashboardViewHTML.swift` as a string
  literal, checked in like `Web/dist`.
  - Not `Bundle.module`, because of the #178 trap, and because the Linux `agentsd` must serve it
    too.
  - A test, `AppViewsGeneratedTests`, checks that the literal's hash matches
    `Web/dist/appviews/MANIFEST`, as `WebDistManifestTests` does for the page.
- **Tile types:**
  - number: value, unit, good direction, trend sparkline as SVG from the points
  - status: level, line, since
  - table: up to 6×50, links as `ui/open-link`
  - note: Markdown
  - link: url, session, file or workflow
  - page: see below
- **Grey for stale**, the age words, hidden tiles shown as hidden, sections and order, and Move
  (drag within and between sections, then `dashboard_arrange`).
- **Page tiles.** The file is read with `dashboard_page` and drawn in a nested `<iframe
  sandbox="" srcdoc>`: no scripts, no network (the view's CSP applies to the srcdoc). The view's
  policy has `frame-src 'none'`. Whether WebKit and Chrome allow an `about:srcdoc` child under
  `frame-src 'none'` is the first spike, T005.
  - If either refuses it: the page tile shows its title and **Open**, which goes through the
    in-app link below to the native pinned-page reader. That reader stays, because pins of `.md`
    and `.html` are not tiles.
  - Today the web page shows page-tile HTML as escaped source in a `<pre>`. Either outcome is a
    step up there.
- **Actions in the view.**
  - Update now, Hide/Show, Remove and Move go through the app-only tools.
  - **Details** is drawn inside the view from the `TileView`: made, set, keeper, keeper changes,
    points, `changedOutside`.
  - **Open Keeper** and a link tile to a session, workflow or file need the app to navigate. The
    view asks with `ui/open-link` and an `agents://` link: `agents://session/<id>`,
    `agents://workflow/<id>`, `agents://file/<project-relative path>`. The host opens these in the
    app, and only for a view of **the app's own server**. A third party's `agents://` link is
    refused, as any non-http link is now.

### Mac (App/)

- `ContentView` shows `ProjectDashboardView` (new) in place of `DashboardPage` when
  `openDashboard` is set.
  - `ProjectDashboardView` holds a project-place `AppViewStore` and one `AppViewHost` in a
    full-page mode: no "Back to the chat", `displayMode: fullscreen`, `availableDisplayModes:
    ["fullscreen"]`.
  - It re-feeds on `AgentsModel.dashboardRevisions[folder]` and `pageRevisions` changes.
- Behind a setting until #190 (`ControlConfig`-scoped key, "Draw the Dashboard as a view"). Off by
  default until the walk; on in run-app walks.
- `AppModel.openKeeper` serves `agents://` links.

### Remote (Remote/)

- `RemoteRoute.dashboard` shows the same `ProjectDashboardView` (Shared/UI). The row
  (`DashboardRow`, summary and red dot) stays native.
- Remote talks to the daemon through the control plane, as #187's views do. The setting mirrors
  the Mac's.

### Web (Web/)

- The `{dashboard: true}` route renders `ViewPage` for `ui://agents/dashboard` through the existing
  sandbox proxy at `127.0.0.1`. It re-feeds on `dashboard/changed` in `store.ts`.
- The parity row in `specs/071-web-remote/walks/parity.md` is updated in the same branch.

### Docs

- `docs/explanation/views.md`: the project place, the host-made call, re-feeding, `agents://`
  links, and that ui/message and model context are refused outside a chat.
- `docs/reference/dashboard-tiles.md`: the view's tools.

## #189: pin a `ui://` view

### Data

`.agents/pins.json` entries gain an alternative to `path`:

```json
{"pins": [
  {"path": "docs/status.md", "pinned_by": {"person": true}},
  {"view": {"server": "agents", "uri": "ui://agents/test-view", "tool": "show_test_view",
            "arguments": {"note": "pinned"}},
   "title": "Test view", "pinned_by": {"agent": "…"}}
]}
```

- Exactly one of `path` and `view` per entry.
- `arguments` is at most 2 KB of JSON, and never holds a secret: the pin is shared through git.
- The 10-a-project limit counts both kinds. The title limit is 60, as now.
- **Before anything writes a `view` pin, every reader must tolerate it.** Today
  `PinsFile.cleaned` decodes the whole file, so an unknown entry shape could fail it. T006
  (in #188's wave) makes the decoder skip an entry it cannot read, and keep it on write, so an
  older `agentsd` on a server host, or an older Remote, sees one pin fewer and does not lose the
  file. It ships a wave before #189 writes one.

### Daemon

- `pin_page` takes `view` instead of `path`: server, uri, tool and arguments. `unpin_page` and
  `move_pin` take an index or the uri.
- The tool must exist on that server, have visibility including `app`, and carry `readOnlyHint`.
  Otherwise the call is refused with words saying why.
- `PinView` gains `view` and `missing` reasons: "server not set up here", "waiting for approval",
  "no such view". Until #191, only `server == "agents"` is ever present.
- `pinsWords` (the pins text in `read_dashboard`) names view pins too.

### Clients

- **Mac:** the sidebar's `PinnedPageRows` draws a view pin like a page pin. Opening it opens a
  project-place `AppViewHost` with the pin's feeding call.
- **Remote:** `PinnedPageCards` and `PinnedPage` do the same.
- **Web:** `Pins.tsx` does the same.
- **Pin** in the view caption's menu, inline in a chat and full screen. It is offered when the
  host knows the call's tool and that tool can feed a pin. It sends `pins/pin` with the call's
  server, uri, tool and arguments.
- **Refreshes on open** (a fresh feeding call). It stays live only for the Dashboard, through its
  own change signal. A general "this tool's result changed" push needs MCP resource subscriptions,
  out of scope here.

### Docs

`docs/explanation/views.md` gets a section "Pinning a view", which **says it is our extension of
SEP-1865**: the spec ties a view to a model's call, and a pin is the host making that call.

## #190: remove the native tile renderer

### What must be true first (the gate)

1. #188 is merged and **live** on the Mac, iPhone, iPad and web, and its walk covers every tile
   type and every action on each client, light and dark. Each walk is recorded in
   `specs/188-mcp-apps-rest/walks/` and the parity row.
   - Tile types: number with trend, status at all four levels, table with links, note with
     Markdown, link to a url, a session, a file and a workflow, page.
   - Actions: Update now, Hide, Show, Remove, Move within and between sections, Open Keeper,
     Details.
2. The view's setting has been **on by default for one wave** with nothing reported against it.
3. Performance is no worse than the native page. 60 tiles × 120 points draws on the Mac within
   074's budget (`dashboard/get` under 100 ms; page drawn under 250 ms). A test or a
   `/usr/bin/log` timing line proves it, and the result is recorded.
4. **Page tiles** work in the view (T005's answer), or open natively through `agents://file/…`.
5. Offline and errors: a Dashboard on a server host that is offline shows the same "host offline"
   state it does now. That state is drawn natively around the view, not by it.
6. The **Remote widget** (`RemoteWidget/`) reads `DashboardSummary` only, and so does the
   sessions column's row. Neither uses `TileCard` (checked: `TileCard` is used only by both
   `DashboardPage.swift` files). Both stay native.
7. A Remote one version behind (installed, not yet updated) still works against the new daemon.
   `dashboard/get`, `/hide`, `/show`, `/remove`, `/arrange` and `/update` stay on the wire. #190
   removes UI, not methods ([Q9](#open-questions)).

### What goes

- **Shared:** `Shared/UI/Dashboard/TileCard.swift` (251 lines, with `Sparkline`).
- **Mac:**
  - `App/Sources/Dashboard/DashboardPage.swift` (391): its grid, menu, Move items, drag and details
    sheet.
  - `PageTileBody` in `App/Sources/Dashboard/PinnedPage.swift`. **`PinnedPage` itself stays**: it
    is the `.md` and `.html` pin reader.
  - In `AppModel`: `actOnTile`, `arrangeDashboard` and the native-only parts of
    `refreshDashboard`. `updateDashboard` stays if the view's Update now still goes through it.
- **Remote:**
  - `DashboardPage` in `Remote/Sources/Dashboard/DashboardPage.swift`. **`DashboardRow` stays.**
  - `PageTileBody` in `Remote/Sources/Dashboard/PinnedPage.swift`.
- **Web:**
  - `Tile`, `Value`, `PageValue`, `TileDetail`, `DashboardPage` and `UpdateNow` in
    `Web/src/views/Dashboard.tsx`. **`DashboardRow` stays.**
  - `app.css` tile rules.
  - What only the page used in `model/dashboard.ts`. The view bundle keeps its copy (it imports
    the module).
- **Settings:** the "Draw the Dashboard as a view" setting and its key, read once and removed.

### Data migration

**None of the data moves.** The view reads the same store through the same handlers:

- Tile files (`.agents/dashboard/<id>.json`, `hidden` included), `_order.json`,
  `history/<id>.jsonl`, the host's `dashboards/<key>/state.json` and the points are untouched.
  Keepers, `take_over`, staleness and limits are unchanged.
- `.agents/pins.json` page pins are untouched. View pins (from #189) are unaffected.
- **One clean-up:** if a person pinned `ui://agents/dashboard` itself (possible after #189), it
  duplicates the Dashboard row. On read, the daemon drops that pin from `pinViews` (not from the
  file), and `pin_page` refuses it with "The Dashboard is already in the sessions column."
- **The setting's key:** remove it from the window's defaults, the `.store` container's plist
  included (memory: scratch copies share defaults).
- **Docs:**
  - `docs/how-to/keep-a-project-dashboard.md` describes the view.
  - `docs/reference/dashboard-tiles.md` keeps the data model and adds the view's tools.
  - The parity row says "by design: one renderer, the view".

## #191: third-party servers' views

### How the app connects

- **Where.** On the host that runs the project. A server project's connection runs in the Linux
  `agentsd`, where its `mcp.json`, approvals and `secrets.env` already live (058). Clients never
  connect to a third-party server. They go through `views/*` as now, routed by the control plane.
- **What.** A new `MCPClient` in `Packages/AgentsKit/Sources/AgentsKit/MCP/`:
  - **stdio:** start our own copy of the server, through `RouteProcess`'s spawning logic, moved
    out of `MCPBridge` into a portable `MCPStdioProcess`. `MCPBridge` is `#if
    canImport(Network)`, so it is not on Linux. The copy uses the same scrubbed
    `RuntimeEnvironment.forRuntimes()`, the server's env, cwd = the project folder, and stderr
    discarded.
    - The runtime's copy cannot be reached over ACP (#191), so it cannot be shared.
    - One exception worth measuring later: Copilot's stdio servers already run inside
      `MCPBridge`, which could multiplex our ids onto that process. Not in scope.
  - **http / streamable-http:** a second client session (its own `Mcp-Session-Id`), through
    `URLSession` (`FoundationNetworking` on Linux). It sends the configured headers.
  - **sse** (the old transport): not supported for views. The server's views show as "this
    server's transport can't show views".
- **Handshake.** `initialize` with `capabilities.extensions["io.modelcontextprotocol/ui"] =
  {"mimeTypes": ["text/html;profile=mcp-app"]}`, then `tools/list` and `resources/list`. It
  tolerates `-32601` on anything optional. It sends nothing before `initialize` (#186 saw clients
  send `server/discover`; we don't).
- **Lifecycle (bounded, per the "bound data" rule).**
  - Started on demand: the first time a view of that server is drawn, a pin of it is opened, or a
    chat sees its tool called and the catalog has no entry yet.
  - Kept while a view of it is open, and ended **2 minutes** after the last one closes.
  - **At most 4 clients per host** (least recently used ended first).
  - At most one start in flight per server.
  - A `tools/call` from a view times out after 60 s.
  - An HTTP server's session is dropped on idle too.
- **Catalog.** A per-server `ServerViewCatalog`: tools with `_meta.ui.resourceUri` (or the flat
  `ui/resourceUri`), their visibility and `readOnlyHint`, and the `ui://` resources. It is cached
  on the host under `<root>/mcp-views/<key>.json`, keyed by the server's **entry digest** (the
  one `MCPApprovals` already computes), so a changed entry is a new catalog. Detection in a chat
  needs only the cache, not a live connection.
- **Secrets.** `SecretsEnv.filled(server)` as for sessions. A server with a missing secret has no
  views, and its pin says so. **Nothing about a server is logged** (054 FR-023). The log may
  have the server's name, a `ui://` uri, the view's policy line and lifecycle words (started,
  ended, refused). Never a command, argument, env value, header, URL or body.

### Trust and policy

- **Approval.** A view never comes from a server that is waiting for approval (project servers,
  `MCPApprovals.status`). Plugin servers follow `PluginApprovalStore` as for sessions.
- **Review the template.** The spec advises that the person see a view's template before it runs.
  On the first draw of a server's views, the daemon hashes every `ui://` resource it serves
  (SHA-256 over uri, mimeType, text and `_meta.ui`) and keeps the hashes beside the approvals
  (`<root>/mcp-approvals.json` gains `views`). A new or changed hash asks once, in the view's
  place: "\<server\> wants to show a view here", with **Show** and **Don't Show**. The Mac also
  gets a row in `ProjectMCPSection`. Personal servers ask too ([Q6](#open-questions)). The answer
  is kept per server and resource hash, so a server that changes its HTML asks again.
- **Policy.** Each view is drawn under `AppViewPolicy(csp: resource._meta.ui.csp)`, unchanged from
  #187: undeclared domains blocked, plain origins only, `frame-src 'none'` unless declared,
  `object-src 'none'`, `form-action 'none'`. On the web, the proxy's policy-in-the-address
  carries it as now. The daemon logs each server's view policy on read, as now.
- **Tool calls from a view.**
  - `views/call` names `server`. The daemon passes it through only if the server is the same one
    whose view it is (the `AppViewCall.server` the host holds, not anything the view says) and
    the cached catalog says visibility includes `app`.
  - A view of server A asking for server B's tool, or for any `agents` tool, is refused and
    logged.
  - A tool only a view may call (visibility `["app"]`) is one the runtime *also* sees, since the
    runtime lists the server's tools itself and no runtime filters by visibility (#186). That
    can't be fixed from the app's side. It goes in the docs as a known limit.
- **`resources/read` from a view:** the same server only.
- **`agents://` links:** refused for third-party views.
- **`ui/message`:** asks the person, as #187 does. **`ui/update-model-context`:** as #187, named
  with the server.

### Which runtimes show a third party's view in the chat (#186)

The daemon writes the `appView` entry from ACP for a third-party tool. It does so by **shape**,
not by runtime name (constitution II):

| What ACP gives | How the server and tool are found | `tool-result` from | Runtimes seen with it |
|---|---|---|---|
| `rawInput.server` + `rawInput.tool` | exactly | `rawOutput.result`, whole | Codex |
| `_meta.claudeCode.toolName` `mcp__<s>__<t>` | exactly | `rawOutput` JSON string, parsed as `structuredContent`; no text, no `_meta` | Claude |
| a title `<s>-<t>` or `<s>_<t>` | longest server name in the session's own `mcpServers` that prefixes the title and owns the tool in the catalog | `rawOutput.structuredContent` + `contents` text, if present | Copilot (`-`); OpenCode (`_`) |
| text only | as above | none usable | OpenCode |

Inline in the chat: **Codex, Copilot, Claude** (Claude's view gets no `content` text and no
`_meta`). **OpenCode: pinned only** ([Q7](#open-questions)). A runtime not in the pool (Grok,
Cursor, Gemini, Antigravity) gets the same shape rules when it returns. `assess-runtime` gains a
step to check it.

The app **never calls a model's tool again** to get its result.

### Clients

The renderer and bridge are unchanged. The caption shows the server's name, and the permission
prompt for "Show" sits in the view's place. Pins of third-party views work through #189 and show
as missing per host.

### Done when (from #191)

An ext-apps example server (`basic-server-vanillajs`, through `npx` in a project `mcp.json`)
shows its view in a Codex turn and as a pin, on the Mac, Remote and web. Its undeclared domain is
blocked. Its app-only tool can't be reached from the test view's frame (`views/call` with
`server: other` is refused).

## Risks

| Risk | Where | Mitigation |
|---|---|---|
| Claude shows its model `structuredContent` in place of the text (#186), so a big `read_dashboard` result costs tokens on every read | #188 | small `structuredContent` (no points); full snapshot only from the app-only `dashboard_view` ([Q2](#open-questions)) |
| An agent's every `read_dashboard` draws a whole Dashboard inline | #188 | compact row with Open ([Q1](#open-questions)) |
| A nested srcdoc frame for page tiles is blocked by `frame-src 'none'` on WebKit or Chrome | #188, #190 gate | spike T005 first; fall back to opening natively |
| The view bundle drifts from `Web/src` or from the Swift literal | #188 | generated literal + manifest test; `scripts/web.sh check` rebuilds both |
| `Bundle.module` trap (#178) if the HTML were a resource | #188 | string literal, not a resource |
| Visual parity: native tiles are SwiftUI; the view is HTML in a web view (fonts, Dynamic Type on iOS, VoiceOver) | #188, #190 | theme variables + `-apple-system`; an accessibility check in the walk (VoiceOver reads each tile); Larger Text on iPhone |
| A WKWebView per project page costs memory on the iPhone | #188 | one view per project page, torn down on leave; measured in the walk |
| An older Remote or server-host `agentsd` fails to read `pins.json` with a view pin | #189 | lenient decoder shipped a wave before (T006) |
| A pin re-runs a tool on every open, and tools can have side effects | #189, #191 | feeding tool must be `app`-visible and `readOnlyHint`; refused otherwise |
| A second copy of a stdio server has side effects (locks, ports, OAuth prompts, duplicate work) | #191 | started only on demand, bounded, ended on idle; Show/Don't Show before the first view; [Q5](#open-questions) |
| The second process runs unsandboxed (064 sandboxes only runtimes' commands) | #191 | same env scrubbing as the bridge; recorded as a known limit; [Q5](#open-questions) |
| Title parsing for Copilot and OpenCode is ambiguous | #191 | resolve only against the session's own server names and the catalog's tools; no match = no view, never a guess |
| App-only tools of a third party are visible to the model anyway (no runtime filters) | #191 | documented limit; nothing the app can do |
| Logging a server's secrets (FR-023) | #191 | log names, uris, policy lines only; a sentinel test, as 054's |
| Web proxy origin: the proxy is at `127.0.0.1` beside `localhost`; behind the cloud control plane (#61) the page is not on loopback | all | a second hostname for the proxy on the cloud plane; out of scope here, noted for #61 |
| Merge order: #187 is not on main yet | all | nothing starts before #187's wave lands |

## Constitution check

- **I (spec-led):** spec, plan and tasks are here.
- **II (capability-driven):** we advertise `io.modelcontextprotocol/ui`, and ACP is read by shape,
  not runtime name.
- **III (scoped access):** project places check the caller's grant; a view reaches only its own
  server; approvals gate third parties.
- **IV (inspectable):** views and calls are on the record; policies and refusals are logged.
- **V (docs):** listed per issue.

No deviation.

## Open questions

For Alex. Claude (MCP Apps plan) has put a recommendation first in each. None blocks #188's first
tasks (T001–T010).

1. **`read_dashboard` in a chat.** It gets a view, so an agent's read draws something. Alex,
   should it be **(a) a compact row, "Read the Dashboard", with Open** (recommended), (b) the
   whole Dashboard inline, or (c) nothing?
2. **Trends out of `read_dashboard`'s `structuredContent`.** Alex, keep the points out of what the
   model sees (recommended; the view gets them from the app-only `dashboard_view`), or accept the
   extra tokens on Claude?
3. **`ui/message` and model context from a project place** (Dashboard, pins). There is no agent to
   tell. Alex, **refuse them** (recommended for now), or offer "Start an agent with this"?
4. **#189 before #191.** Until third-party views, the only pinnable views are the test view (and
   the Dashboard, which is already a row). Alex, **build #189 now on the test view** (recommended:
   the mechanism is #188's and is cheap), or fold it into #191?
5. **A second copy of a stdio server** for views. Alex, is starting our own copy acceptable, gated
   by **Show / Don't Show per server** (recommended), or should #191 cover HTTP servers only at
   first?
6. **Personal servers and Show / Don't Show.** Personal servers skip run approval today. Alex,
   should the view prompt apply to them too (recommended: yes, it is about HTML, not running)?
7. **OpenCode** gives only text. Alex, **pinned only** (recommended) or inline with the text alone?
8. **Page tiles if the nested frame is blocked.** Alex, is opening them in the native reader
   acceptable (recommended), or should #190 wait until they draw inside the view?
9. **How long the old wire stays.** Alex, keep `dashboard/get` and its siblings indefinitely,
   since the view's data uses them anyway (recommended), or remove them once every Remote has
   updated?
