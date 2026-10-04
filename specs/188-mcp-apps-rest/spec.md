# Feature Specification: MCP Apps, the rest

**Feature Branch**: `agents/build-free-planning-rest`
**Created**: 2026-10-04
**Status**: Planned, not built
**Issues**: #188, #189, #190, #191. This follows #187 (the host) and #186 (the probe).

The issues hold the full text. This file lists the stories and the criteria the tasks are
checked against. The design is in [plan.md](plan.md).

## User stories

### US1: The Dashboard as a view (#188), P1

A person opens a project's Dashboard on the Mac, iPhone, iPad or web, and sees it drawn as
`ui://agents/dashboard` from the app's own server. It is the same tiles, actions and live updates
as today.

**Independent test:** on a scratch root with the view setting on, seed one tile of each type
(number with trend, status at each level, table, note, link, page). Then check, on each client:

- each tile draws, and stale tiles are grey;
- Update now, Hide, Show, Remove, Move, Open Keeper and Details work;
- a keeper's `set_tile` shows in the open view within 2 s, with no reload;
- `example.com` stays blocked.

**Acceptance:**

1. The data model and the tools `set_tile`, `remove_tile`, `read_dashboard` and `move_tile` are
   unchanged for agents and workflows. `read_dashboard`'s text is byte-identical to today's.
2. `read_dashboard` carries `_meta.ui.resourceUri`. Its `structuredContent` holds no points.
3. A person can hide and remove any tile from the view, and can never set a value. An app-only
   Dashboard tool called from a chat's view is refused.
4. The view has no network: the strict default policy, with nothing declared.

### US2: Pin a view (#189), P2

A person or an agent pins a `ui://` view under a project. Opening the pin makes the view's feeding
call and draws the view.

**Independent test:** pin the test view from its caption menu in a chat. It appears in the
sidebar on the Mac, the Remote and the web. Opening it draws it with the pinned arguments. Then
check:

- `pin_page` with `view` works from an agent;
- the 11th pin is refused;
- an older daemon reading the file skips the view pin and keeps it.

**Acceptance:**

1. View pins live in `.agents/pins.json` beside page pins. The limit is 10 pins a project, both
   kinds counted together.
2. Only a tool whose visibility includes `app` and which has `readOnlyHint` can feed a pin.
3. A pin of a server that is not set up or approved here shows as missing, with the reason.
4. The docs call it an extension of SEP-1865.

### US3: One Dashboard renderer (#190), P3

Once US1 has been walked on every client, the native tile views are removed.

**Independent test:** `swift test` and the web build pass. Searching for `TileCard` and for
`DashboardPage(` finds nothing. Existing tiles, order, history and pins draw unchanged in the
view.

**Acceptance:** every condition on the gate list in plan.md §#190 is met before the removal
merges. Nothing in the data moves.

### US4: Third-party servers' views (#191), P4

A view from a third-party MCP server, configured in `mcp.json`, a plugin or the marketplace,
draws in an agent's turn and as a pin.

**Independent test:** an ext-apps example server in a project's `mcp.json`, called by a Codex
agent:

- after Show, it draws inline on the Mac, the Remote and the web;
- it draws as a pin;
- its undeclared domain is blocked;
- its app-only tool can't be called from another server's view;
- nothing about the server's command, env or headers is in the daemon log.

**Acceptance:**

1. No view is drawn from a server waiting for approval.
2. A new or changed `ui://` resource asks Show / Don't Show once.
3. The app's connection advertises `io.modelcontextprotocol/ui`.
4. It runs on the host that runs the project.
5. It is bounded: at most 4 clients a host, and each is ended 2 minutes after its last view
   closes.

## Docs

- `docs/explanation/views.md`: US1, US2 and US4.
- `docs/reference/dashboard-tiles.md`: US1.
- `docs/how-to/keep-a-project-dashboard.md`: US3.
- `specs/071-web-remote/walks/parity.md`: all four stories.
