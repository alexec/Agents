# Contract: The Mac window

Bound to [wireframes.md](../wireframes.md). This fixes behaviour and state; the drawings fix
layout. The **Words** table in wireframes.md is the source for every string.

## Project list (`ProjectListView`)

- With **only** `.mac` in `HostSet`, the list is exactly today's. There are no headings.
- With any server, one section per host in this order: This Mac, then servers in the order they
  were added. Heading = label uppercased + state mark:

  | HostState | Mark |
  |---|---|
  | connected | green dot, no word |
  | connecting | spinner, no word |
  | offline(since) | grey dot, `Offline · HH:mm` |
  | updateWaiting | orange dot, `Update waiting` |
  | failed | red dot, `Can't connect` |

- Rows of an offline host are drawn with `.secondary` foreground. They stay selectable.
- Context menu on a server project: no **Show in Finder**. **Archive** is disabled while offline.
- Archived projects keep their host section.

## New project menu

- No servers: `Choose Folder…`, `Clone Git URL…`, divider, `Add a server…`.
- Servers: `This Mac ▸`, one `<label> ▸` per server (disabled with `Offline` when not
  connected), divider, `Add a server…`. Each submenu holds the same two items.
- Clone on a server calls that host's `projects/clone`. The destination line reads
  `Clones into ~/<name> on <label> and adds it as a project.`
- Choose Folder on a server opens `RemoteFolderSheet`. It is backed by `files/list` on that
  host, starts at `ServerFacts.home`, and lists folders first. **Add as project** calls
  `projects/add` on that host.

## Add a server (`AddServerSheet`)

States A–D and C′ as drawn. Transitions:

| From | Event | To |
|---|---|---|
| A | Connect (field valid) | connecting: connect |
| connect | key unknown | B |
| B | Trust and continue | connecting: checkSystem |
| B / any | Cancel | dismissed, temporary files removed, nothing left on the server |
| connect | key known and master up | checkSystem → setUp → findRuntimes |
| findRuntimes | ≥ 1 runtime available | C |
| findRuntimes | 0 | C′ |
| any step | HostProblem | D, field keeps its text, Try again returns to connect |
| D(hostKeyChanged) | — | no Try again button |

The host record is written only on reaching C or C′. **Open terminal on <label>** opens a
terminal (`shell/attach`) in the server's home folder in the right pane. **Check again**
re-runs `runtimes/list`.

## A server project

- Detail header adds `on <label>` in `fine` before the path.
- Files pane, image preview and workflow page go through `ProjectFiles.remote(host)`
  (`files/list`, `files/read`, `files/watch`). Live pages load through `agents-file://`.
- Attachments: dropped files are sent with `files/write` into
  `<project>/.agents/attachments/<uuid>-<name>`, then referenced by that path. Over 25 MB →
  `That file is too big to send to <label>.`
- **Open in…**, **Show in Finder** and **Keep awake** are not shown.

## Offline (`OfflineStrip`)

- Shown at the top of the chat when the agent's host is `offline`.
- `Next try in N s` counts down to `HostSet`'s next attempt. **Try now** triggers it.
- Send is disabled with the tooltip `<label> is offline`. The draft is kept in the field.
  Permission and question cards are shown, but their buttons are disabled with the same tooltip.
- Agent rows show `as of HH:mm` instead of the live time.
- On reconnect the strip is removed, with no animation beyond the default and no toast.

## Sending across a drop

- Send makes a `requestID`. If the call fails with a transport error, the bubble shows
  `Sending…` and the call is retried with the same ID on reconnect for up to 30 s. After that,
  the bubble is removed, the text is put back into the prompt field, and the fine line under the
  field reads `Not sent — <label> went offline.`

## Settings ▸ Servers (`ServersSettingsView`)

- A tab after Devices, with the `server.rack` symbol.
- Rows as drawn. The subtitle is built from `ServerFacts` and state. The selected row shows
  **Check again** (re-probe + `runtimes/list`) and **Remove…**.
- The Remove dialog uses `daemon/status.agentsLive` for its number, and its checkbox sets whether
  step 8's `rm -rf` runs.
- The **+** button opens `AddServerSheet`.
- Footer: `Servers are reached with your own ssh setup. Nothing on them listens on a network
  port.`

## Spending

- The row's second line adds `· £X on servers` when any server has spent today.
- The Settings Spending page notes under the daily limit: `Each server keeps to this limit on
  its own.` (R7)
