# US5 walk — Settings ▸ Control plane (2026-09-26)

Build `5ba46b2c`, plus the fixes in the commit that adds this file.

**Set-up**
- A fresh scratch root `/tmp/run-cs` set up with Run One Here.
- A second host posing as another machine: `agentsd --control …/hosts.sock --host-id devbox --host-name devbox` with `AGENTS_MACHINE_ID=devbox-machine`, on its own root.
- A stand-in "Alex's iPhone" written into `clients.json` while the control plane's job was stopped.

**How it was driven**
- By exact-title AX presses on the scratch window's pid.
- Grant changes went over `control.sock`, because the segmented pickers have two "Device" segments each.

## What was seen

- **D · Overview** ([us5-d-overview.png](us5-d-overview.png))
  - The rail's Control plane group replaces Devices and Servers.
  - This Mac is marked "you are here", with `agents-control`, its start time and port 8799.
  - Away from home shows Off (the scratch job has no mailbox).
  - Hosts shows "2 hosts · 2 online"; Clients shows "1 client · 1 operator".
- **Restart** restarted the control plane under launchd, with a new pid. Both hosts rejoined within a second, and the page came back by itself.
- **F · Clients** ([us5-f-clients.png](us5-f-clients.png))
  - "This window" is first, marked "you", as Operator.
  - The iPhone shows its Operator/Device picker and Forget….
  - Demoting or forgetting the only operator was refused with `lastOperator` (-32072), "That would leave no client that can change grants…".
  - Promoting the iPhone showed on the page at once, from `control/clientChanged`.
  - Forget… asked first ([us5-f-forget.png](us5-f-forget.png)), then took the iPhone off `clients.json` and the page. The rail count went from 2 to 1.
- **E · Hosts** ([us5-e-hosts.png](us5-e-hosts.png))
  - This Mac is first and has no buttons.
  - devbox shows "connects out", with Check again and Remove….
  - With devbox's host stopped, its row turned grey and said "Offline" ([us5-e-offline.png](us5-e-offline.png)).
  - Remove… asked first, then took devbox off `hosts.json` and the page ([us5-e-after-remove.png](us5-e-after-remove.png)).
- **G · Pair a Mac** ([us5-g-pair-mac.png](us5-g-pair-mac.png)): the grant is chosen first, with Operator as the default. The code itself waits for network pairing, and the sheet says so.

## Found and fixed on the way

- The first wording on Pair a Mac ("a Mac joins by running its own control plane") was wrong; it now says only this Mac's window can use it for now.
- `PaperButtonStyle` never dimmed when disabled, unlike `PaperProminentButtonStyle`. It now does, everywhere. That is why Add a Server… and Add by Code… showed as live buttons.
- The walk's own mistakes, not the app's:
  - `ui.swift press` matches substrings and presses the last hit. "Settings…" hit "Services Settings…", which opened System Settings, quit at once. "Restart" hit a menu item of the app's own; the Mac did not restart (uptime 11 days, no dialog).
  - The rest of the walk used `/tmp/press-exact.swift`, which presses only a single exact title.

## Not walked

- Pair a Device… opens today's pairing sheet, which pairs with this Mac's host as before; it is the same sheet as 046.
- Phones paired to the host are listed under Clients with a fixed Device grant and Forget…. None were paired on the scratch root.
- Add a Server… and Add by Code… are disabled until servers and Macs can join through the control plane (US3, pairing).
