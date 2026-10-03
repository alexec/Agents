# Walk: one sidebar (#145)

**Date:** 2026-10-03

**Set-up:** a run-app scratch root, `/tmp/run-145`, with the window, its host and its control
plane, and a second host, `build-box`, on `/tmp/run-145r` that joined the same control plane
(`agentsd --control-code … --host-name build-box`).
- This Mac: three projects, *Agents*, *website* and *infra-tools*, with 14 sessions seeded
  from the test fixture (Needs you, Done with unread, Paused, archived) and two workflows.
- `build-box`: *api-server*, with three seeded sessions, and *Agents*, left over from
  a seeding slip. It shows two hosts with the same project name.
- One real Claude turn (`sleep 240`), so Working and *Keeping this Mac awake* show.

The window was looked at by window id (`screencapture -l`). Folds and selection were set over
AX (`ui.swift unfold`/`select`: AXDisclosing and AXSelected), with no clicks or keys.

## What was seen

| Shot | What it shows |
|---|---|
| `1-folded-nothing-selected.png` | Activity at the top. Every project folded, each with its counts (*Needs you · 2 unread*, *1 unread*) and the red dot. The server's project reads `build-box:api-server`. *Keeping this Mac awake* is at the foot. With nothing selected, the detail shows the help text. Two columns. |
| `2-unfolded.png` | *Agents* and *build-box:api-server* unfolded: Needs you, Working (with its background shell), Done (2 unread), Paused, *Archived sessions* folded, Workflows. An unfolded project's row drops its counts, because the rows under it show them. |
| `3-session-selected.png` | A session picked: its chat in the detail, titled with the session and its project, and the inspector toggle in the toolbar. |
| `5-relaunched-folds-kept.png` | The window quit and reopened: the same projects are still unfolded. The real turn has finished and parked itself, and *Today $0* has arrived on Spending. |
| `6-archived.png` | A session archived (over the socket): it leaves Done, and *Archived sessions* goes from 2 to 3. |

## Found and fixed during the walk

- **Picking a project lit its subheadings too.** The project's tag was on the
  `DisclosureGroup`, and a group's tag goes to every untagged row under it. The tag is now on
  the project's row only.

## Not yet walked

The screen locked part-way, and these need it unlocked:
- a project picked, showing its Dashboard (the first try is what showed the bug above);
- the keyboard: ↑/↓ through the list, ←/→ to fold and unfold, ⌘F, ⌫ on several sessions;
- the context menus: the project's *Dashboard / New Session / Project Settings… / Archive /
  Show in Finder*.
