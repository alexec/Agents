---
diataxis: how-to
devices: [mac, iphone, ipad, browser]
description: Read a project's Dashboard, the tiles its agents keep, and decide what stays on it.
---

# Keep a project Dashboard

Every project has a **Dashboard**: one page of tiles its agents keep, such as how many bugs
are open, what is live, or which lanes are running. Agents decide what goes on it. You read it
and decide what stays.

## Open it

- **On the Mac**, pick a project. The **Dashboard** row sits at the top of the sessions
  column, above the sessions. It says how many tiles there are and the line worth a glance,
  such as "1 to watch · Open bugs 4". A red dot means a tile is **bad**. Picking it shows the
  Dashboard where a chat would be.
- **On the iPhone or iPad**, open the project. The **Dashboard** row is above Sessions. Tap it
  for the tiles in one column.
- **In a browser**, the web page has the same row and page as the Mac.

The Dashboard changes as agents set tiles. You don't need to reload it.

## Bring it up to date now

**Update now**, at the top of the Dashboard (on the phone, the ↻ in the toolbar), asks an agent to
set the tiles again there and then, rather than waiting for their keepers:

- If the project has a workflow labelled `dashboard`, such as the nightly **Update the
  dashboard**, it runs that workflow once, as **Run now** on its page would. It runs even when the
  workflow is off. While the workflow's file waits for your approval, or it is past a limit,
  nothing starts. The line under the title says why and opens the workflow.
- With no such workflow, it starts an agent of its own, **Update the dashboard**. That agent sets
  each tile again from the `source` its keeper gave it, and leaves alone any tile it can't read.

While it runs, the button reads **Updating…** and the tiles change as they're set. The line under
the title says when the last update started, and links to its session if it did not finish. Update
now works once every 5 minutes, and only one runs at a time. Every device has the button.


Each tile has a title, its value and a foot naming who keeps it and how old it is:

| Tile | Shows |
| --- | --- |
| Number | The number, its change since a day ago (▲2, ▼1, green when the change is good news) and a line of its trend. |
| Status | A light (green ok, orange warn, red bad) and a line. |
| Table | Up to 6 columns. The phone shows the first 5 rows; tap for all of them. |
| Note | A short piece of Markdown. |
| Link | A web page, a session, a workflow or a file in the project. |
| Page | A document or an HTML page from the project, live: its top, with **Open** for the rest. Never grey. See [Pin a page to a project](pin-a-page-to-a-project.md). |

Click the keeper's name in a tile's foot to open its session or workflow. On the Mac, double-click a tile, or pick **Details…** from its **···**
menu, for where its value came from, who has kept it, whether its file was changed outside
Agents, and its last 10 values.

**A grey tile is out of date.** Every tile has its own time, a day unless its keeper said
otherwise. A tile not set again within it turns grey and says how old it is ("2 days old"). A
grey status light shows no colour, so a green that nobody has confirmed stops saying all is
well. Grey tiles don't count towards the row's line or its red dot.

## Decide what stays

From a tile's **···** menu (or its context menu on the Mac, a long press on the phone):

- **Hide** takes a tile off the Dashboard on every device. Its keeper goes on updating it.
  **Show Hidden Tiles** in the Dashboard's menu (the web page's check box) shows hidden
  tiles, and **Show** puts one back. Use it for a tile that is right but not interesting.
- **Remove** deletes the tile and its history. If its keeper sets it again, it comes back,
  and the keeper is told you removed it, and when. Use it for a tile nobody keeps any more, or
  one set by mistake. To keep a tile that is still kept off the Dashboard, hide it.
- **Open Keeper** opens the session or workflow that keeps it. To correct a number, tell its
  keeper.

Every device can hide, show and remove.

## Ask an agent to keep tiles

Agents are told to keep what you check often as tiles, with the `set_tile` tool. You can ask
for one directly, for example: "Keep a tile of how many bugs are open, from `gh issue list -l
bug --state open`, and update it when you finish a turn." An agent a workflow starts keeps its
tiles for the workflow, so each run updates the same tiles. An agent carrying on another
session's work can take over that session's tiles once it has read it.

See [Dashboard tiles](../reference/dashboard-tiles.md) for every field and limit.

## Where tiles are kept

Each tile is a file in the project, `.agents/dashboard/<id>.json`, beside
`.agents/workflows/`. The app writes it whole, only through the agents' tools, and only in the
project folder, never in a worktree. A file changes only when a value does, so setting the
same number every hour changes nothing in git. The app never commits these files. They show
in the project's changes and go in with whatever is committed next.

A number's trend is kept in the project too, in `.agents/dashboard/history/<id>.jsonl`: each
hour's last point for a week, then each day's last to 90 days, and nothing written while the
number holds still. A clone on another machine shows the trends. To keep them out of the
repository, add `.agents/dashboard/history/` to `.gitignore`.

When each tile was last set and who removed what are kept by the host the project is on, not
in the project. A clone on another machine shows the tiles' values greyed, with "age
unknown", until their keepers set them there.
