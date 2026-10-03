# Tasks: Project Dashboard, slice 1

**Input**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: asked for by the research's proof list (§7): keepers, atomic writes under concurrent
posts, a worktree agent writing the project folder, unchanged values, outside edits, limits,
compaction, downsampling.

**Order**: the look first (Phase 2), as Alex asked, then depth.

## Phase 1: Setup

- [X] T001 Create `Packages/AgentsKit/Sources/AgentsKitCore/Dashboard/` and `Packages/AgentsKit/Sources/AgentsKit/Dashboard/`, `App/Sources/Dashboard/`, `Remote/Sources/Dashboard/`; run `xcodegen generate` so the app targets pick the folders up (`project.yml` globs)

## Phase 2: Foundational — wire types and the look

- [X] T002 [P] `TileFile`, `TileType`, `TileValue` (number `value` finite, `unit` ≤ 12, `good` up/down; status `level` ok/warn/bad/unknown, `line` ≤ 200, `since` ≤ 40; table `columns` 1–6, `rows` ≤ 50, cell ≤ 200 characters, cell string or `{text,url}`; note `markdown` ≤ 4096 bytes; link `title` + one of `url`/`session`/`file`/`workflow`), `TileKeeper` (`{"agent"}`/`{"workflow"}`), canonical encoding (sorted keys, 2-space indent, trailing newline) in `Packages/AgentsKit/Sources/AgentsKitCore/Dashboard/Tile.swift`
- [X] T003 [P] `DaemonAPI.Method.dashboard*`, `Notification.dashboardChanged`, `Failure.dashboardRefused` (-32060), `DashboardSnapshot`, `TileView`, `KeeperView`, `TilePoint`, `KeeperChange`, `DashboardSummary`, the request types, in `Packages/AgentsKit/Sources/AgentsKitCore/Dashboard/DashboardWire.swift`
- [X] T004 [P] `DashboardModel`: stale (`setAt == nil` or past `stale_after_hours`), shown level (stale status → unknown), age words, change since a day ago, row line, sections in made order, in `Packages/AgentsKit/Sources/AgentsKitCore/Dashboard/DashboardModel.swift`
- [X] T005 Mac: `ColumnPick.dashboard`, `AppModel.openDashboard`, Dashboard row at the top of the sessions column, page in the chat's place with a grid of 180 pt tiles by section, tile foot (keeper · age), sparkline `Path`, greying; in `App/Sources/Dashboard/{DashboardRow,DashboardPage,TileCard}.swift`, `App/Sources/Projects/SessionsColumn.swift`, `App/Sources/ContentView.swift`, `App/Sources/AppModel.swift`
- [X] T006 Web: `Web/src/model/dashboard.ts` (the T004 rules), `Web/src/views/Dashboard.tsx` (row + grid + SVG sparkline), route `dashboard` in `Web/src/views/Columns.tsx`, styles in `Web/src/app.css`
- [X] T007 A first `dashboard/get` and `dashboard/summaries` in the daemon reading tile files as they are (no state yet) in `Packages/AgentsKit/Sources/AgentsKit/Dashboard/DaemonCore+Dashboard.swift`, `DaemonCore+Dispatch.swift`, `DaemonAPI+Web.swift`; `scripts/web.sh types`
- [X] T008 **Look**: hand-written tile files in a scratch project; Mac window screenshot by window id and web page in headless Chrome, saved under `specs/074-project-dashboard/look/`; commit

## Phase 3: User Story 1 — an agent keeps a tile, the person sees it (P1)

**Independent test**: an agent sets one tile of each type; the Mac shows value, keeper, section, age.

- [X] T009 [P] [US1] `TileCheck`: parse `set_tile` arguments into a `TileFile`, every rule in data-model.md, refusal sentences naming the field, in `Packages/AgentsKit/Sources/AgentsKitCore/Dashboard/TileCheck.swift`
- [X] T010 [US1] `DashboardStore`: per project `<root>/dashboards/<key>/` (key = 16 hex of an FNV-1a hash of the standardized path), `state.json`, `points/<id>.jsonl`, whole writes by temp + rename, skip identical bytes, at most one point a minute, in `Packages/AgentsKit/Sources/AgentsKit/Dashboard/DashboardStore.swift`
- [X] T011 [US1] `setTile`/`removeTile`/`readDashboard` in `DaemonCore+Dashboard.swift`: caller from token, project = `projectFolder` (never cwd), missing folder refused (#119), keeper agent or the agent's `startedByWorkflow`, other keeper refused naming it, 120 sets an hour, 60 tiles, 8 KB, 8 MB history; answer per contracts/agent-tools.md
- [X] T012 [US1] Three tools in `AppService.swift` (`DashboardCall`, sink, schemas), `AppTool.swift` names, relay in `Daemon/Sources/main.swift`, methods in `ConnectionRole.agentMethods`, dispatch in `DaemonCore+Dispatch.swift`
- [X] T013 [US1] `dashboard/changed` with summary, once a second per project; clients refetch: `App/Sources/AppModel.swift`, `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift`, `Web/src/model/store.ts`
- [X] T014 [US1] Keeper click opens the session or workflow (Mac, web)
- [X] T015 [P] [US1] Tests in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/DashboardTests.swift`: checks, keeper refusal, worktree agent writes the project folder, same value leaves bytes alone and refreshes age, 100 concurrent sets from 5 agents leave every file whole

## Phase 4: User Story 2 — old tiles look old (P1)

- [X] T016 [US2] Greying, "2 days old", stale status as unknown, archived/retired keeper foot on Mac and web (from `DashboardModel`/`dashboard.ts`); tests for `DashboardModel` in `DashboardTests.swift`

## Phase 5: User Story 3 — hide and remove (P2)

- [X] T017 [US3] `dashboard/hide`, `show`, `remove` in `DaemonCore+Dashboard.swift`; removal note (30 days) and the "put it back" answer on the next set
- [X] T018 [US3] Mac tile `···` and context menu (Hide, Remove, Open Keeper), Show Hidden Tiles; web tile menu; tests for hide surviving a set and remove coming back

## Phase 6: User Story 4 — phone and browser (P2)

- [X] T019 [US4] Remote: Dashboard row above Sessions with the one-line summary, one-column page (numbers two across, tables to 5 rows with All N rows), long-press Hide/Remove/Open Keeper, in `Remote/Sources/Dashboard/` and `Remote/Sources/Projects/ProjectPageView.swift`, `Remote/Sources/RemoteModel.swift`
- [X] T020 [US4] Web: live updates, Hide/Show/Remove, tile detail; `scripts/web.sh build`

## Phase 7: User Story 5 — read and carry on (P3)

- [X] T021 [US5] `take_over` for archived/retired keepers and for sessions the caller read with `read_session` (research R1); keeper change recorded; workflow runs share tiles; tests

## Phase 8: Polish

- [X] T022 Outside edits: watch `<folder>/.agents/dashboard/` via the workflow `FolderWatch`; "changed outside Agents"; broken file as a broken tile; tests
- [X] T023 Compaction on the housekeeping tick (7 d / 90 d / 1 y); tests. **Not wired:** there is no project remove in the daemon today (only archive, which keeps the Dashboard), and #61's move between machines does not carry `dashboards/<key>/` yet; `DashboardStore.deleteHistory` and `moveHistory` are there for both
- [X] T024 Briefing paragraph in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift`; `BriefingTests`
- [X] T025 Docs: `docs/reference/agent-tools.md`, `docs/how-to/keep-a-project-dashboard.md`, `docs/reference/dashboard-tiles.md`, `docs/explanation/projects-hosts-worktrees.md`, `specs/071-web-remote/walks/parity.md`, `mkdocs.yml`
- [X] T026 `scripts/perf-budgets.py` row for `dashboard/get`
- [X] T027 The walk (quickstart.md): a Claude agent posted `open_bugs` 4 and `tests_passing` 1180 → 1191 → 1203 (a minute apart, three points) through set_tile; shown on the Mac and the web page; Remove from the web page held (dashboard/get without it) until the agent set it again, whose answer said who removed it and when; Remote builds for the generic simulator (its look is Alex's). Shots in `specs/074-project-dashboard/walks/`

## Dependencies

Phase 2 before all stories. US1 before US2–US5. US3 before US4's Hide/Remove. Polish last.

## Parallel

T002–T004 together; T009 beside T010; T015 beside T013–T014; T019 (Remote) beside T020 (web).

## MVP

Phases 1–4: tiles written by agents, seen and greyed on the Mac and the web page.
