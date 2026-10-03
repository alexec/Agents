# Feature Specification: Project Dashboard, slice 1

**Feature Branch**: `074-project-dashboard`

**Created**: 2026-10-02

**Status**: Draft

**Input**: User description: "Slice 1 of the Dashboard (#122), from specs/research/122-project-board.md (§7 slice 1, with the decisions in §8): agents keep tiles through set_tile/remove_tile/read_dashboard; the host writes one committed file per tile in <project>/.agents/dashboard/ (project folder only, never a worktree; no timestamps or points in the file; never commits), history on the host with the agreed retention and limits; tile types number (with sparkline), status, table, note, link; keepers (agent, workflow, successor), source, stale_after greying; Hide (in the file), Show, Remove (comes back on the keeper's next post, keeper told); a Dashboard row at the top of the sessions column on the Mac, the Remote (read, Hide, Remove) and the web page; briefing guidance including that .agents/dashboard/ is written only through the tools. Out of scope: series charts, event-counted tiles, reordering, built-in tiles, person-made notes."

## Why this feature exists

What agents know about a project's health lives today in their turn endings, their memory
files and GitHub issues. A project lead agent keeps its queue and ship state in prose. The
person has no single place to see, at a glance, what is merged but not shipped, how many
bugs are open, or whether the tests passed last night.

A **Dashboard** is that place: one per project, made of **tiles** that agents keep. A tile is
a number with its trend, a status light, a table, a note or a link. Each tile says who keeps
it, where its value came from and how old it is, so the person can trust it or ignore it. The
person reads it on the Mac, the iPhone or iPad, or the web page, and decides what stays on it.

The design, its alternatives and Alex's decisions are in
[`specs/research/122-project-board.md`](../research/122-project-board.md). This spec is its
slice 1.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An agent keeps a tile, and the person sees it (Priority: P1)

A project lead agent finishes a turn. Before it does, it sets three tiles: "Merged, not
shipped: 4", a status "Live: f0711855, shipped 16:59", and a table of the lanes it is
running. The person opens the project and picks the **Dashboard** row at the top of the
sessions column. The three tiles are there, grouped under the section the agent named. Each
names the agent that keeps it and says "12 min ago". The number tile shows its change since
the day before and a small trend line.

**Why this priority**: This is the whole point. Without agents writing tiles and the person
reading them, nothing else in the feature matters.

**Independent Test**: In a scratch project, have an agent set one tile of each type, then
open the Dashboard on the Mac and check that each tile shows its value, keeper, section and
age.

**Acceptance Scenarios**:

1. **Given** a project with no Dashboard tiles, **When** an agent sets a number tile "Open
   bugs" with value 4, **Then** the project's Dashboard shows a tile titled "Open bugs" with 4,
   the agent's title as its keeper, and its age.
2. **Given** a number tile with earlier values 6, 5 and 5, **When** its keeper sets it to 4,
   **Then** the tile shows 4, its change since a day ago, and a trend line through the
   recorded values.
3. **Given** an agent's tile, **When** a different agent tries to set a tile with the same id,
   **Then** the call is refused, and the refusal names the tile's keeper.
4. **Given** an agent working in a worktree of the project, **When** it sets a tile, **Then**
   the tile appears on the project's one Dashboard, and its file is written in the project
   folder, not in the worktree.
5. **Given** a tile set with a value, **When** its keeper sets the same value again, **Then**
   the tile's age is refreshed, and its file in the project is unchanged.
6. **Given** a tile, **When** the person clicks its keeper, **Then** the keeper's session (or
   workflow) opens.

---

### User Story 2 - Old tiles look old (Priority: P1)

The nightly workflow kept a "Tests passing: 1,203" tile, but it has not run for two days. The
tile is greyed out, and its foot says "2 days old" instead of an age in minutes. A green
status light that nobody has confirmed past its own time goes grey too, so it stops saying
"all is well".

**Why this priority**: A dashboard that shows stale numbers as if they were current is worse
than none. Greying has to ship with the first tiles.

**Independent Test**: Set a tile with "stale after 1 hour", age it past that, and check it is
greyed on every client, and that a stale green status shows no colour.

**Acceptance Scenarios**:

1. **Given** a tile set with stale-after of 24 hours, **When** 25 hours pass without its
   keeper setting it, **Then** the tile is greyed and says how old it is.
2. **Given** a stale status tile that was green, **When** the Dashboard is shown, **Then** the
   light shows as unknown, without colour.
3. **Given** a tile whose keeper was archived, **When** the Dashboard is shown, **Then** the
   tile's foot says its keeper is archived.
4. **Given** a stale tile, **When** its keeper sets it again, **Then** it is no longer greyed.

---

### User Story 3 - The person hides and removes tiles (Priority: P2)

A helper agent posted a tile nobody needs. The person removes it. Another tile is accurate
but not interesting; the person hides it, and its keeper keeps updating it out of sight. Later
the person opens **Show Hidden Tiles** and shows it again.

**Why this priority**: Agents decide what goes on a Dashboard; the person decides what stays.
Without this, a Dashboard fills with noise the person can't clear.

**Independent Test**: Hide one tile, remove another, and check the first stays hidden through
its keeper's next post, while the second comes back on its keeper's next post with the
keeper told.

**Acceptance Scenarios**:

1. **Given** a tile, **When** the person hides it, **Then** it leaves the Dashboard on every
   client, and stays hidden when its keeper sets it again.
2. **Given** a hidden tile, **When** the person picks Show Hidden Tiles and shows it, **Then**
   it is back on the Dashboard on every client.
3. **Given** a tile, **When** the person removes it, **Then** it and its history are gone from
   the Dashboard, and its file is gone from the project folder.
4. **Given** a tile the person removed, **When** its keeper sets it again, **Then** the tile is
   back, and the keeper is told who removed it and when.
5. **Given** the iPhone, **When** the person long-presses a tile, **Then** Hide, Remove and
   Open Keeper are offered.

---

### User Story 4 - The Dashboard on the phone and in the browser (Priority: P2)

Away from the Mac, the person opens the project in Agents on the iPhone. A **Dashboard** row
above Sessions shows a one-line summary, such as "1 needs a look · Open bugs 4". Tapping it
opens the tiles in one column. In a browser on the Mac, the web page has the same Dashboard
row and grid as the window.

**Why this priority**: The person reads the Dashboard where they are. The parity rule asks
for the web page in the same change.

**Independent Test**: With tiles set in a scratch project, open the project on the web page
and check the row, the tiles, greying, Hide, Show and Remove; check the Remote builds and
shows the same tiles.

**Acceptance Scenarios**:

1. **Given** tiles in a project, **When** the person opens the project on the Remote, **Then**
   a Dashboard row above Sessions shows the worst live status and the first number.
2. **Given** the Remote's Dashboard, **When** a table has more than five rows, **Then** five are
   shown with a way to see them all.
3. **Given** the web page, **When** the person opens the Dashboard row, **Then** the tiles show
   in the chat's place, as on the Mac, with Hide, Show and Remove.
4. **Given** any client showing the Dashboard, **When** an agent sets a tile, **Then** the
   change shows without the person reloading.

---

### User Story 5 - Agents read each other's tiles and carry them on (Priority: P3)

A project lead is continued by a successor. The successor reads the Dashboard, finds the
tiles its predecessor kept, and keeps updating them as their keeper. A workflow's runs share
the workflow's tiles, so each night's new agent updates the same "Tests passing" tile rather
than making another.

**Why this priority**: Without it, tiles are orphaned every time a session ends, and
Dashboards fill with copies.

**Independent Test**: Continue a session that keeps a tile, and have the successor set it;
run a workflow twice and check both runs update one tile.

**Acceptance Scenarios**:

1. **Given** a session that keeps tiles, **When** it is continued by a successor, **Then** the
   successor can set those tiles, and is shown as their keeper.
2. **Given** a workflow that starts a new agent each run, **When** two runs set the same tile
   id, **Then** there is one tile, kept by the workflow.
3. **Given** a tile whose keeper is archived, **When** another agent sets it asking to take
   it over, **Then** it becomes the keeper, and the handover is recorded in the tile's detail.
4. **Given** any agent in the project, **When** it reads the Dashboard, **Then** it gets every
   tile with its value, keeper, age, hidden state and its most recent values.

### Edge Cases

- **Two agents set tiles at the same moment**: both succeed or are refused in full. No tile
  file is ever half-written or a mix of two posts.
- **A tile file is edited by hand, or changed by a pull**: the Dashboard shows the file's
  content, and the tile's detail says it was changed outside Agents. The keeper's next post
  overwrites it.
- **A tile file doesn't parse**: the tile shows as broken with the reason, as an unreadable
  workflow does; the rest of the Dashboard is unaffected.
- **A worktree's copy of `.agents/dashboard/`**: never read and never written by the app.
- **The project folder is missing** (#119): setting a tile is refused in words, naming the
  folder; the Dashboard shows the missing-folder strip like the rest of the project.
- **Limits**: a post over a limit (tiles in the project, table size, note size, the project's
  history size, posts an hour) is refused in words naming the limit; nothing is written.
- **A clone on another host**: tiles show their current values from the files, with no history
  and "age unknown", greyed, until their keepers next set them there.
- **The host is down**: clients show the Dashboard as they show the rest of the project when
  its host doesn't answer; Hide, Show and Remove are off.
- **A tile links to a session that was retired or a file that was deleted**: the link says so
  when opened.
- **An id another keeper holds, whose keeper is still active**: refused, naming the keeper.

## Requirements *(mandatory)*

### Functional Requirements

**Tiles and their types**

- **FR-001**: Each project MUST have one Dashboard, made of tiles. A tile MUST have an id
  unique in the project (1–40 lowercase letters, digits, `_` and `-`), a title, a type, a
  keeper, a source, a stale-after time, a hidden flag, and optionally a section.
- **FR-002**: The types in this slice MUST be:
  - **number**: one number with an optional unit, and whether up or down is good. Each set
    records a point. It is shown with its change since a day ago and a trend line over up to
    30 days.
  - **status**: ok, warn, bad or unknown, a short line, and optionally since when.
  - **table**: up to 6 columns and 50 rows of short text (200 characters a cell). A cell may
    be a link.
  - **note**: Markdown up to 4 KB, shown as a chat message is, without images.
  - **link**: a web address, a session in the project, a file in the project or a workflow,
    with a title. A session, file or workflow link opens in the app.
- **FR-003**: A source line saying where the value came from MUST be required for number and
  table tiles, and shown in the tile's detail.

**How agents write**

- **FR-004**: Every agent the app starts, helpers included, MUST have three tools:
  `set_tile` (create or replace a tile the caller keeps), `remove_tile` (remove a tile the
  caller keeps) and `read_dashboard` (every tile in the project, with value, keeper, age,
  hidden state and its last 10 points).
- **FR-005**: The app MUST answer these tools itself; the person is not asked, as for
  `show_file`.
- **FR-006**: Each `set_tile` MUST be checked (type, sizes, limits, keeper) before anything is
  written, and refused in words when it fails, naming what is wrong.
- **FR-007**: An agent MUST NOT be able to set or remove a tile kept by another keeper, unless
  that keeper is archived or retired and the agent asks to take it over.
- **FR-008**: The tools' answer to a set MUST include the tile as stored, and say when the tile
  is hidden, or when it had been removed by the person (who and when) and is now back.
- **FR-009**: An agent MUST be limited to 120 `set_tile` calls an hour.

**Keepers**

- **FR-010**: A tile's keeper MUST be the calling agent; or, for an agent started by a
  workflow, that workflow, so all its runs keep the same tiles.
- **FR-011**: A session continued by a successor MUST pass its tiles to the successor.
- **FR-012**: A change of keeper MUST be recorded and shown in the tile's detail.

**Where tiles live**

- **FR-013**: Each tile's current state MUST be stored as one file in the project folder's
  `.agents/dashboard/` folder, named by the tile's id, so it can be committed and reviewed.
- **FR-014**: Tile files MUST be written only in the project folder, never in a worktree's
  copy, wherever the agent works. A worktree's copy MUST never be read.
- **FR-015**: A tile file MUST hold no timestamps and no history, so that setting the same
  value again does not change it.
- **FR-016**: Writes MUST be whole: a tile file is never seen half-written, and two posts at
  once never mix.
- **FR-017**: The app MUST NOT commit tile files. Changed files stay as changes in the project
  folder.
- **FR-018**: The app MUST read tile files changed outside its tools (by hand or by a pull),
  show them, and mark them "changed outside Agents" in the tile's detail. A file that doesn't
  parse MUST show as a broken tile with the reason.
- **FR-019**: When each tile was last set, its history of points, and who removed what and
  when MUST be kept by the host, not in the project.

**History and limits**

- **FR-020**: A number tile's points MUST be kept: every point (at most one a minute) for 7
  days, one an hour to 90 days, one a day to a year, then dropped.
- **FR-021**: A project MUST hold at most 60 tiles (hidden ones count), and at most 8 MB of
  history on its host. A tile file MUST be at most 8 KB.
- **FR-022**: Moving a project to another machine MUST carry its Dashboard history with it.
  Archiving a project MUST keep its Dashboard. Removing a project MUST delete the host's
  history and leave the project's files alone.

**Staleness**

- **FR-023**: Each tile MUST have a stale-after time, given by its keeper, from 1 hour to 7
  days, 24 hours if not given.
- **FR-024**: A tile past its stale-after time MUST be greyed on every client, with its age in
  words ("2 days old"). A stale status tile MUST show as unknown, without colour.
- **FR-025**: A tile whose keeper is archived or retired MUST say so at its foot.
- **FR-026**: The Dashboard row's summary and its alert MUST ignore stale tiles.

**The person's controls**

- **FR-027**: The person MUST be able to hide a tile, see hidden tiles, and show a hidden
  tile again. Hiding MUST be stored in the tile's file, and MUST survive the keeper's posts.
- **FR-028**: The person MUST be able to remove a tile, which deletes its file and history. The
  keeper's next set MUST bring it back, and tell the keeper (FR-008).
- **FR-029**: Every client MUST be able to hide, show and remove, following the one-grant
  decision; there is no person-only or device-only setting.
- **FR-030**: Each tile MUST name its keeper; picking the keeper MUST open that session or
  workflow.

**Where it shows**

- **FR-031**: On the Mac, a **Dashboard** row MUST sit at the top of each project's sessions
  column, with the number of tiles and a red mark when a live tile is bad. Picking it MUST
  show the Dashboard in the chat's place, as a workflow's page is shown, as a grid of tiles
  grouped by section in the order they were made.
- **FR-032**: On the iPhone and iPad, a Dashboard row MUST sit at the top of the project page,
  above Sessions, with a one-line summary (the worst live status, the first number). It MUST
  open the tiles in one column, number tiles two across, tables to their first 5 rows with a
  way to see all. Long-press MUST offer Hide, Remove and Open Keeper.
- **FR-033**: The web page MUST have the Mac's Dashboard row, grid, detail, greying and Hide,
  Show and Remove.
- **FR-034**: Every client MUST show changes to the Dashboard as they happen, without a reload.
- **FR-035**: A tile's detail MUST show its source, keeper (and changes of keeper), whether it
  was changed outside Agents, and its last 10 values with their times.

**Agents' briefing**

- **FR-036**: Every agent's briefing MUST say when to keep a tile ("if you keep something the
  person checks often, keep it as a tile"), and that `.agents/dashboard/` is written only
  through the tools, never by hand and never in a worktree.

**Out of scope in this slice**

- **FR-037**: This slice MUST NOT include charts with several lines or bars, tiles counted from
  events, reordering, built-in tiles, or tiles the person makes by hand.

### Key Entities

- **Dashboard**: one per project; its tiles, in sections, in the order they were made.
- **Tile**: id, title, type, value (by type), section, keeper, source, stale-after, hidden.
  Its file in the project holds these; the host holds when it was last set.
- **Keeper**: who may set a tile: an agent, or a workflow. Has a history of changes.
- **Point**: one recorded value of a number tile, with its time; held by the host.
- **Removal note**: who removed which tile and when, held by the host for 30 days, so the
  keeper can be told on its next set.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A tile an agent sets appears on an open Dashboard on every client within 2
  seconds.
- **SC-002**: The Dashboard with 60 tiles opens on the Mac in under a quarter of a second,
  and the host's part of it takes under a tenth of a second (added to the perf budgets).
- **SC-003**: Setting an unchanged value an hour for a week leaves the tile's file unchanged
  in git: zero changes.
- **SC-004**: In a test of 100 posts at once from 5 agents, no tile file is ever half-written
  or mixed.
- **SC-005**: A project lead can replace the queue-and-ship prose in its memory with
  Dashboard tiles, and the person can tell what is merged, shipped and live from the
  Dashboard alone, without opening a session.
- **SC-006**: Every stale tile is greyed on all three clients; none shows a coloured status
  past its stale-after time.

## Docs *(mandatory)*

- `docs/reference/agent-tools.md` — change: add `set_tile`, `remove_tile` and `read_dashboard`.
- `docs/how-to/keep-a-project-dashboard.md` — add: what a Dashboard is, how agents keep
  tiles, reading it on the Mac, phone and web page, hiding, showing and removing, what grey
  means, and the files in `.agents/dashboard/`.
- `docs/reference/dashboard-tiles.md` — add: each tile type, its fields and limits, staleness,
  keepers, and history retention.
- `docs/explanation/projects-hosts-worktrees.md` — change: `.agents/dashboard/` is written in
  the project folder only, never a worktree, and the app does not commit it.
- `specs/071-web-remote/walks/parity.md` — change: a row for the Dashboard.

## Assumptions

- Writing tile files in the project folder is the app's own write, made through tools it
  answers, as `manage_workflows` writes `.agents/workflows/`. It needs no permission prompt,
  and is limited to `.agents/dashboard/`.
- "The project folder" is the folder the project was added as; for a project on a server,
  the folder on that server.
- Section order and tile order within a section are the order in which tiles were first made;
  the person can't change it in this slice.
- A tile's change "since a day ago" compares with the last point at least 24 hours old; with
  none, the change since the first point is shown.
- The phone shows 7-day and 30-day trends only; the Mac and the web page show up to 30 days in
  a number tile.
- Agents learn of the Dashboard from their briefing and the tool descriptions; no agent is
  started to keep tiles by this feature. Seeding the lead's, the nightly and a bug-count
  Dashboard is follow-on work.
- The parity rule is met by building the web page in the same change.
