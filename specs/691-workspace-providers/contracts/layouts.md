# Layouts: what each screen shows

These are drawn in text, in the app's existing style. **They go to Alex for a decision before
any client code is written.** The rest of each screen is as it is today.

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
┌─ Docker on this Mac ────────────────────────── command provider · docker ─ [···] ┐
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
│ Docker on this Mac                                    │
│   ( ) agents-devbox Running                           │
│                                                       │
│ [✓] Start when used                                   │
│ Stop when idle  [ 30 minutes ▾ ]                      │
│                                      [Cancel] [Link]  │
└───────────────────────────────────────────────────────┘
```

Only unlinked workspaces are listed. A workspace already linked to another host is shown
greyed as "linked to X".

## L6. Kept prompts (US3, all three clients; for later, shown now for context)

```text
                                   ┌──────────────────────────────┐
                                   │ run the migration again      │
                                   └──────────────────────────────┘
                                     Waiting for devbox to start · ×
```

This is the queued-bubble style of #95, with the line under it saying what it waits for.

## L7. Remote and web

There are no Hosts or Providers pages (as today). Their part is L1 (the strip with
**Start**), and later L6. The parity table gains:

| Row | Mac | Remote | Web | Status |
|---|---|---|---|---|
| Start a stopped workspace (#691) | strip + Hosts row | strip | strip | **same** |
| Workspace providers (#691) | Settings ▸ Control plane ▸ Providers | — | — | **by design** (managing hosts is the Mac's) |
