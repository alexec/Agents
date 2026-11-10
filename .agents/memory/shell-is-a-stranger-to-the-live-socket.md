---
name: shell-is-a-stranger-to-the-live-socket
description: "A script on the live host's daemon.sock gets the stranger role (roles by code signature), so connections/*, mcp/approve and workflows/enable are refused; pair_web_page is not on the 2026-11-10 build; set up a connector by a PR to .agents/mcp.json and let Alex Approve it"
metadata:
  type: project
  modified: 2026-11-10T19:30:00Z
---

On the live root (`~/Library/Application Support/Agents`) the socket gives roles by code
signature (`roles_darwin.go`): a Python or shell caller is a **stranger** and may call only
`daemon/ping`, `daemon/status`, `git/credential`, `daemon/lockReset` and `secrets/terminalValue`.
`connections/sign-in/email`, `mcp/approve`, `workflows/enable` and the other control-role
methods answer `-32045 not open to this connection (stranger)`. `agentsctl` needs a pairing
code from the window, and `pair_web_page` answered "Method not found" on the build of
2026-11-10 (#1780 set-up). Reading or writing the host's Keychain connection store from a
shell is also refused by the runtime's own guard.

**How to apply:** set a connector up in the folder by a PR to `.agents/mcp.json` with
`${SECRET}` for the sealed secret and the Mail or other page in `.agents/pins.json`; the
entry then waits for Alex's **Approve** in Project Settings ▸ Connectors, by design. A
ready-made workflow is turned on per folder in the root's `workflows.json` (`userEnabled`),
so that too is Alex's switch in the app. On a scratch root the socket is open unless
`AGENTS_ENFORCE_ROLES` is set ([[driving-agentsd-by-hand]]).
