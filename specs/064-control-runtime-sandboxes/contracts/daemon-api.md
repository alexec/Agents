# Contract: daemon API for runtime sandboxes

JSON-RPC over `daemon.sock` and the phone bridge, in the style of `clientPermissions/*`. Types are in [../data-model.md](../data-model.md).

## Methods

| Method | Params | Result | Roles |
|---|---|---|---|
| `sandbox/state` | `{}` | `SandboxSettings` | control, device |
| `sandbox/set` | `SandboxSettings` | `SandboxSettings` | control only |
| `agents/setSandbox` | `{agentID, choice: SandboxChoice?}` | `Agent` | control, device |
| `agents/answerSandbox` | `{agentID, carryOn: Bool}` | `Agent` | control, device |

**`sandbox/set`**: a default the catalog does not offer for that runtime is dropped. Changing a default changes no override.

**`agents/setSandbox`**: `choice: null` clears the override (FR-003b). A choice the catalog does not offer is refused with `invalidParams` and the runtime's `why`. For Codex, `off` also sets mode `agent-full-access`, and `on` from Full access sets `read-only`. It applies from the agent's next turn.

**`agents/answerSandbox`**: refused unless the agent's latest `.sandboxFailure` entry is `pending`. `carryOn: false` marks it `keptStopped`. `carryOn: true` needs `recoveryOffered`; it sets the override to Off, marks the card `continued`, and re-sends the task (plan, Recovery).

## Changed requests

- `StartRequest.sandbox: SandboxChoice?`: the new agent's override. Nil follows the default.
- A draft is made with its runtime default's choice and is reused only by a start that resolves to the same one.
- `agents/setOption` of Codex's `mode` also writes that agent's override (FR-005c).

## New error

`sandboxWillNotStart`, returned by a start whose runtime would not start because of its sandbox. Its data is `{runtimeID, detail, offOffered}`. The form keeps the prompt and, when `offOffered`, offers **Start without sandbox**, which resubmits with `sandbox: "off"`.

## Notifications

`sandbox/changed` carries `SandboxSettings`, after `sandbox/set`. Changes to `sandboxOverride` and `effectiveSandbox` travel in the existing agent notifications.

## Transcript

`TranscriptEntry.Kind.sandboxFailure(SandboxFailureRecord)`, drawn as a block, so a concise turn shows it. An older client that does not know the kind keeps it as unrecognised.

## Servers

The Mac sends `sandbox/set` to each connected server when a default changes and when it connects, as for `clientPermissions`. Each server resolves with its own catalog and recognises its own failures.
