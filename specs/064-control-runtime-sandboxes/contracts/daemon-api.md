# Contract: daemon API for runtime sandboxes

JSON-RPC over `daemon.sock` and the phone bridge, in the same style as `clientPermissions/*`. Types are in [../data-model.md](../data-model.md).

## Methods

| Method | Params | Result | Roles |
|---|---|---|---|
| `sandbox/state` | `{}` | `{settings: SandboxSettings, capabilities: [RuntimeID: SandboxCapability]}` | control, device |
| `sandbox/set` | `{runtimeID, choice: SandboxChoice}` | `SandboxSettings` | control only |
| `sandbox/probe` | `{runtimeID}` | `SandboxProbe` | control only |
| `agents/setSandbox` | `{agentID, choice: SandboxChoice?}` | `Agent` | control, device |
| `agents/continueWithoutSandbox` | `{agentID}` | `Agent` | control, device |

**`sandbox/set`**
- A choice that is not in the capability for this host is refused with `notSupported` and a reason.
- Changing a runtime default does not change any agent's override.

**`agents/setSandbox`**
- `choice: null` clears the override (FR-003b).
- For Codex, `off` also sets mode `agent-full-access`, and `on` from Full access sets `read-only`. The returned agent shows both.
- If the agent's turn is running, the result carries `appliesFrom: "nextTurn"`.

**`agents/continueWithoutSandbox`**
- Refused with `notAllowed` unless the agent's latest `.sandboxFailure` entry is `pending` and `recoveryOffered` is true.
- On success it sets the override to Off, marks the card `continued`, and re-sends the task (see the plan's Recovery section).

## Changed requests

- `StartRequest.sandbox: SandboxChoice?`: the agent's override at creation. nil means inherit.
- `OptionsRequest.sandbox: SandboxChoice?`: lets the draft process launch with the same choice. A draft is reused only when the choice matches.

## New error

`sandboxWillNotStart`, a new code in the `DaemonAPI` error-code list. Its data is `{runtimeID, detail, offOffered: Bool}`. It is returned by a start whose `session/new` failed because the sandbox could not start. The client keeps the form and, when `offOffered` is true, offers **Start without sandbox**, which resubmits with `sandbox: "off"`.

## Notifications

`sandbox/changed` carries `{settings, capabilities}`. It is sent after `sandbox/set`, after a probe, and after an installed runtime version changes.

Agent changes to `sandboxOverride` and `effectiveSandbox` travel in the existing agent update notifications.

## Transcript

`TranscriptEntry.Kind.sandboxFailure(SandboxFailureRecord)`. Clients that do not know the kind show it as a runtime note: "Sandbox could not start".

## Servers

The Mac calls `sandbox/set` on each connected server for every non-`runtime` default when a setting changes and on reconnect, like `pushClientPermissionsToServers`. Servers never receive `probes`.
