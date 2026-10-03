# 122: A project board agents post to

2026-10-02, branch `agents/ideate-github-issue-122` off main at f0711855. This covers issue #122. It is ideation and design only; nothing is built.

**Method**: The #122 ideation agent read the issue, `README.md`, `docs/reference/events.md`, `workflows.md`, `agent-tools.md`, `docs/explanation/leases.md` and `control-plane.md`, `specs/research/073-robustness-speed-feedback.md` (timing budgets) and `099-event-matching.md`. It also read the parity walk (`specs/071-web-remote/walks/parity.md`) and spec 063 (the GitHub Project issue board). A read-only survey of the code covered the Activity pages, the event log, the agents' tools, the spend ledger, workflows, on-disk state and the web page's wire. The file references below come from that survey.

## Summary

- **A board is a list of tiles that agents keep, one board per project.** A tile is a number with its trend, a chart, a table, a status light, a note or a link. Every tile says who keeps it and how old it is.
- **Values go in through the agents' own tools, into the host's store.** The first slice adds three tools: `set_tile`, `remove_tile` and `read_board`. A file in the project was considered and rejected for values, because worktrees and git churn break it (see [§3](#3-how-data-gets-in)). Events are a good **source of counts** but a poor **carrier for values**.
- **History lives on the host, beside `events.jsonl`, not on the control plane.** It is kept at full grain for 7 days, hourly to 90 days, then one point a day for a year, with hard caps per tile and per project.
- **On screen it is a Board row at the top of each project's sessions column** on the Mac, the Remote and the web page. It opens in the chat's place, the same way a workflow's page does today. Every client can pin, hide and remove tiles, following the [one grant for every client](../../docs/explanation/control-plane.md) decision.
- **Trust comes from provenance and age, not from checking the numbers.** Each tile names its keeper, says where its value came from, greys out once it is past its own "stale after" time, and can be removed by the person. A removed tile stays removed.
- **First slice:** the store, the three tools, five tile types (number with sparkline, status, table, note, link), the board page on all three apps with greying and Remove. Charts with several lines and tiles counted from events come next.

## What exists today, and what a board adds

| | Activity pages (Events, Resources, Runtimes, Spending) | The board |
|---|---|---|
| Scope | The whole Mac (Events can be filtered to a project) | One project |
| Who decides what's on it | The app | Agents, and the person who prunes it |
| History | Events: 7 days or 10,000, whichever is first (`EventLog.swift:19-25`). Spend: 7 days per day per currency, and "not a history and must never be shown as one" (`SpendLedger.swift:11-22`) | 7 days full grain, hourly to 90 days, daily to a year |
| Charts | None. Nothing in App, Remote or Packages imports `Charts` | Sparklines first, then lines and bars |
| Web page | Resources only. No Events, Spending or Runtimes page | All of it, from the start |

Other facts that shape the design:

- **There is no project tab bar.** The Mac's middle column is one `List` with Sessions and Workflows sections (`SessionsColumn.swift:6`, `ProjectWorkRows.swift:57`). Picking a workflow opens `WorkflowPage` in the detail column (`ContentView.swift:90`). The Remote's `ProjectPageView` stacks Sessions, Archived and `WorkflowsSection` (`:77–97`). The web page's `Columns.tsx` mirrors the Mac's columns.
- **Events never leave their host** (`DaemonCore+Events.swift:17`). The control plane's store holds pairing, hosts and settings, and nothing per project.
- **Workflows run agents, never scripts** (`WorkflowTrigger.swift:209`). "A workflow runs the perf script" means a workflow starts an agent that runs it and posts the result. That costs a model turn.
- **Adding an agent tool** takes four things: a name in `AppTool`, a schema plus a `tools/call` branch in `AppService`, a `DaemonAPI.Method` with its handler, and an entry in `ConnectionRole.agentMethods`. The web page also needs the read method listed in `WebSignatures`, then `scripts/web.sh types`.
- **The name "board" is taken in the specs.** `specs/063-github-project-board` is a GitHub Project issue board (Ready and In progress issues, assign to an agent). It is not in the app today: no code matches it. If 063 is ever built, the two need different names (see [Decisions](#8-decisions-for-alex)).

## 1. What it's for

Each board below is what one agent, or one workflow, would keep in a project. The tile types are those in [§2](#2-tile-types). "Source" says where the value comes from.

1. **The project lead's queue and ship state.** Today the lead keeps this in prose, in memory files such as `lead-queue-2026-10-01.md`.
   - *Big numbers:* running lanes, merged-not-shipped, merged-not-pushed.
   - *Status:* "live: f0711855, shipped 16:59" (green), "Remote on iPhone: install failed: locked" (amber).
   - *Table:* lane, issue, agent, state (running, walking, merged, shipped, live).
   - *Source:* the lead agent, at each `finish_turn`.
2. **Open bugs by label.**
   - *Big number:* open bugs, with a trend over 30 days.
   - *Bar chart:* `bug`, `crash`, `regression` and `web` per week.
   - *Table:* the five oldest open bugs, each linked.
   - *Source:* a scheduled workflow whose agent runs `gh issue list --json` and posts. The "bugs before features" rule makes this the lead's first glance.
3. **Tests.**
   - *Big numbers:* AgentsKit passing, ControlPlane passing, web tests passing, each with a trend.
   - *Table:* flaky tests, with failures in the last 6 runs. The suite is broadly flaky under load, so this table is the evidence for "compare six runs".
   - *Status:* the last full run on main.
   - *Source:* the merge or verify agent after each `swift test`, and #39's nightly.
4. **Performance budgets over time.**
   - *Line chart:* one line per row of `scripts/perf-budgets.py` (`agents/list`, chat open, `changes/list` and the rest), with the budget drawn as a dashed line.
   - *Status light:* red when the script exits 1.
   - *Source:* the nightly workflow (#39) parsing `perf-budgets.py --markdown`. The window's numbers from `Perf.swift` can follow later.
5. **Spend per runtime.**
   - *Bar chart:* spend per day per runtime.
   - *Big number:* today against the daily limit.
   - *Status:* runtimes out of allowance.
   - *Source:* today the app keeps spend per agent (`Agent.costToDate`) and a 7-day ledger, with no per-runtime history. So either an agent posts this, or the board counts it from `agent.finished` carrying cost. That is a later built-in tile (slice 3).
6. **Workflow fires and refusals.**
   - *Bar chart:* `workflow.ran` per day, and `workflow.refused` per day stacked by `reason`.
   - *Big number:* runs awaiting approval.
   - *Source:* events counted over time. No agent is needed once tiles can count events (slice 2).
7. **Agent outcomes.**
   - *Bar chart:* `agent.finished` per day by `outcome`, and `agent.failed` by `reason`. Allowance spent and rate-limited are the ones to watch.
   - *Source:* events counted over time.
8. **Reconnect health.**
   - *Big numbers:* `server.offline` in the last 7 days, and the longest time offline.
   - *Table:* the last Remote hangs, from `remote.log` pulls.
   - *Status:* "Remote reconnect: still sticks" (amber).
   - *Source:* events plus an agent that reads the logs. This one is mostly notes and a table; it is the board as a shared notebook.
9. **A release checklist (alpha).**
   - *Status lights:* LICENSE, CI, pairing docs, security review S2 and S3 open.
   - *Note:* what "alpha" means.
   - *Source:* the agent leading the release, by hand.
10. **The docs site.**
    - *Status:* last deploy.
    - *Big number:* broken links.
    - *Link:* the site.
    - *Source:* a workflow on `branch.moved` `main`.

What these have in common:

- Most tiles are **a number that changes, and whose change matters** (1, 2, 3, 6, 8). A number tile should therefore keep its own history, and draw a trend line, without the agent having to ask for one.
- Several boards are **partly notes**: the lead's caveats, the reconnect investigation. A board with no notes would push those back into memory files.
- Three boards (6, 7, part of 8) need **no agent at all**. They are counts of events the host already raises.

## 2. Tile types

| Type | Holds | Draws | Example |
|---|---|---|---|
| `number` | One number with a unit, and optionally a goal or limit. Each set records a point. | The number, its change since a day ago or since the last point (▲2, ▼5%), and a sparkline of up to 30 days. Colours come from `good: up \| down`. | Open bugs **4** ▼1, sparkline |
| `series` | Up to 6 named lines (or bars), each a list of points. An optional dashed `threshold` per line. | A line or bar chart over 1 day, 7 days, 30 days or 90 days. | Perf budgets: `agents/list` 45 ms against 250 |
| `table` | Up to 6 columns and 50 rows of short text. A cell may be a link, a session or a status dot. | A table, with the first 5 rows on the phone. | Lanes: #120 · Walking · agent "Fix…" |
| `status` | `ok \| warn \| bad \| unknown`, a short line, and optionally since when. | A light and the line. | ● Live: f0711855 since 16:59 |
| `note` | Markdown, up to 4 KB. | Rendered like a chat message: no images, links allowed. | "Remote still sticks after a Mac restart…" |
| `link` | A URL, a session in this project, a file in the project or a workflow, plus a title. | A row that opens it. A session or file link opens in the app. | Docs site ↗ · "Spec 058" (opens in Files) |

Every tile also carries:

- `id`: a slug unique in the project, `[a-z0-9_-]{1,40}`, as custom event names are;
- `title`;
- an optional `section` (a heading tiles are grouped under);
- `keeper` (see [§6](#6-trust-and-staleness));
- `source`: one line saying where the value came from, such as `gh issue list -l bug --state open`;
- `updated_at`;
- `stale_after`.

`number` and `series` both store points. A `number` is a `series` with one line, drawn small. That keeps the store to one shape.

### On the Mac

The board opens in the detail column, in the chat's place. Tiles flow in a grid of fixed 180 pt columns, as many as fit, which is 4 at a typical width. Small tiles (number, status, link) take one cell. Charts and tables take two cells across. Notes take two cells across and grow down.

```text
┌ Projects ─────┬ Agents ─────────────────────┬ Board ───────────────────────────────────────────────────────┐
│ ▸ Agents   3  │ ▦ Board            12 tiles │  Agents · Board                         ⟳ 2 min ago   ···    │
│   Website     │ ─────────────────────────── │                                                              │
│   Notes       │ Needs you                   │  SHIPPING                                                    │
│               │  ● Fix reconnect   #120     │  ┌──────────────┐┌──────────────┐┌───────────────────────────┐│
│               │ Working                     │  │Merged, not   ││Running lanes ││● Live  f0711855          ││
│               │  ◌ Ideate board    #122     │  │shipped       ││              ││  shipped 16:59 · iPhone  ││
│               │  ◌ Missing folder  #119     │  │   4   ▲1     ││   3          ││  ◐ install failed: locked││
│               │ Done                        │  │ ▁▂▂▃▃▅▄▆     ││ ▃▅▃▂▅▃▃      ││ lead · 12 min ago        ││
│               │  ✓ Queued bubbles  #95      │  │ lead · 12 min││ lead · 12 min│└───────────────────────────┘│
│               │                             │  └──────────────┘└──────────────┘                             │
│               │ Workflows                   │  ┌───────────────────────────────────────────────────────────┐│
│               │  ⟲ Nightly         10pm     │  │Lanes                                       lead · 12 min  ││
│               │  ⟲ Bug count       hourly   │  │#120  Reconnect hang   walking     agent "Fix reconnect"   ││
│               │                             │  │#118  Sheet look       building    agent "Sheet…"          ││
│               │                             │  │#119  Missing folder   live        —                       ││
│ ───────────── │                             │  └───────────────────────────────────────────────────────────┘│
│ Events        │                             │  QUALITY                                                     │
│ Resources     │                             │  ┌──────────────┐┌──────────────┐┌───────────────────────────┐│
│ Runtimes      │                             │  │Open bugs     ││AgentsKit     ││Perf budgets       30 days ││
│ Spending      │                             │  │   4   ▼1     ││ 1,203 pass   ││ 250 - - - - - - - - - - - ││
│               │                             │  │ ▆▅▅▄▄▃▃▂     ││    2 flaky   ││ 45 ──╮─────────────────── ││
│               │                             │  │ Bug count ·1h││ nightly · 2 d││ chat open 287→250 ms  ✓   ││
│               │                             │  └──────────────┘└░░░░░░░░░░░░░░┘└───────────────────────────┘│
│               │                             │                   ↑ greyed: past its 24 h, "2 days old"       │
└───────────────┴─────────────────────────────┴──────────────────────────────────────────────────────────────┘
```

- The **Board row** sits at the top of the sessions column, above Needs you. It is a row like a workflow's: selectable, with a count, and a red dot when any tile is `bad`.
- **The foot of each tile** names its keeper and its age: an agent's title, a workflow's name or "you". Clicking the keeper opens that session or workflow.
- The **⟳** shows the newest update. **···** holds Show Hidden Tiles and Copy Board as Markdown.

### On the phone

The Remote's project page gets a Board row above Sessions. It shows the worst status and the first number, so it is worth a glance without opening anything. It opens a single column of tiles. Charts are drawn full width at a fixed 120 pt height, and tables show their first 5 rows with "All 14 rows".

```text
┌─────────────────────────────┐        ┌─────────────────────────────┐
│ ‹ Projects     Agents       │        │ ‹ Agents        Board       │
│                             │        │ SHIPPING                    │
│ ▦ Board                   › │        │ ┌─────────────┬────────────┐│
│   ● 1 needs a look · 4 bugs │  tap   │ │Merged, not  │Running     ││
│                             │ ─────► │ │shipped  4 ▲1│lanes     3 ││
│ SESSIONS                    │        │ │ ▁▂▃▃▅▄▆     │ ▃▅▃▂▅▃     ││
│ ● Fix reconnect      #120   │        │ └─────────────┴────────────┘│
│ ◌ Ideate board       #122   │        │ ● Live f0711855 · 16:59     │
│ ✓ Queued bubbles      #95   │        │ ◐ iPhone: install failed    │
│                             │        │ ┌─────────────────────────┐ │
│ WORKFLOWS                   │        │ │Lanes          lead·12 m │ │
│ ⟲ Nightly            10pm   │        │ │#120 walking             │ │
│ ⟲ Bug count        hourly   │        │ │#118 building            │ │
│                             │        │ │#119 live    All 7 rows ›│ │
│                             │        │ └─────────────────────────┘ │
│                             │        │ QUALITY                     │
│                             │        │ ┌─────────────┬────────────┐│
│                             │        │ │Open bugs 4▼1│░AgentsKit░░││
│                             │        │ │ ▆▅▅▄▄▃▂     │░1,203 · 2 d││
│                             │        │ └─────────────┴────────────┘│
└─────────────────────────────┘        └─────────────────────────────┘
```

- Number tiles go two across on the phone. Long-press a tile for **Open Keeper**, **Hide** and **Remove**.
- Charts on the Mac and the Remote use Swift Charts, which nothing imports yet. It is on macOS 13 and iOS 16, below our minimums. The web page draws small SVGs of its own: a sparkline, a line and a bar are about 150 lines together, and it adds no chart library to `Web/dist`.

## 3. How data gets in

| Way in | Pros | Cons |
|---|---|---|
| **A. Agent tools: `set_tile`, `remove_tile`, `read_board`** | The daemon knows which agent is calling (its token), so the keeper is known for certain. A tile is checked when it is written (sizes, types, rate), and a bad call is refused in words, as `publish_event` is. It works the same on every runtime and in every worktree, and on a Linux server. It needs no git, so it causes no churn. | Values aren't reviewable in git. A tool is one more thing in every agent's catalogue: 3 tools, about 1 KB of schema. A misleading agent can post a misleading number (see [§6](#6-trust-and-staleness)). |
| **B. A file in the project (`.agents/board/*.json`)** | Reviewable and diffable, and it travels with the repo and with #61's move. Any script can write it, with no agent in the loop. It looks like workflows, which live in `.agents/workflows/`. | **Every worktree has its own copy.** An agent in `.agents/worktrees/x` writes that worktree's file, so the board would show whichever checkout the host reads, and lanes would conflict on merge. Values change hourly, so every commit carries board churn, or the file is git-ignored and is not reviewable after all. Nothing says who wrote a value. And the host would have to watch the file. |
| **C. Events counted over time** | Free, with no model turns: the host already raises `workflow.refused`, `agent.finished` and the rest. The filters are #99's matcher as it is (equals, any-of, label sets). Counts are honest, because the app made them. | Only counts. Nobody can post "1,203 tests" this way. The log keeps 7 days, so the board must count as events arrive and keep its own points (it cannot look back further than 7 days when a tile is made). |
| **C′. Agents publish `custom.metric` events carrying values** | No new tool. | 30 publishes an hour per agent. Each publish wakes waiters and runs workflows. It floods the Events page. The 7-day log is the wrong store. **Rejected.** |
| **D. GitHub queries run by the host** | Open bugs by label with no agent, refreshed on a timer. | The host has no GitHub identity of its own. It would use the person's `gh` sign-in on a timer, unseen, on every host, and on a server whose `gh` may not be signed in. 063 (the GitHub board) is not in the app, so there is nothing to build on. An hourly workflow whose agent runs `gh` and calls `set_tile` does the same job, visibly. |
| **E. Workflows running scripts** | Tests and perf budgets on a schedule. | Workflows run agents, not scripts. An agent turn to run one script and post one number costs money and a turn's latency, though it reads the output well and can explain a red. A **host-run command source** would be cheap, but it means running code from the repo on a timer. That is the class of hole S2 and S3 in the security review were about, so it would need the workflow approval flow. Later, if ever. |

**Recommendation:** use A for values, C for counts, and B for nothing in the first slices.

- **A is the main way in.** Agents already end turns with `finish_turn`, and a lead that sets three tiles before it does is the whole of board 1. Board-keeping guidance goes in the agent's briefing next to the lease guidance: "If you keep something the person checks often, keep it as a tile."
- **C comes in slice 2**, as a tile kind whose `source` is an event pattern plus a bucket (`per: hour | day`). It is created with `set_tile` like any other tile, so an agent sets it up once and the host keeps it. This gives boards 6 and 7, and part of 8, for nothing.
- **B, if wanted later,** is a **layout file**, not a values file: `.agents/board.md` with sections, order and pinned tiles. It would be reviewable, travel with the repo, and is read only from the project folder, never a worktree. It is useful once a project has 30 tiles and wants an order that survives the people and agents that made it.

### The tools, sketched

`set_tile` creates or replaces a tile the caller keeps. For `number` and `series`, each call also records a point.

```json
{ "id": "open_bugs", "title": "Open bugs", "type": "number",
  "value": 4, "unit": "", "good": "down",
  "section": "Quality", "source": "gh issue list -l bug --state open",
  "stale_after_hours": 2 }
```

```json
{ "id": "perf", "title": "Perf budgets", "type": "series", "chart": "line",
  "points": { "agents/list": 45, "chat open": 287 },
  "thresholds": { "agents/list": 250, "chat open": 500 }, "unit": "ms",
  "stale_after_hours": 30 }
```

- **What the caller is told back:** the tile as stored, its points count, and a warning when a person has hidden it.
- **Refusals,** each in words: an id another keeper owns ("kept by agent 'Nightly', a workflow; ask it, or take it over once it is archived"), a removed tile (see [§6](#6-trust-and-staleness)), sizes over the limits in [§4](#4-storage-and-history), or more than 120 calls an hour.
- **`remove_tile`** removes a tile the caller keeps.
- **`read_board`** lists every tile in the project, with values, keeper, age and the last 10 points. Agents can use it to build on each other's tiles, and a successor can use it to pick up the lead's.
- **Who gets the tools:** every agent, helpers included. A helper is often the one that measured the thing.
- **Permission:** "No. The app answers", as for `show_file`. Writing a tile changes nothing outside the app.

## 4. Storage and history

**Where:** on the host that owns the project, beside the event log. Not on the control plane.

- `<root>/boards/<project-key>/tiles.json` holds every tile's current state, written whole on change, as `agent.json` is.
- `<root>/boards/<project-key>/points/<tile-id>.jsonl` holds one line per point, appended. It is compacted by rewrite (temp file, then rename), as `EventStore` prunes.
- **Why the host:** the host owns the project's folder, agents and events, and events never leave it. Event-counted tiles must count where the events are raised. The control plane's store is deliberately thin (pairing, hosts, settings), and in the cloud it is S3. Putting per-minute writes there adds cost and a failure path for no gain. Clients already reach host data through the control plane's router, so a board on the host is seen everywhere, like a chat.
- **Moving a project (#61)** must carry `boards/<project-key>/` with it. **Archiving** a project keeps its board. **Removing** a project deletes it.

**Grain and retention:**

| Age | Kept |
|---|---|
| Up to 7 days | Every point, at most one a minute per line. A second point in the same minute replaces the first. |
| 7 to 90 days | One point an hour per line: the hour's last value for a number, its sum for counts. |
| 90 days to 1 year | One point a day per line: the day's last value for a number, its max for counts. |
| Older than 1 year | Dropped. |

Compaction runs on the host's existing housekeeping tick. It never runs on a read.

**Limits:**

| What | Limit | Why |
|---|---|---|
| Tiles per project | 60 (hidden ones count; removed ones don't) | A board past 60 is not glanceable |
| Lines per `series` | 6 | Legible on a phone |
| `table` | 6 columns × 50 rows, 200 characters a cell | |
| `note` | 4 KB of Markdown | |
| Points per line | about 12,400 at most: 7 days of minutes (10,080), 83 days of hours (1,992) and 275 days | A line set hourly holds about 2,400 |
| A project's board on disk | 8 MB, refusing new points with a sentence past it | 60 tiles × 6 lines × 12,400 points × about 40 B is about 180 MB in the worst case. Real boards, set hourly or per turn, are under 1 MB, and the cap makes the worst case a refusal rather than a full disk (#88) |
| `set_tile` | 120 calls an hour per agent | A lead setting 5 tiles every turn stays under; a loop does not |

**What travels to a client:**

- `board/get` returns tiles with their series **downsampled to at most 120 points per line** for the range asked (1 d, 7 d, 30 d or 90 d). The full file never travels.
- `board/changed` tells clients of a change, at most once a second per project.

**Timing budgets** (to add to `scripts/perf-budgets.py`, in 073's terms):

| What | Budget |
|---|---|
| `board/get`, 60 tiles, 30 days (host) | 100 ms |
| Board open on the Mac, drawn | 250 ms |
| Board open on the Mac, from the Board row | Within the 100 ms project-switch budget |

## 5. UI placement and parity

| | Mac window | Remote (iPhone, iPad) | Web page |
|---|---|---|---|
| Where | **Board** row at the top of the sessions column; opens in the detail column, as a workflow's page does | **Board** row at the top of the project page, with a one-line summary; pushes a page | **Board** row at the top of the sessions column; opens in the chat's column |
| Tiles | Grid, 180 pt columns | One column; numbers two across | Grid, like the Mac |
| Ranges | 1 d · 7 d · 30 d · 90 d | 7 d · 30 d | Like the Mac |
| Hide, Remove, Restore | Tile's ··· and context menu | Long-press | Tile's ··· |
| Reorder, sections | Drag (slice 3) | — (by design, slice 3) | Drag (slice 3) |
| Open keeper | Click the foot | Tap the foot | Click the foot |

- **Why a row, not a tab:** none of the three apps has a project tab bar, and adding one is a larger change than the board. The Board row reuses the pattern workflows proved in #98: a row in the sessions list that opens a page in the chat's place. A tab bar (Sessions · Workflows · Board) is the alternative if Alex wants one (see [Decisions](#8-decisions-for-alex)).
- **Why not the empty project page:** `ProjectAgentsView`, shown when nothing is picked, could become the board. But it would vanish the moment a session is picked, and a board is something to come back to.
- **Parity:** all three ship in the same lane. The web page needs `board/get`, `board/hide`, `board/remove` and `board/restore` in `WebSignatures`, then `scripts/web.sh types`. Each commit says which of the three it covers, and the parity table gains a row.
- **Who edits the layout:**
  - In slice 1 there is no layout to edit. Tiles go in sections in the order they were created, and the person hides, removes and restores.
  - Every client may do all of it, per the one-grant decision (no operator-only settings).
  - Agents decide content and `section`. People decide what stays.
  - Reordering (drag, stored on the host) comes in slice 3, and the optional `.agents/board.md` after it.

## 6. Trust and staleness

**Keepers:**

- A tile is kept by **an agent**, **a workflow** or **you**. An agent started by a `standing` or `new` workflow writes tiles as **the workflow**, so every run of "Nightly" updates the same tiles rather than each new agent orphaning the last one's.
- An agent started by a person or another agent keeps its own tiles. When it is **continued by a successor** (spec 065), the successor inherits them.
- Another agent cannot overwrite a tile. It can read it, and it can **take over** a tile whose keeper is archived or retired (`set_tile` with `take_over: true`). The handover is recorded in the tile's detail.
- **You** keep a tile you make by hand. In slice 1 that is only notes and links: "Add Note" in the board's ···.

**Provenance:**

- Every tile has `source`. The tool requires it for `number`, `series` and `table`.
- The tile's detail shows the source, the keeper with a link to its session, every change of keeper, and the last 10 points with their times.
- A number that looks wrong is one click from the turn that posted it. That is the main defence against misleading numbers: it is visible, attributed and correctable, not prevented.

**Staleness:**

- Each tile has `stale_after`: the tool's `stale_after_hours`, defaulting to 24 h and at most 7 days. Event-counted tiles never go stale, because the host keeps them.
- Past it, the tile is **greyed** and its foot says "2 days old" instead of "12 min ago". A greyed `status` tile becomes `unknown` and loses its colour, so a green light that stopped being kept does not keep saying green.
- The Board row's summary and its red dot ignore greyed tiles.
- A tile whose keeper is **archived or retired** shows that at its foot ("its agent is archived"), and is greyed once stale like any other.

**Correcting and removing:**

- **Hide** takes the tile off the board for this project, on every client. Its keeper keeps updating it, and **Show Hidden Tiles** brings it back. Use it for "true but not interesting".
- **Remove** deletes the tile and its points, and leaves a tombstone. The keeper's next `set_tile` on that id is refused: "Alex removed this tile on 2 Oct at 17:20; don't recreate it under another id unless asked." **Restore** in Show Hidden Tiles lifts the tombstone. Without the tombstone, an hourly workflow would put back a tile the person removed within the hour.
- **Correcting a number** is not done by editing it. The person opens the keeper (one click) and tells it. A person's edit would be overwritten at the next post anyway.

## 7. A recommended first slice

**Slice 1: "agents keep tiles, people read and prune them".** One lane.

- **Host:**
  - The store in [§4](#4-storage-and-history), with its limits and compaction.
  - `set_tile`, `remove_tile` and `read_board`, for types `number` (with points), `status`, `table`, `note` and `link`.
  - Keepers: agent and workflow, with successor inheritance. Hide, remove (tombstone) and restore.
  - `board/get`, `board/changed`, `board/hide`, `board/remove` and `board/restore`.
- **Briefing:** a paragraph on when to keep a tile, beside the lease paragraph.
- **Mac:** the Board row, a grid page, the tile detail (source, keeper, last points), the greying, and Hide/Remove/Restore. Number tiles draw their sparkline with Swift Charts.
- **Remote:** the Board row with its summary, the one-column page, and long-press Hide/Remove.
- **Web:** the Board row and the grid page, with SVG sparklines. Hide/Remove/Restore. Added to `WebSignatures`.
- **Docs:** `docs/reference/agent-tools.md` (three rows), a how-to "Keep a project board", and the parity table row.
- **Proof:** unit tests for keepers, tombstones, limits, compaction and downsampling, plus a `perf-budgets.py` row. A run-app walk where a scratch agent posts four tiles, one is aged past `stale_after` by seeding, and one is removed and then refused. The web walk runs in Chrome.
- **Left out on purpose:** `series` charts with several lines, bars, event-counted tiles, reordering, layout files, built-in tiles and person-made notes.

**Slice 2: charts and counts.**

- The `series` type (lines and bars, up to 6 lines, thresholds, ranges).
- Event-counted tiles (`source: { event, where, per }`), using `EventPattern` as it is. These count from the moment they are made, and the detail says so.
- "Add Note" and "Add Link" for the person.

**Slice 3: arranging, and boards with no agent.**

- Drag to reorder, and sections the person can rename. A built-in set the person can add with one click: workflow fires and refusals, agent outcomes, and spend per runtime. Spend per runtime needs `agent.finished` to carry its cost, which is one detail in `agentDetails`.
- Copy Board as Markdown, so a lead can paste the board into an issue.

**After that, if wanted:**

- `.agents/board.md` as a reviewable layout.
- A host-run command source, behind workflow-style approval.
- Thresholds that raise `custom.` events, so that "perf over budget" starts a workflow.

**Seeding the boards in §1:**

- Once slice 1 is live, the project lead starts keeping board 1, which replaces the queue prose in its memory.
- #39's nightly workflow keeps boards 3 and 4.
- An hourly `Bug count` workflow keeps board 2.
- Boards 6 and 7 wait for slice 2.

## 8. Decisions for Alex

The #122 ideation agent proposes each of these. Alex, they are yours to settle before slice 1 is specified:

1. **The way in.** The #122 ideation agent recommends agent tools writing to the host (A), with events counted later (C), and no values file in git. Alex, is git-reviewable board content worth the worktree and churn costs, or is a layout file later enough?
2. **Placement.** The recommendation is a Board row at the top of the sessions column on all three apps. Alex, would you rather have a real project tab bar (Sessions · Workflows · Board), which is a bigger change touching every app's project page?
3. **The name.** "Board" collides with spec 063's GitHub Project issue board, which is not in the app. Alex, should this be **Board** (with 063 renamed "Issues" if it is ever built), or **Dashboard**?
4. **Remove is final until restored.** A removed tile's keeper is refused if it tries to recreate it. Alex, is that right, or should Remove only clear the tile and let the next post bring it back?
5. **Retention.** The proposal is 7 days at full grain, hourly to 90 days, a year of daily points, and 8 MB per project. Alex, longer, shorter, or settable?
6. **Built-in tiles.** Should the app ever put tiles on a board by itself (workflow refusals, outcomes, spend per runtime), or should every tile be agent-curated, as the issue frames it? The recommendation is a one-click set the person adds (slice 3), never automatic.
7. **The phone.** The proposal gives it read, Hide and Remove, but no reordering. Alex, is that enough?
