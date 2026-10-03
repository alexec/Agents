# Implementation Plan: Project Dashboard, slice 1

**Branch**: `agents/ideate-github-issue-122` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

**Input**: Spec 074 (#122, slice 1), from [`specs/research/122-project-board.md`](../research/122-project-board.md)
with Alex's nine decisions (§8): it is the Dashboard; agents write through tools to committed
`.agents/dashboard/<id>.json` files in the project folder; history stays on the host; Remove comes
back on the keeper's next post; the host never commits; the briefing is the only worktree guard.

## Summary

The host owns a project's Dashboard. Three new agent tools, `set_tile`, `remove_tile` and
`read_dashboard`, reach the daemon through `agentsd mcp` as every app tool does. The daemon checks
each call (id, type, sizes, keeper, rate, limits), then writes the tile whole, by temp file and
rename, to `<project folder>/.agents/dashboard/<id>.json`. The folder comes from the agent's
`projectFolder`, never its `cwd`, so an agent in a worktree writes the project's one Dashboard. A
file holds no timestamps and no points, so an unchanged value is not rewritten.

What must not churn git lives on the host, under `<root>/dashboards/<project hash>/`:
`state.json` (when each tile was set, the hash of the host's last write, keeper changes, removal
notes) and `points/<id>.jsonl` (a number tile's points, compacted on the host's housekeeping tick).

Clients read with `dashboard/get` and act with `dashboard/hide`, `dashboard/show` and
`dashboard/remove`. They hear `dashboard/changed`, at most once a second per project. The Mac and
the Remote share one `DashboardModel` in AgentsKitCore (staleness, summary, trend); the web page
mirrors it in `Web/src/model/dashboard.ts`.

**Order of work** (the look first, as asked):
1. The wire types and a seeded fake Dashboard behind `dashboard/get`, enough to draw.
2. **Look**: the Mac's Dashboard row and grid on a scratch window, and the web page's row and grid
   in headless Chrome, screenshotted, before any depth.
3. The store, the tools, keepers, limits, history; unit tests.
4. The Remote's row and page; the web page's Hide, Show, Remove; live updates on all three.
5. Briefing, docs, parity row, perf budget row; the run-app walk.

## Technical Context

**Language/Version**: Swift 6.2, strict concurrency (AgentsKit, App, Remote); TypeScript 5 strict
(`Web/`, Preact).

**Primary Dependencies**: none new. Sparklines are a SwiftUI `Path` on the Mac and the Remote (no
Swift Charts: the research named it, but a 30-point line is twenty lines of `Path`, and nothing
else in the app imports Charts). The web page draws an SVG polyline.

**Storage**: tile files in the project (`.agents/dashboard/*.json`); host state in
`<root>/dashboards/<key>/state.json` and `points/<id>.jsonl`. The key is the SHA-256 of the
standardized project path, first 16 hex characters.

**Testing**: `swift test --package-path Packages/AgentsKit` (Swift Testing); `npm test` in `Web/`
via `scripts/web.sh check`; run-app scratch root with a real Claude agent posting tiles; Chrome via
`Web/test/walk/cdp.mjs`.

**Target Platform**: agentsd on macOS (and the Linux build: no Darwin-only API in the store); the
Mac window (AgentsStore); the Remote (iOS/iPadOS); the web page.

**Project Type**: multi-app Swift repo with a shared core package, plus the web page.

**Performance Goals**: `dashboard/get` with 60 tiles under 100 ms on the host; the Mac's page drawn
under 250 ms (SC-002). Reads never compact.

**Constraints**: FR-016 whole writes; FR-015 no timestamps in files; FR-014 never a worktree;
FR-017 never commit; limits FR-021; 120 sets an hour per agent (FR-009).

**Scale/Scope**: about 6 new Swift files in AgentsKit/AgentsKitCore, 3 in the App, 2 in the
Remote, 3 in `Web/src`; edits to AppService, main.swift, Dispatch, ConnectionRole, WebSignatures,
Briefing, the three clients' models and columns; 5 docs pages.

## Constitution Check

| Principle | How this plan meets it |
|---|---|
| I. Spec-led | Spec 074 with acceptance scenarios; this plan, then tasks, then implement. |
| II. Capability-driven runtimes | The tools are MCP tools like the other app tools; no runtime is special-cased. |
| III. Scoped access | The tools write only `<project>/.agents/dashboard/`, the app's own write, as `manage_workflows` writes `.agents/workflows/` (spec Assumptions). Keepers are taken from the caller's token, never from arguments. |
| IV. Inspectable | Each tile names its keeper, source and age; its detail shows keeper changes, outside edits and the last 10 points. Every refusal is a sentence naming what was wrong. |
| V. Docs and quality | The five docs pages in the spec change with the code; `generated.ts` and `Web/dist` regenerated; warnings are errors. |

No violations. Gate passes before and after design.

## Project Structure

### Documentation (this feature)

```text
specs/074-project-dashboard/
├── spec.md
├── plan.md              # this file
├── research.md          # decisions on the open points
├── data-model.md        # tile file, host state, wire types
├── quickstart.md        # the walk that proves it
├── contracts/
│   ├── agent-tools.md   # set_tile, remove_tile, read_dashboard
│   └── daemon-api.md    # dashboard/get, hide, show, remove, changed
├── look/                # the look-first screenshots
└── tasks.md
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/Dashboard/
├── Tile.swift                 # TileFile (the committed shape), TileValue, TileType, Keeper
├── TileCheck.swift            # parsing a set_tile call, limits, refusals in words
├── DashboardWire.swift        # DaemonAPI methods, requests, DashboardSnapshot, TileView
└── DashboardModel.swift       # staleness, worst status, summary line, trend, ages in words
Packages/AgentsKit/Sources/AgentsKit/Dashboard/
├── DashboardStore.swift       # files (atomic), host state, points, compaction
└── DaemonCore+Dashboard.swift # tools, person methods, notifications, watch, keepers
Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift   # 3 tools + DashboardCall sink
Daemon/Sources/main.swift                                          # relay
Packages/AgentsKit/Sources/AgentsKitCore/Daemon/ConnectionRole.swift, DaemonAPI+Web.swift
Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift      # the paragraph
App/Sources/Dashboard/{DashboardRow,DashboardPage,TileView}.swift
Remote/Sources/Dashboard/{DashboardRow,DashboardPage}.swift
Web/src/model/dashboard.ts, Web/src/views/Dashboard.tsx (+ Columns.tsx, store.ts, app.css)
Packages/AgentsKit/Tests/AgentsKitTests/Unit/Dashboard*Tests.swift
```

**Structure Decision**: the wire and the pure rules (staleness, summary, trend, checks) live in
AgentsKitCore so the Mac, the Remote and the tests share them; the store and the daemon's side live
in AgentsKit beside the other `DaemonCore+` files.

## Complexity Tracking

None.
