# Walk: the page's one sidebar (#151)

**Date:** 2026-10-03

**What it covers:** the web page brought in step with the window's one sidebar (#145). The window's
shots are in `specs/145-one-sidebar/walks/`; these are the page's, numbered to match where they can.

**Set-up:** a run-app scratch root, `/tmp/run-151`, with its host and control plane (no window), and a
second host, `build-box`, on `/tmp/run-151r`, joined to the same control plane with
`agentsd --control-code … --host-name build-box`. Seeded as the window's walk was:
- This Mac: *Agents* (two Needs you, Done with two unread, Paused, two archived, two workflows that are
  off), *website* and *infra-tools*.
- `build-box`: *api-server* (Needs you, Done with one unread, one archived).

The page was driven in headless Chrome, at 1280 × 900 unless a shot says otherwise, by
`node Web/test/walk/sidebar.mjs <WEB_URL> <browser code> <out dir> [offline]`. What it read off the
page is in `notes.txt`.

## Widths

- **760 px and up: one sidebar, then the chat.** This is the window's layout. The sidebar is 300 px
  wide, and 260 px below 1200 px. From 1440 px the files pane is a third column; below that it lies over
  the chat, as before.
- **760 to 1200 px:** chose the sidebar here too, in place of the old sessions column with its
  projects menu. At 760 px a 260 px sidebar leaves 500 px for the chat, which is enough. One layout
  for every width that has room for a sidebar keeps the two in step, and the projects menu was the
  thing #145 replaced.
- **Below 760 px:** unchanged (web: by design). The page drills project → sessions → chat one
  column at a time, as the iPhone Remote does (`13-width-390.png`).

## What was seen

| Shot | Window | What it shows |
|---|---|---|
| `1-folded-nothing-selected.png` | `1-folded-nothing-selected.png` | Activity at the top: Events (*Last 12:22*), Resources, Runtimes and Spending. Each project is folded, with its counts (*Needs you · 1 unread*) and the red dot. The server's project reads `build-box:api-server`. With nothing selected, the detail shows the help text and the keys. Two columns. |
| `2-unfolded.png` | `2-unfolded.png` | *Agents* and *build-box:api-server* unfolded: Needs you, Done (with its unread count), Paused, *Archived sessions 2* folded, and Workflows. An unfolded project's row drops its counts, as the window's does. |
| `3-session-selected.png` | `3-session-selected.png` | A session picked: its row lights and its chat opens. |
| `4-project-dashboard.png` | `4-project-dashboard.png` | A project's row picked: only that row lights, and its Dashboard opens with ✎ New Session in its head. |
| `5-reloaded-folds-kept.png` | `5-relaunched-folds-kept.png` | The page reloaded: the same projects are still unfolded (localStorage, `agents.sidebar.folds`). |
| `6-archived.png` | `6-archived.png` | *Archived sessions* opened under *Agents*. Opening and closing it is remembered too. |
| `7-workflow-selected.png` | `7-workflow-selected.png` | A workflow picked: its row lights and its page opens. In the sidebar a workflow's row says *Off* where it stands; Run Now is on its page. |
| `8-activity-events.png`, `8-activity-runtimes.png` | — | Activity pages in the chat's place: events from every host, newest first, with the host named when there are several; each runtime's availability and pool note. Resources and Spending are the same shape. All are read-only: changing them is the Mac's. |
| `9-keys-folded.png` | — | ← on a project row folds it. → unfolds it again. |
| `10-session-menu.png` | — | The menu key on a session row: Park, Mark as Unread / Read, Archive. These are the chat's ··· actions. Mark as Unread was chosen, and the Done heading went from 1 to 2 unread. |
| `11-project-menu.png`, `12-new-session.png` | — | A right click on a project row offers Dashboard and New Session. New Session opens the project's new-session form. |
| `13-width-1600.png`, `13-width-1000.png`, `13-width-760.png`, `13-width-390.png` | — | Sidebar and chat at 1600, 1000 and 760 px. One column at 390 px. Nothing scrolls sideways. |
| `14-server-offline.png` | — | `build-box`'s host paused with SIGSTOP: *build-box is offline* at the sidebar's foot, above the browser's own line. |

## Keys

Walked, and read in `notes.txt`:
- ↓ from Events goes through Resources, Runtimes, Spending, *Agents* (its Dashboard opens), then the
  first session (its chat opens). The list's selection follows the keys, as the window's does.
- ← on an unfolded project folds it, and → unfolds it. ← on a row under a project goes to the project.
- The menu key opens a session row's menu.

Built but not walked: → and ← on an Archived fold, Home and End, Shift-F10, and ↑, ↓ and Escape
inside a menu.

## Differences from the window, and why

- **No *Keeping this Mac awake* line.** The page is not told the Mac's wake state. The foot holds the
  host notices and the browser's own line (*Chrome on this Mac · Forget This Browser…*).
- **The project menu has Dashboard and New Session only.** Project Settings, Archive and Show in
  Finder are the Mac's (web: by design, as Settings already was).
- **Runtimes counts what the pool left out** (`poolNote`). The window counts runtimes whose allowance
  is spent, and the page is not sent allowances.
- **A server that is already down when the page opens** has no projects listed until it answers.
  This was true before this change too. A page that had them keeps them, greyed.
- **⌘F, ⌫ and choosing several rows** are not on the page. The browser keeps ⌘F for itself.

## Not walked

- Safari (needs Alex's go-ahead).
- This Mac's host down, at the foot. It uses the same words and code as the old projects column (#83).
