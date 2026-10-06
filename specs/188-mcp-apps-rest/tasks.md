# Tasks: MCP Apps, the rest (#188, #189, #190, #191)

**Input**: [plan.md](plan.md), [spec.md](spec.md); #187 at `324ee04d`; #186 note
`specs/research/186-mcp-apps-acp-probe.md`.

**Prerequisite for every task**: #187 is merged to main.

**Tests**: the repo's quality gates apply (Swift Testing in `Packages/AgentsKit`; `scripts/web.sh
check`), so the tasks below include their unit tests. Walks go through the run-app skill and
`Web/test/walk/`.

Paths are relative to the repo root. `AK` is `Packages/AgentsKit/Sources/AgentsKit` and `AKC` is
`Packages/AgentsKit/Sources/AgentsKitCore`.

## Format: `[ID] [P?] [Story] Description`

## Phase 1: Setup

- [ ] T001 Add an `appviews` step to `Web/build.mjs` that bundles each `Web/src/appviews/<name>/index.tsx` into one self-contained `Web/dist/appviews/<name>.html` (JS and CSS inline, no external loads) and lists their hashes in `Web/dist/appviews/MANIFEST`
- [ ] T002 Write `scripts/gen-appviews.sh` to turn each `Web/dist/appviews/*.html` into a string literal in `AK/AppViews/Generated/<Name>ViewHTML.swift` (generated header, no `Bundle.module`), and run it from `scripts/web.sh build`
- [ ] T003 [P] Add `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AppViewsGeneratedTests.swift` checking that each generated literal's SHA-256 equals its `Web/dist/appviews/MANIFEST` line

---

## Phase 2: Foundational (blocks US1–US4)

- [ ] T004 Add `ViewPlace` (`agent(UUID)` | `project(folder:)`) to `AKC/AppViews/AppViewsWire.swift`. `ViewReadRequest`, `ViewCallRequest`, `ViewLogRequest` and `ViewContextRequest` keep `agentID` and gain an optional `project` (exactly one set) and an optional `feed: Bool` on `ViewCallRequest`. Regenerate `Web/src/protocol/generated.ts`
- [ ] T005 [P] Spike, no app change: in a scratch HTML under `/tmp`, check whether an `<iframe sandbox="" srcdoc>` child draws under a parent CSP of `frame-src 'none'` in WKWebView (Mac) and in Chrome. Write the answer in `specs/188-mcp-apps-rest/research.md` (decides the page-tile path in T016)
- [x] T006 [P] Make `PinsFile` decoding in `AKC/Pins/Pins.swift` skip an entry it cannot read, and keep that entry's raw JSON on rewrite. Test in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/PinsTests.swift`: a file with an unknown `{"view":…}` entry keeps it and lists the others. Ships a wave before T030
- [ ] T007 In `AK/AppViews/DaemonCore+AppViews.swift`, resolve a project place:
  - `readView` and `callFromView` accept `project` and check the caller's grant for the folder;
  - `keepViewContext` and `ui/message` from a project place are refused with `viewRefused` and logged;
  - `feed: true` is allowed only for a tool with visibility `app` and `annotations.readOnlyHint == true`.

  Route the change through `AK/Daemon/DaemonCore+Dispatch.swift`.
- [ ] T008 [P] Add "a newer result" to `AppViewFeed` in `AKC/AppViews/AppViewBridge.swift`: a second done result with a different value re-sends `ui/notifications/tool-result`. Mirror it in `Web/src/views/chat/appViewBridge.ts`, with tests in `Tests/AgentsKitTests/Unit/AppViewTests.swift` and `Web/test/appViews.test.mjs`
- [ ] T009 Add a project-place `AppViewStore` in `Shared/UI/AppView/AppViewHost.swift`: `AppViewActions` carries a `ViewPlace`, holds one host-made `AppViewCall`, and gains a full-page mode (no Back to the chat, `availableDisplayModes: ["fullscreen"]`). Add a `refeed()` that calls `views/call` with `feed: true` and passes the answer to `update(_:)`
- [ ] T010 [P] Give `ViewLayer` in `Web/src/views/chat/viewLayer.ts` a page slot, and add `Web/src/views/page/ViewPage.tsx` to draw one project-place view through the sandbox proxy, with `refeed()`
- [ ] T011 Serve `agents://session/<id>`, `agents://workflow/<id>` and `agents://file/<path>` from `ui/open-link`, for views of the `agents` server only:
  - Mac: `App/Sources/AppModel.swift` (`openKeeper` and friends)
  - Remote: `Remote/Sources/RemoteModel.swift`
  - Web: `Web/src/views/chat/appViewBridge.ts` and `route.ts`

  Any other server's `agents://` link is refused.

**Checkpoint**: a project-place view can be drawn and re-fed on all three clients.

---

## Phase 3: US1, the Dashboard as a view (#188), P1 🎯 MVP

**Goal**: `ui://agents/dashboard` replaces the native page behind a setting, with the same tiles,
actions and live updates.

**Independent test**: spec.md US1.

- [ ] T012 [US1] Add the resource `ui://agents/dashboard` (no `csp`, `prefersBorder: false`), always offered, to `AK/AppViews/AppViewCatalog.swift`, with its HTML from `Generated/DashboardViewHTML.swift`
- [ ] T013 [US1] Add these tools to `AppViewCatalog` and answer them in `AK/AppViews/DaemonCore+AppViews.swift` by calling the existing handlers in `AK/Dashboard/`. All are visibility `["app"]`, and all are refused from a chat place:
  - `dashboard_view` (`readOnlyHint`; `structuredContent` = the full `DashboardSnapshot`)
  - `dashboard_update_now`
  - `dashboard_hide` and `dashboard_show`
  - `dashboard_remove`
  - `dashboard_arrange`
  - `dashboard_page` (`readOnlyHint`)
- [ ] T014 [US1] Give `read_dashboard` in `AK/ACP/Serve/AppService+Dashboard.swift` `_meta.ui.resourceUri: ui://agents/dashboard`, and route it through `viewToolSink`. Its `content` text stays byte-identical. Its `structuredContent` is the small form: ids, titles, values, levels, stale flags, **no points**. Test that the text is unchanged and that no points appear, in `Tests/AgentsKitTests/Unit/DashboardToolTests.swift`
- [ ] T015 [P] [US1] Add a test fixing the JSON shape of `DashboardSnapshot`/`TileView` as the view reads it, in `Tests/AgentsKitTests/Unit/DashboardViewShapeTests.swift`, with a matching fixture `Web/test/fixtures/dashboard-snapshot.json`
- [ ] T016 [US1] Write the view in `Web/src/appviews/dashboard/`:
  - `index.tsx`, `Tile.tsx`, `Details.tsx`, `dashboard.css`, using the spec's CSS variables only;
  - reuse `Web/src/model/dashboard.ts`, `dashboardOrderSync.ts` and the Markdown renderer;
  - draw number (SVG sparkline), status, table, note, link and page (per T005: a srcdoc frame, or Open through `agents://file`);
  - grey for stale, hidden, sections and Move by drag;
  - Update now, Hide/Show, Remove, Open Keeper and Details.
- [ ] T017 [P] [US1] Add web unit tests for the view's tile drawing and actions in `Web/test/dashboardView.test.mjs`, against the T015 fixture
- [ ] T018 [US1] Mac: add `App/Sources/Dashboard/ProjectDashboardView.swift`, which holds a project-place store, re-feeds on `dashboardRevisions` and `pageRevisions`, and draws the "host offline" state natively. Show it from `App/Sources/ContentView.swift` when `openDashboard` is set and the `ControlConfig`-scoped setting "Draw the Dashboard as a view" is on
- [ ] T019 [P] [US1] Remote: show `ProjectDashboardView` (moved to `Shared/UI/Dashboard/` if both apps can share it) for `RemoteRoute.dashboard` in `Remote/Sources/RemoteApp.swift`, behind the same setting. `DashboardRow` is unchanged
- [ ] T020 [P] [US1] Web: render `ViewPage` for `ui://agents/dashboard` on the `{dashboard: true}` route in `Web/src/views/Dashboard.tsx`, re-fed from the `dashboard/changed` handler in `Web/src/store.ts`, behind a page setting
- [ ] T021 [US1] Show the compact row for a `read_dashboard` `appView` entry (per Q1) in `Shared/UI/AppView/AppViewRow.swift` and `Web/src/views/chat/AppView.tsx`: "Read the Dashboard", with Open
- [ ] T022 [US1] Update the docs: in `docs/explanation/views.md`, the project place, host-made call, re-feeding, `agents://` links and refusals outside a chat; in `docs/reference/dashboard-tiles.md`, the view's tools
- [ ] T023 [US1] Walk each tile type and each action, light and dark, on the Mac (run-app), the iPhone and iPad (Alex's look), and web Chrome and Safari (`Web/test/walk/dashboardView.mjs`). Include VoiceOver on one tile of each type, and the 60-tile timing. Put the shots in `specs/188-mcp-apps-rest/walks/` and update the row in `specs/071-web-remote/walks/parity.md`

**Checkpoint**: US1 is complete behind its setting. Turn the setting on by default for one wave (gate item 2 of #190).

---

## Phase 4: US2, pin a view (#189), P2

**Goal**: a `ui://` view pinned under a project, opened by a feeding call.

**Independent test**: spec.md US2.

- [x] T024 [US2] Add a `view` entry to `AKC/Pins/Pins.swift`: `{server, uri, tool, arguments ≤ 2 KB}`, with exactly one of `path`/`view`, "at most 10 pins a project, both kinds counted", and a title of at most 60 characters. `PinView` gains `view` and the missing reasons "server not set up here", "waiting for approval" and "no such view"
- [x] T025 [US2] Make `pin_page`, `unpin_page` and `move_pin` take `view` in `AK/ACP/Serve/AppService+Dashboard.swift` (schemas) and `AK/Pins/DaemonCore+Pins.swift`. Refuse a tool that is not `app`-visible or lacks `readOnlyHint`, and refuse `ui://agents/dashboard`. `pinsWords` names view pins
- [x] T026 [P] [US2] Add tests in `Tests/AgentsKitTests/Unit/PinsTests.swift`: a view pin round-trips, the 11th pin is refused, a non-read-only tool is refused, the Dashboard pin is refused, a missing server is reported
- [x] T027 [US2] Open a view pin on the Mac: draw it in `App/Sources/Projects/PinnedPageRows.swift`, and open it with a project-place host for the pin's call from `App/Sources/Dashboard/PinnedPage.swift`
- [x] T028 [P] [US2] Do the same on the Remote: `Remote/Sources/Dashboard/PinnedPage.swift` (`PinnedPageCards`, `PinnedPage`)
- [x] T029 [P] [US2] Do the same on the web: `Web/src/views/Pins.tsx` and `ViewPage`
- [x] T030 [US2] Add **Pin** to the view caption's menu, inline and full screen, when the call's tool can feed a pin: `Shared/UI/AppView/AppViewRow.swift` and `Web/src/views/chat/AppView.tsx`, sending `pins/pin` with the view. Requires T006 to be live
- [x] T031 [US2] Add "Pinning a view (our extension of SEP-1865)" to `docs/explanation/views.md`, and the pin row to `specs/071-web-remote/walks/parity.md`
- [ ] T032 [US2] Walk it: pin the test view from a chat, open it on the Mac, the Remote and the web, see it missing on a root without the test view, and unpin it

---

## Phase 5: US3, one Dashboard renderer (#190), P3

**Goal**: no native tile views. **Starts only when every item of plan.md's #190 gate is
recorded as met.** It can run beside Phase 4.

**Independent test**: spec.md US3.

- [ ] T033 [US3] Record each gate item with its evidence (walk shots, wave, timings, T005 answer, offline state, Remote one version behind) in `specs/188-mcp-apps-rest/walks/190-gate.md`
- [ ] T034 [US3] Mac: remove the native page in `App/Sources/Dashboard/DashboardPage.swift`, and `PageTileBody` from `App/Sources/Dashboard/PinnedPage.swift` (keep `PinnedPage`). Remove `actOnTile` and `arrangeDashboard` from `App/Sources/AppModel.swift`. `ContentView` always shows `ProjectDashboardView`
- [ ] T035 [P] [US3] Remove `Shared/UI/Dashboard/TileCard.swift` (with `Sparkline`)
- [ ] T036 [P] [US3] Remote: remove `DashboardPage` from `Remote/Sources/Dashboard/DashboardPage.swift` (keep `DashboardRow`), and `PageTileBody` from `Remote/Sources/Dashboard/PinnedPage.swift`
- [ ] T037 [P] [US3] Web: remove `DashboardPage`, `UpdateNow`, `Tile`, `Value`, `PageValue` and `TileDetail` from `Web/src/views/Dashboard.tsx` (keep `DashboardRow`). Remove the tile rules from `Web/src/app.css`, and what only they used from `Web/src/model/dashboard.ts`
- [ ] T038 [US3] Remove the "Draw the Dashboard as a view" setting from the Mac, the Remote and the web, and clear its key from the window's defaults (`.store` container included). Keep every `dashboard/*` wire method (Q9)
- [ ] T039 [US3] Update the docs: `docs/how-to/keep-a-project-dashboard.md` describes the view; in `specs/071-web-remote/walks/parity.md`, "by design: one renderer, the view"
- [ ] T040 [US3] Verify: `swift test` and `scripts/web.sh check` pass, and searching for `TileCard` and `DashboardPage(` finds nothing. Existing tiles, order, history and pins draw unchanged on a seeded root

---

## Phase 6: US4, third-party servers' views (#191), P4

**Goal**: views from servers in `mcp.json`, plugins and the marketplace, in the chat and as pins.

**Independent test**: spec.md US4.

T041–T046 are daemon-only groundwork. They can start early in a lane of their own.

- [x] T041 [P] [US4] Move `RouteProcess`'s spawning out of `AK/MCP/MCPBridge.swift` into a portable `AK/MCP/MCPStdioProcess.swift` (Linux too: no `Network`), with the same scrubbed `RuntimeEnvironment.forRuntimes()`, the server's env, cwd and stderr discarded. `MCPBridge` uses it
- [x] T042 [US4] Add `AK/MCP/MCPClient.swift` with stdio (through `MCPStdioProcess`) and streamable HTTP (`URLSession`, its own `Mcp-Session-Id`, the configured headers). `initialize` advertises `extensions["io.modelcontextprotocol/ui"] = {mimeTypes: ["text/html;profile=mcp-app"]}`; then `tools/list`, `resources/list`, `resources/read` and `tools/call` (60 s timeout). `-32601` on optional methods is tolerated. sse is refused for views
- [ ] T043 [US4] Add `AK/MCP/MCPClientPool.swift`, on the host that runs the project:
  - at most 4 clients a host, least recently used ended first;
  - one start in flight per server;
  - each ended 2 minutes after its last view closes;
  - secrets filled by `SecretsEnv.filled`;
  - no view from a server waiting under `MCPApprovals`, or under `PluginApprovalStore`.
- [ ] T044 [US4] Add `AK/MCP/ServerViewCatalog.swift`, cached at `<root>/mcp-views/<entry digest>.json`: tools with `_meta.ui.resourceUri` or `ui/resourceUri`, their visibility and `readOnlyHint`, and the resources
- [ ] T045 [P] [US4] Add `AKC/AppViews/ACPToolShape.swift`, which finds the (server, tool, result) of an ACP tool call by shape:
  - `rawInput.server`/`tool`;
  - `_meta.claudeCode.toolName` `mcp__s__t`;
  - a title `s-t`/`s_t`, resolved against the session's own `mcpServers` and the catalog (no match means no view);
  - the result from `rawOutput.result`, from `rawOutput.structuredContent`/`contents`, or from a JSON-string `rawOutput`.

  Tests in `Tests/AgentsKitTests/Unit/ACPToolShapeTests.swift`, built from the #186 wire logs in `specs/research/186-mcp-apps-acp-probe/`
- [x] T046 [P] [US4] Add a sentinel test in `Tests/AgentsKitTests/Unit/MCPClientLoggingTests.swift`: a server whose command, args, env, headers and URL hold a sentinel, driven through connect, read, call and end, leaves no sentinel in the daemon log (054 FR-023)
- [ ] T047 [US4] Review the template: hash each server's `ui://` resources (uri, mimeType, text, `_meta.ui`) into a `views` section of `<root>/mcp-approvals.json`, in `AK/Catalog/MCPApprovals.swift`. A new or changed hash makes `views/read` answer "needs Show" until the person answers. Personal servers are included (Q6)
- [ ] T048 [US4] Give `views/read`, `views/call` and `views/log` a `server` in `AKC/AppViews/AppViewsWire.swift` and `AK/AppViews/DaemonCore+AppViews.swift`. `views/call` is passed through only when the server is the held `AppViewCall.server` and the catalog says `app`; a cross-server or `agents` tool from a third-party view is refused and logged. `resources/read` is same-server only. Each policy is logged on read
- [ ] T049 [US4] Write `appView` entries for third-party calls in the ACP update path (`AK/ACP/ACPSession.swift`, the tool_call and tool_call_update handling) through `ACPToolShape`, only when the catalog says the tool has a view. A text-only result is pinned only (Q7). A model's tool is never called again
- [ ] T050 [US4] Clients: the caption shows the server's name, and Show / Don't Show is drawn in the view's place:
  - `Shared/UI/AppView/AppViewRow.swift`
  - `Web/src/views/chat/AppView.tsx`
  - a Mac row in `App/Sources/Projects/ProjectMCPSection.swift`
- [ ] T051 [US4] Pins of third-party views: lift the `server == "agents"` limit in `AK/Pins/DaemonCore+Pins.swift`, and give missing reasons per host
- [ ] T052 [US4] Add a step to `.agents/skills/assess-runtime/` that checks a runtime's ACP shape for a third-party tool with a view
- [ ] T053 [US4] Update the docs: in `docs/explanation/views.md`, third-party views (where the connection runs, approval and Show, policy, which runtimes inline, the known limit on app-only visibility). Update the parity row
- [ ] T054 [US4] Walk it with an ext-apps example (`basic-server-vanillajs` through `npx` in a project's `mcp.json`) and a Codex agent: Show, inline on the Mac, the Remote and the web, as a pin, its undeclared domain blocked, a cross-server call refused, and a log free of the server's values

---

## Phase 7: Polish

- [ ] T055 [P] Add a row per new limit (4 clients, 2 min idle, 2 KB pin arguments, 60 s call) to the performance budget table in `docs/`
- [ ] T056 Run `speckit-analyze` over spec.md, plan.md and tasks.md after Alex's answers, and fold the answers in

---

## Dependencies

- Phase 1 → Phase 2 → US1. **US1 is the base for everything.**
- US2 depends on Phase 2 (project place) and T006 being live a wave earlier. It does not need US1's view.
- US3 depends on US1 being walked, defaulted on for a wave, and the gate recorded (T033). It can run beside US2: the files are disjoint.
- US4's groundwork (T041–T046) depends only on #187 and can start any time. T047–T054 need Phase 2. T051 needs US2.

## Parallel examples

- After T004: T005, T006, T008 and T010 together.
- US1: T015 and T017 beside T016. T019 and T020 beside T018.
- US3: T035, T036 and T037 together after T034.
- US4: T041, T045 and T046 together, as one daemon lane, while US1 is built.

## Implementation strategy

1. **MVP = Phases 1–3 (US1)** behind a setting, walked, then defaulted on.
2. US2 and US4 groundwork in parallel lanes. Then US3 once its gate is met.
3. US4's client half last.

Each phase is one lane and one merge-wave entry. Each commit says what the web page does (#233).
