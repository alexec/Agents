# 159: Pinned pages on a project

2026-10-03, branch `agents/build-github-issue-159`. Issue #159, with Alex's answers in its
comment. This note settles the shape. The look comes first, then the depth
([[settle-ux-before-building-depth]]).

## Summary

- **A project has pinned pages.** The Dashboard is the built-in one and is always first. Alex
  or an agent can pin any Markdown document or HTML page in the project beside it, such as a
  roadmap, a coverage report or a review. A project holds at most **10** pins.
- **They show under the project** in the sidebar on the Mac, on the Remote and on the web
  page. Picking one opens it in the chat's place, live as it changes, as `show_file` does in
  the files pane today.
- **Agents pin with tools**: `pin_page`, `unpin_page` and `move_pin`. People pin from the
  files pane, and unpin and drag pins in the sidebar.
- **One file holds them**, `.agents/pins.json` in the project folder, beside
  `.agents/dashboard/`. The host writes it, only through the tools and the clients' calls,
  never in a worktree.
- **A Dashboard tile can embed a page**: a new tile type, `page`, that shows a pinned or
  unpinned document from the project, live.
- **One difference on the web page:** an HTML pin shows as its source there, as the web
  page's files pane already shows HTML. The page's own policy allows no frames and no HTML
  of its own making, which is what keeps an agent's page from running in it. The Mac and
  the Remote draw it.
- **Tiles stay** the way data gets onto the Dashboard. A pin is a page; a tile is a value.

## Where pins are kept

One file in the project folder, `.agents/pins.json`, written whole by the host with keys
sorted, never in a worktree. The order of the list is the order shown.

```json
{
  "pins": [
    { "path": "docs/roadmap.md", "title": "Roadmap", "pinned_by": { "person": true } },
    { "path": "coverage/index.html", "pinned_by": { "agent": "8C1F…" } },
    { "path": "specs/159-pinned-pages/README.md", "pinned_by": { "workflow": "nightly-review" } }
  ]
}
```

- `path` is relative to the project folder, with `/` separators and no `..`. It is the pin's
  identity: a path is pinned once.
- `title` is optional, up to 60 characters. Without one the row shows the file's name
  without its extension (`roadmap`, `index`), or, for a file called `README.md` or
  `index.html`, its folder's name.
- `pinned_by` is who pinned it: the person (any client: one grant for every client), an
  agent, or the workflow an agent was started by, as a tile's keeper is.
- The file holds no times, so it changes only when the pins do. The app never commits it. It
  shows in the project's changes and goes in with whatever is committed next, so pins travel
  with the project, as tiles do.
- A file edited by hand or brought by a pull is read again. Entries it can't use (a bad path,
  a repeat, past the limit) are skipped, not deleted. The next write drops them.

An agent in a worktree pins a path in its worktree by the same relative path. The pin opens
the **project folder's** copy, which is where it lives once the branch lands. Until then the
row shows it as missing (below), and `pin_page` says so in its answer, so the agent can
choose to pin after the merge.

## The tools

Agents get three tools, alongside `set_tile` and `move_tile`. Each answers with the pins as
they are afterwards, numbered.

| Tool | Arguments | Does |
| --- | --- | --- |
| `pin_page` | `path`, optional `title`, optional `position` (`first` or `last`, `last` if not given) | Pins a Markdown (`.md`, `.markdown`) or HTML (`.html`, `.htm`) file in the project. Pinning a path already pinned changes only its title. |
| `unpin_page` | `path` | Unpins a page the agent pinned (or its workflow did). A pin made by the person or another agent is refused with who pinned it: "Nothing was unpinned: docs/roadmap.md was pinned by the person. Only the person, or whoever pinned it, can unpin it." |
| `move_pin` | `path`, and one of `before`, `after` (another pinned path) or `position` (`first`, `last`) | Moves any pin, as a person can drag any pin. The latest move wins. |

`read_dashboard` lists the pins before the tiles. The Dashboard itself can't be pinned,
unpinned or moved: it is always first.

People do the same from any client: the pin in the files pane's bar on a Markdown or HTML
file (Mac and web page), **Pin to Project** on a page opened from a page tile, and **Unpin**,
**Move Up** and **Move Down** in a pin's context menu, or a drag. A person can unpin any pin.

On the wire: `pins/list`, `pins/pin`, `pins/unpin`, `pins/arrange` (the whole order, once
per drop), `pins/read` and `pins/write` (any file in the project folder, its links resolved
and held inside it), and the notifications `pins/changed` (the pins, after any change or
when a pinned file comes or goes) and `pages/changed` (folders where a pinned page, a page
tile's file or one beside them changed, at most a few times a second).

## How a pin shows

Under its project in the sidebar, after the project's own row (which opens the Dashboard),
before its sessions, in their order:

```text
▾ Agents                       3
    📄 Roadmap
    🌐 Coverage
    📄 159 pinned pages
    ● Fix login…            Needs you
    ○ Raise issues…
```

- A Markdown pin has a document icon, an HTML pin a globe. The row is the title alone,
  and **Missing** when its file isn't there.
- Picking it opens it **in the chat's place**: the same live page the files pane uses
  (Markdown follows the file and takes typing; HTML is drawn with scripts and the network
  off, with Page and Source). Its bar says the title and the path, and has **Show in Finder**
  (a project on this Mac) and **Unpin**.
- **Drag** a pin among the pins to re-order it (Mac, web page; on the Remote, whose long
  press is the menu, **Move Up** and **Move Down**, as for tiles). A pin can't be dragged
  among sessions, and a session can't be dropped among pins.
- A folded project hides its pins with its sessions.

On the **Remote**, the project's page lists the Dashboard row, then the pins, then Sessions.
A pin opens the same live page as an agent's files do. On the **web page**, the sidebar is the
Mac's; a pin opens in the main column.

## When a pinned file is deleted or moved

The pin stays, and its row is dimmed with **Missing**. Opening it says "`docs/roadmap.md` isn't
in the project folder." with **Unpin**. If the file comes back (a pull, a branch landing, an
undo), the pin works again by itself. The host does not follow renames: an agent that moves a
pinned file pins the new path and unpins the old one. `read_dashboard` marks a missing pin, so
its pinner can tidy it.

## The limit

At most **10 pins a project**, the Dashboard not counted. Past it:

- `pin_page` is refused, with nothing written: "This project already has 10 pinned pages, the
  most it can have. Unpin one first, or ask the person which to unpin."
- The files pane's pin and **Pin to Project** are greyed, with the same reason as their help.

## The `page` tile

A new tile type, set with `set_tile` like any other:

| Type | Fields | Draws |
| --- | --- | --- |
| `page` | `file`: a Markdown or HTML path in the project | The page, live, two cells across, its top 300 pt (260 on the phone), with **Open** for the whole of it in the chat's place, as a pin opens. |

- The tile's value is the file, so it is never greyed: `stale_after_hours` doesn't apply.
- Markdown is drawn read-only, with pictures. HTML is drawn with scripts and the network off,
  as in the files pane, and as its source on the web page.
- A link tile's Markdown or HTML `file` opens in the chat's place too.
- A missing file shows as a broken tile with the path, as an unreadable tile file does.
- The file need not be pinned. Pinning and embedding are separate choices.

## Parity

The Mac, the Remote and the web page, from the start (AGENTS.md).

## Pinned workflows (#432)

A project's workflows can be pinned beside its pinned sessions (#180), so one run often by
hand is one click away.

- **Kept** in the same `.agents/pins.json`, as a `workflows` list of `{workflow, pinned_by}`
  after `sessions`, absent when empty so a file without them is the same bytes. `workflow`
  is the file name without `.md`. At most 10 a project, apart from pages and sessions.
  Written only by the host.
- **On the wire**: `pins/list` and `pins/changed` carry `workflows`, the ids in order;
  `pins/pinWorkflow`, `pins/unpinWorkflow` (`WorkflowRequest`) and `pins/arrangeWorkflows`
  (the whole order) are the person's, from every client. No agent tool pins a workflow.
- **Shown** in the project's Pinned group, after the pinned sessions, in their order, and
  out of the Workflows group. The row is the same row, with its Off mark, its status mark
  and Run Now on the web; choosing it opens the workflow's page. The heading counts both
  kinds and is tinted, folded, when a pinned workflow needs a person.
- **Pin / Unpin** on the row's menu, a leading swipe (Mac and Remote) and the workflow's
  page. Ordered by drag on the Mac, Move Up / Move Down on the Remote and the web.
- **Archived: unpinned.** Archiving a workflow takes its pin off, as archiving a session
  does, and Bring Back does not pin it again. An archived workflow can't be pinned. One
  archived by editing its file shows only under Archived workflows until it is unpinned.
  A workflow renamed or removed leaves an entry naming nothing, which no client shows.

## The look (2026-10-03)

Taken on a scratch root (run-app, `/tmp/run-pins159`) and in headless Chrome
(`Web/test/walk/pins.mjs`), in `look/`:

| Shot | What it shows |
| --- | --- |
| `mac-1-markdown-pin.png` | Three pins under the project, before its sessions; Roadmap open in the chat's place, with Show in Finder and Unpin. |
| `mac-2-followed-an-edit.png` | The same page after the file was appended to: it followed. |
| `mac-3-html-pin.png` | The HTML pin, drawn with its stylesheet, with Page and Source. |
| `mac-4-missing.png` | The file deleted: the row says Missing, the page says why, with Unpin. |
| `web-1-markdown-pin.png` | The web page's sidebar with the same pins; Roadmap open, live. |
| `web-2-followed-an-edit.png` | The page followed an edit made while it was open. |
| `web-3-html-pin.png` | The HTML pin as its source, saying why. |
| `web-4-dragged.png` | Security review dragged to the top; `.agents/pins.json` changed with it. |
| `mac-5-page-tile.png` | A `page` tile on the Dashboard, beside a number tile; the pins above the agent's session in the sidebar. |

A real Claude agent on the scratch root called `pin_page`, `move_pin` and `unpin_page`. That
found `unpin_page` being taken for `pin_page`, because tools are matched by the end of their
name and one ends with the other. It is fixed, with a test (`unpinPageIsNeverTakenForPinPage`).
