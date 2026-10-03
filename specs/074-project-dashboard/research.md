# Research: Project Dashboard, slice 1

The design work is in [`specs/research/122-project-board.md`](../research/122-project-board.md). This
file settles the points the spec leaves to the plan.

## R1. How a successor is known

- **Decision**: a caller may take a tile over (`take_over: true`) when its keeper is an agent that
  is archived or retired, **or** an agent whose session the caller has read with `read_session`
  and that is not working now. The second is how 065 continues a session: the person starts a new
  chat and names the one to carry on, and the new agent reads it. The daemon remembers, in memory,
  which sessions each agent has read; after a restart the successor reads again. The handover is
  recorded as a keeper change.
- **Rationale**: 065 removed the pool and **Continue with**; there is no successor link on the
  record. `agents/continueInProject` (#119) starts a successor whose prompt tells it to read the
  old session, so it is covered by the same rule.
- **Alternatives**: a `continues` field on `Agent` (a record change for one feature, and only
  #119's path would set it); letting anyone take over a finished agent's tiles (a helper could
  silently take the lead's).

## R2. Sparklines without Swift Charts

- **Decision**: a SwiftUI `Path` through the points, shared by the Mac and the Remote; an SVG
  `polyline` on the web page.
- **Rationale**: one thin line needs no axes, legends or interaction. Swift Charts arrives with
  slice 2's `series` charts if it is wanted then.
- **Alternatives**: Swift Charts now (more to load for a line).

## R3. The tile file

- **Decision**: JSON, keys sorted, two-space indent, trailing newline, at most 8 KB. The keeper is
  `{"agent": "<uuid>"}` or `{"workflow": "<id>"}`; names are looked up when drawn, so renaming a
  session does not touch the file. The value sits under one key named for the type
  (`"number": {...}`).
- **Rationale**: sorted keys make the bytes a function of the content, so "same value, same file"
  (FR-015, SC-003) is a byte comparison before the write.

## R4. Host state and its key

- **Decision**: `<root>/dashboards/<key>/` where `key` is the first 16 hex characters of SHA-256 of
  the standardized project path. `state.json` holds, per tile: when it was made (the order), when
  last set, the hash of the host's last write, keeper changes; plus removal notes (30 days) and
  each agent's sets in the last hour. `points/<id>.jsonl` holds `{"t": <unix s>, "v": <number>}`
  per line.
- **Rationale**: the same shape as `events.jsonl` and `EventStore`'s state. A hash keeps the path
  short and the same on every host's root.

## R5. Compaction

- **Decision**: on append, a point in the same minute as the last replaces it. On the host's
  existing housekeeping tick (`DaemonCore+Retention`), points older than 7 days fold to the hour's
  last, older than 90 days to the day's last, older than a year go; the file is rewritten by temp
  file and rename. Never on a read.

## R6. Telling clients

- **Decision**: `dashboard/changed` carries `{folder}` only, at most once a second per project
  (trailing edge). A client showing that project's Dashboard, or its row, asks `dashboard/get`
  again. The row's summary (`tileCount`, `bad`, `summary`) rides on `dashboard/get` and on a
  small `dashboard/summaries` for every project, read once at start.
- **Rationale**: tiles are small, but 60 tiles with points in every notification to every phone is
  waste. The person's view asks for what it shows.

## R7. Seeing outside changes

- **Decision**: the workflows' `FolderWatch` on the project root already fires for every path
  under `/.agents`. Its callback also schedules a Dashboard rescan when a changed path starts with
  `<folder>/.agents/dashboard/` (so a worktree's `.agents/worktrees/x/.agents/dashboard/` never
  counts). A file whose SHA-256 differs from the host's last write is "changed outside Agents".

## R8. Where the person's controls go

- **Decision**: `dashboard/hide` and `dashboard/show` rewrite the file with `hidden` flipped (and
  record the new hash). `dashboard/remove` deletes the file and points, and keeps a removal note:
  who (the person, on which surface if the connection says) and when, for 30 days.

## R9. Servers and moving projects

- **Decision**: the store is plain Foundation, so the Linux agentsd has it. Clients route
  `dashboard/*` by host as they route `workflows/*`. Moving a project (#61) copies
  `dashboards/<old key>/` to the new key; removing a project deletes it.
