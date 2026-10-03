---
diataxis: reference
devices: [mac, iphone, ipad, browser, server]
description: Every Dashboard tile type, its fields and limits, keepers, staleness and history.
---

# Dashboard tiles

A project's Dashboard is made of tiles that agents keep with `set_tile` (see
[Tools the app gives agents](agent-tools.md)). How to read it and prune it is in
[Keep a project Dashboard](../how-to/keep-a-project-dashboard.md).

## Every tile

| Field | Rule |
| --- | --- |
| `id` | 1 to 40 lowercase letters, digits, `_` and `-`, unique in the project. It is the file's name. |
| `title` | Up to 80 characters. |
| `type` | `number`, `status`, `table`, `note` or `link`. |
| `section` | Optional, up to 40 characters. Tiles are grouped under it. |
| `source` | Where the value came from, in one line, up to 200 characters. Required for `number` and `table`. |
| `stale_after_hours` | 1 to 168. Past it without a set, the tile is greyed. 24 if not given. |

## By type

| Type | Fields | Limits |
| --- | --- | --- |
| `number` | `value`, `unit`, `good` (`up` or `down`) | `unit` up to 12 characters. Each set records a point. |
| `status` | `level` (`ok`, `warn`, `bad`, `unknown`), `line`, `since` | `line` up to 200 characters, `since` up to 40. |
| `table` | `columns`, `rows` | 1 to 6 columns, up to 50 rows, 200 characters a cell. A cell is text, or `{"text", "url"}` for a link. |
| `note` | `markdown` | 4 KB. Shown as a chat message is, without images. |
| `link` | one of `url` (http or https), `session` (an id), `file` (a path in the project), `workflow` (an id) | The tile's title names it. |

A tile's file is at most 8 KB. A project holds at most 60 tiles, hidden ones included. An agent
may set at most 120 tiles an hour. A refused call says which limit, and nothing is written.

## Keepers

- A tile is kept by the agent that set it, or, for an agent a workflow started, by that
  workflow, so all its runs keep the same tiles.
- Only its keeper can set or remove it. Another agent is refused, with the keeper named.
- With `take_over`, an agent can become the keeper of a tile whose keeper is archived or
  retired, or of a tile kept by a session it has read with `read_session` and that is not
  working (065's way of carrying a session on). The handover shows in the tile's detail.

## Staleness

A tile not set within its `stale_after_hours` is greyed on every device, and its foot says how
old it is. A greyed status shows no colour. A tile whose keeper is archived or retired says so
at its foot. Greyed tiles don't count towards the Dashboard row's summary or its red dot.

## The file

`<project>/.agents/dashboard/<id>.json`, written whole by the host in the project folder, never
in a worktree, keys sorted. It holds the fields above, the keeper (`{"agent": "<id>"}` or
`{"workflow": "<id>"}`), `hidden` when you hid it, and the value under the type's name. It
holds no times and no history (its trend has a file of its own, below), so setting the same
value again leaves it as it is. A file
edited by hand or brought by a pull is shown, marked "changed outside Agents" in the tile's
detail; the keeper's next set overwrites it. A file that can't be read shows as a broken tile
with the reason.

## History

A number tile's trend is kept in the project, beside its tile, in
`<project>/.agents/dashboard/history/<id>.jsonl`: one point a line, `{"t":<seconds since
1970>,"v":<value>}`, written by the host in the project folder, never in a worktree. So the
trend goes wherever the project goes, and a clone on another Mac or server shows it.

| Age | Kept |
| --- | --- |
| Up to 7 days | The last point of each hour. A second set in the same hour replaces that hour's point. |
| 7 to 90 days | The last point of each day. |
| Over 90 days | Nothing. |

That is at most about 250 lines, some 6 KB, a tile. The file changes only when the trend does:

- a set whose value is the one the trend already ends at adds no point, so a number that
  holds still never touches the file;
- a run of equal values is kept as its first point, the moment the value became what it is;
- the file is rewritten only when its bytes change.

The app never commits it. It shows in the project's changes and goes in with whatever is
committed next. To keep trends out of the repository, add `.agents/dashboard/history/` to
`.gitignore`: the app still keeps them in the folder, and a clone starts its trends empty.
A history file changed by a pull is read again.

At most 8 MB of history a project; past it, a number tile's set is refused until a tile is
removed. A screen is sent at most 120 points a tile, over 30 days. Removing a tile deletes its
history file. Before this version the trend was kept by the host, in `dashboards/` in its
root; the first time a tile's trend is read, those points are folded as above, moved into the
project's file and removed from the host. Who removed a tile, and when, is kept 30 days, only to tell its keeper.
