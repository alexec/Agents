# Contract: desktop control on the wire

Types are in [data-model.md](../data-model.md). Methods go in
`Packages/Wire/daemon.openrpc.json`. Every new method has `x-capability:
host.desktop-control/1` (research R8).

## The agent tool (`Go/wire/app-tools.json`, `Packages/Wire/app-tools.json`)

| Tool | Params | What it does | Asks the person first? |
|---|---|---|---|
| `drive_screen` | `DriveScreenCall` (data-model.md) | Takes the `screen` lease if not already held by this agent (queues otherwise, exactly as `lease_resource` would); acts on the named app through the Accessibility API or a synthetic mouse/keyboard event; replies with the result, or, for `action: "screenshot"`, a short-lived reference the client-facing `desktopControl/liveFrame` push also carries. Refused with `DesktopControlRefusal` while the switch is Off or Accessibility is not granted (FR-004, FR-005). | The app answers (Off/not granted), or the runtime decides (an ordinary tool-call permission, same as any other tool) — no extra prompt beyond what the runtime already asks for its own tools. |

Added to `appToolCalls()` (`Go/internal/agentsd/leasewaits.go`), listed in
`docs/reference/agent-tools.md` in the same table as `lease_resource` and `show_file`.

## Daemon methods (client → machine)

| Method | Who may call | Params | Result | Notes |
|---|---|---|---|---|
| `desktopControl/state` | any client | `{}` | `DesktopControlSettings` and, if held, `DesktopControlState` | |
| `desktopControl/set` | the person's own clients only | `{enabled: bool}` | `DesktopControlSettings` | refused `forbidden` from the agent socket role, an MCP tool, or a workflow (research R5, FR-004's own intent) |
| `desktopControl/resume` | the person's own clients | `{agentID}` | `{}` | refused `notPaused` when the state is not paused |
| `desktopControl/takeOver` | the person's own clients | `{agentID}` | `{}` | releases the `screen` lease at once (FR-008); refused `notHeld` when the agent does not hold it |

Stop uses the existing stop-turn method; no new method (research R9).

## Notifications (machine → client)

| Notification | When | Body |
|---|---|---|
| `desktopControl/stateChanged` | the state changes (held, paused, resumed, released) | `DesktopControlState` or `{agentID, released: true}` |
| `desktopControl/liveFrame` | FR-011's refresh, while the `screen` lease is held | `LiveFrame` (data-model.md); never recorded, never replayed to a client that opens the session later than the frame's `capturedAt` |

The narration itself needs no new notification: it is `drive_screen`'s own ACP tool-call
title, already carried by the existing live-step pipeline (`NotifyAgentEntry`, research
R7).

## Events

`desktopControl.paused`, `desktopControl.resumed`, `desktopControl.takenOver`
(data-model.md). `lease.granted` for `"screen"` is unchanged.

## Capability

`host.desktop-control/1`, declared by `agentsd` in `host/hello` once this feature ships
(`Go/internal/agentsd/capabilities.go`), and required by every method and notification
above, and by `offeredTools()` before `drive_screen` is offered to an agent at all
(research R8). A machine that does not say it: the tool is not offered, and a client of
that machine shows a session the ordinary way (Edge Cases, "An older client").

## Errors

`DesktopControlRefusal` (data-model.md) is the `data` of a new error code (name chosen at
implementation, following the pattern of `policyRefused`, -32076). `forbidden`, `notPaused`
and `notHeld` above are existing-style string reasons, not new error codes, matching how
other daemon methods already refuse in words.

## The runtime's own `computer_use`

No wire change: `Go/internal/agentsd/runtimes.go`'s `toolPolicyEnv` map for Codex gains
`"computer_use": false` (research R10); this never reaches the wire, only the runtime's own
launch configuration.
