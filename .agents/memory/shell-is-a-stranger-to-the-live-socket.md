---
name: shell-is-a-stranger-to-the-live-socket
description: "A script on the live host's daemon.sock gets the stranger role, so control-role methods are refused; ask the person with manage_connectors approve / manage_workflows enable (a Needs you card, #4538); pair_web_page is served since 2026-11-12 but needs Serve Agent Loops to browsers"
metadata:
  type: project
  modified: 2026-11-12T23:30:00Z
---

On the live root (`~/Library/Application Support/Agents`) the socket gives roles by code
signature (`roles_darwin.go`): a Python or shell caller is a **stranger** and may call only
`daemon/ping`, `daemon/status`, `git/credential`, `daemon/lockReset` and `secrets/terminalValue`.
`connections/sign-in/email`, `mcp/approve`, `workflows/enable` and the other control-role
methods answer `-32045 not open to this connection (stranger)`. Never widen a role to get past it.

**How to apply:** for a server waiting in the folder's `.agents/mcp.json`, call the app tool
`manage_connectors approve`; for a workflow that is the person's to turn on (its file says
`enabled: false`, such as a ready-made one), `manage_workflows enable`. Each opens a Needs you
card (Approve / Deny) and agentsd makes the change only on Approve (#4538, `personchanges.go`).
`pair_web_page` answered "Method not found" on 2026-11-10; on 2026-11-12 it is served, but it
refuses while Settings ▸ Control plane ▸ Serve Agent Loops to browsers is off. Do not use it to click
Approve for the person. On a scratch root the socket is open unless `AGENTS_ENFORCE_ROLES` is
set ([[driving-agentsd-by-hand]]).
