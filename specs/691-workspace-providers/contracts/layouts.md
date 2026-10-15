# Layouts: what each screen shows

These are drawn in text, in the app's existing style. **They go to Alex for a decision before
any client code is written.** The rest of each screen is as it is today.

**Settled by Alex, 2026-10-12**:
- **L1**: the one-line strip.
- **L2**: Start or Stop, plus a `···` menu.
- **L3**: a Providers page of its own.
- **L4**: Add Provider starts by picking a kind. A grid (Docker Containers, DigitalOcean
  Droplets, GitHub Codespaces, Coder Workspaces, Google Cloud Workstations, Your own commands,
  An MCP server; #1026) leads to a short form for just that
  kind, with Back. The single form drawn below is what was not chosen; its fields stay, split
  by kind.

**Settled by Alex, 2026-10-12, for US3–US5**:
- **L6**: a kept prompt is a queued bubble, "Waiting for ‹host› to start · ×".
- **L6a**: a new agent started on a stopped host opens its chat at once, with its first
  prompt kept as in L6. The agent is made when the host connects; × drops it and the empty
  chat goes.
- **L8**: the scheduled-workflows warning is a line on the Hosts row.
- **L9**: New Workspace… is a button on the provider card, then a sheet and a confirmation.
  Delete Workspace… is in the Hosts row's `···` menu.

## L1. The offline strip, for a linked host (all three clients)

This is today's strip (`OfflineStrip`, `HostOfflineStrip`, `OfflineStrip.tsx`), with one
button and a phase. Its words are shared between the Mac and the Remote in `OfflineWords`;
the web page has the same words in `OfflineStrip.tsx`.

```text
Stopped
┌──────────────────────────────────────────────────────────────────────────────┐
│ ● devbox is stopped. Agents there are paused until it starts.       [Start]  │
└──────────────────────────────────────────────────────────────────────────────┘

Stopped by Agents
┌──────────────────────────────────────────────────────────────────────────────┐
│ ● devbox was stopped by Agents after 30 minutes idle.               [Start]  │
└──────────────────────────────────────────────────────────────────────────────┘

Starting (spinner in place of the dot)
┌──────────────────────────────────────────────────────────────────────────────┐
│ ◌ Starting devbox…                                                    0:24   │
└──────────────────────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────────────────────┐
│ ◌ Waiting for devbox to connect…                                      1:10   │
└──────────────────────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────────────────────┐
│ ◌ devbox started but agentsd didn't connect; starting it over ssh…    2:05   │
└──────────────────────────────────────────────────────────────────────────────┘

Failed
┌──────────────────────────────────────────────────────────────────────────────┐
│ ● Couldn't start devbox: "Error: droplet is locked" (DigitalOcean) [Start]   │
└──────────────────────────────────────────────────────────────────────────────┘

Offline, linked, but its workspace is running (it lost the network)
┌──────────────────────────────────────────────────────────────────────────────┐
│ ● devbox is offline since 14:02. Agents there keep working.        [Try now] │  (as today)
└──────────────────────────────────────────────────────────────────────────────┘
```

**Rules**:
- The timer counts up from the press, so the wait is visible.
- There is no Stop on the strip: the strip only shows while a host can't be reached.
- On the iPhone the strip wraps to two lines, and **Start** stays at the trailing edge.
- An unlinked host's strip is unchanged (US1 AS5).

## L2. Settings ▸ Control plane ▸ Hosts, a linked host's row (Mac)

```text
┌─ Hosts ───────────────────────────────────────────────────────────────────────────────┐
│ ● This Mac           Online · macOS · 0.9.2                         [Choose Projects…]│
│───────────────────────────────────────────────────────────────────────────────────────│
│ ● devbox             Online · Linux · 0.9.2 · DigitalOcean: agents-devbox             │
│                      Stops after 30 minutes idle                [Stop] [ ··· ]        │
│───────────────────────────────────────────────────────────────────────────────────────│
│ ○ build-box          Stopped · DigitalOcean: build-box · $0.03/h when running         │
│                      Starts when used                           [Start] [ ··· ]       │
│───────────────────────────────────────────────────────────────────────────────────────│
│ ○ old-server         Offline since 09:12 · Linux · 0.9.1        [Check again] [ ··· ] │
└───────────────────────────────────────────────────────────────────────────────────────┘
  [Add a Server…]  [Add by Code…]
```

- `···` is a menu holding Choose Projects…, Check again, Link to Workspace… or Unlink,
  Start when used ✓, Stop when idle ▸ (Off, 15, 30, 60 minutes, 2 hours), and Remove….
- Today's row has three buttons. Moving the rarer ones into `···` keeps a linked row to one
  main action and the menu.
- **Stop** asks first when turns are running: "Stop devbox? Claude (fix-login) and Codex
  (docs) are working there." with [Stop] [Cancel] (US4).

## L3. Settings ▸ Control plane ▸ Providers, a new page (Mac only)

```text
 Control plane:   Overview   Hosts   Providers   Clients

┌─ DigitalOcean ─────────────────────────────── command provider · doctl ─ [ ··· ] ┐
│ ● agents-devbox   Running   linked to devbox                                     │
│ ○ build-box       Stopped   linked to build-box              $0.03/h when running│
│ ○ scratch-1       Stopped   not a host                          [Add as Host…]   │
│   Listed 14:31                                                       [Refresh]   │
└──────────────────────────────────────────────────────────────────────────────────┘
┌─ Docker Containers on this Mac ─────────────── command provider · docker ─ [···] ┐
│ ● agents-devbox   Running   not a host                          [Add as Host…]   │
└──────────────────────────────────────────────────────────────────────────────────┘
┌─ Codespaces ──────────────────────────────────────── stdio · mapped ─── [ ··· ] ┐
│ ⚠ Couldn't list: "gh: not logged in". Showing what it listed at 09:02.           │
└──────────────────────────────────────────────────────────────────────────────────┘
  [Add Provider…]

  A provider starts and stops the machines your hosts run on. It runs here, on the
  control plane, so it can start a host that is down.
```

- The provider's `···` menu holds Edit…, Refresh and Remove….
- **Add as Host…** opens the Add a Server sheet, with the ssh destination and the tunnel
  filled in, and links the host when it joins.

## L4. Add Provider sheet (Mac only)

Chosen: pick a kind first. The fields below are split into one form per kind.

```text
┌ Add a Provider ────────────────────────────────────────────────┐
│ [Docker Containers] [DigitalOcean Droplets] [GitHub Codespaces]│
│ [Coder Workspaces] [Google Cloud Workstations]                 │
│ [Your commands] [MCP server]                                   │
└────────────────────────────────────────────────────────────────┘
→ DigitalOcean Droplets:  Name [DigitalOcean Droplets]  Tag [agents]
                 needs doctl signed in on this Mac
                                     [Back] [Add]
```

The single form, which was not chosen:

```text
┌ Add a Provider ──────────────────────────────────────────────────────────┐
│ Name      [DigitalOcean                         ]                         │
│                                                                           │
│ Kind      (•) Commands   ( ) MCP server (command)   ( ) MCP server (URL)  │
│                                                                           │
│ ── Commands ──                                                            │
│ Preset    [ doctl (DigitalOcean droplets)  ▾ ]   Custom… Docker, Codespaces│
│ Tag       [agents          ]                                              │
│   needs doctl signed in on this Mac                                       │
│                                                                           │
│ ── or, for Custom ──                                                      │
│ Workspace [devstack        ]  ssh [devstack-1.cws        ]                │
│ Start     [cws start devstack-1                         ]                 │
│ Stop      [cws stop devstack-1                          ]                 │
│ Status    [cws status devstack-1                        ]  (optional)     │
│                                                                           │
│ ── MCP server ──                                                          │
│ Command   [npx -y @digitalocean/mcp                     ]  or  URL [    ] │
│ Tool map  [ DigitalOcean (shipped) ▾ ]   Edit…   (none if it follows      │
│                                                   the contract)           │
│ Secrets   DIGITALOCEAN_API_TOKEN  [••••••••••••]   [+ Add secret]          │
│                                                                           │
│ ⚠ It has no workspace_stop tool.                                          │
│                                                     [Cancel]  [Add]       │
└───────────────────────────────────────────────────────────────────────────┘
```

- Only the selected kind's section shows.
- **Add** connects, checks and lists, and the sheet closes once the provider has listed.
- A secret is never shown again once added. Edit offers **Replace…**, not the value.

## L5. Link to Workspace… (Mac only)

```text
┌ Link devbox to a Workspace ───────────────────────────┐
│ DigitalOcean                                          │
│   ( ) scratch-1     Stopped                           │
│   (•) agents-devbox Running                           │
│ Docker Containers on this Mac                         │
│   ( ) agents-devbox Running                           │
│                                                       │
│ [✓] Start when used                                   │
│ Stop when idle  [ 30 minutes ▾ ]                      │
│                                      [Cancel] [Link]  │
└───────────────────────────────────────────────────────┘
```

Only unlinked workspaces are listed. A workspace already linked to another host is shown
greyed as "linked to X".

## L6. Kept prompts (US3, all three clients)

```text
                                   ┌──────────────────────────────┐
                                   │ run the migration again      │
                                   └──────────────────────────────┘
                                     Waiting for devbox to start · ×
```

This is the queued-bubble style of #95, with the line under it saying what it waits for.

- The offline strip (L1) shows as well, so the start's phase and timer are visible.
- × drops the kept prompt on every client. The workspace keeps starting (US3 AS3).
- A failed start turns each kept prompt into a not-sent bubble, with the reason and
  **Try Again**, as a failed send is shown today (US3 AS4).

### L6a. A new agent on a stopped host

New Agent in a project on a stopped host opens the new chat at once: its first prompt is the
kept bubble of L6, under the L1 strip. The agent itself is made when the host connects, and its
transcript follows as usual. × on the bubble drops the request, and the empty chat goes.

## L8. The scheduled-workflows warning (US4, Mac Hosts row)

Shown only when the host has scheduled workflows and **Stop when idle** is on: a third grey
line on its row.

```text
│ ● devbox    Online · Linux · 0.9.2 · Docker: agents-devbox                │
│             Stops after 30 minutes idle                 [Stop] [ ··· ]    │
│             ⚠ 2 scheduled workflows here don't run while it is stopped.   │
```

## L9. New Workspace… and Delete Workspace… (US5, Mac only)

**New Workspace…** is a button beside **Refresh** on a provider card whose provider offers
`workspace_create`. It opens a sheet drawn from `workspace_options`, then a confirmation:

```text
┌ New Workspace on DigitalOcean ─────────────┐
│ Name    [build-2           ]               │
│ Region  [ lon1 ▾ ]                         │
│ Size    [ s-2vcpu-4gb ▾ ]                  │
│ Image   [ ubuntu-24-04 ▾ ]                 │
│                         [Cancel] [Make…]   │
└────────────────────────────────────────────┘
→ Make build-2 on DigitalOcean?
  s-2vcpu-4gb · lon1 · $0.036/h when running
                          [Cancel] [Make]
```

- The cost line shows only when the provider gives one.
- Once made, the workspace shows in the card as **Joining…** until its host joins and is
  linked.
- Cancel at either step makes nothing (US5 AS3).

**Delete Workspace…** is in a linked host's `···` menu on the Hosts row (L2), with a
destructive confirmation:

```text
Delete build-2?
The workspace and everything on its disk are deleted, and host build-2 is
removed with its 3 agents.
                                   [Cancel] [Delete]
```

## L7. Remote and web

There are no Hosts or Providers pages (as today). Their part is L1 (the strip with
**Start**), and later L6. The parity table gains:

| Row | Mac | Remote | Web | Status |
|---|---|---|---|---|
| Start a stopped workspace (#691) | strip + Hosts row | strip | strip | **same** |
| Workspace providers (#691) | Settings ▸ Control plane ▸ Providers | — | — | **by design** (managing hosts is the Mac's) |
