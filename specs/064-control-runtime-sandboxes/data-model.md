# Data model: Control runtime sandboxes

## SandboxChoice

The person's choice, used both as a runtime default and as an agent override.

| Value | Meaning |
|---|---|
| `runtime` | As configured by runtime: Agents adds no flag, env or mode change |
| `on` | Ask the runtime to sandbox commands |
| `off` | Ask the runtime not to sandbox commands |

Stored as a string. An unknown value decodes as `runtime`, so it never widens access.

## SandboxSettings (`<root>/sandbox-settings.json`)

| Field | Type | Notes |
|---|---|---|
| `defaults` | `[RuntimeID: SandboxChoice]` | A missing key means `runtime` (FR-003c, SC-006) |
| `probes` | `[RuntimeID: SandboxProbe]` | Results for this host only; never pushed to servers |

A missing or corrupt file is treated as empty. A corrupt file is set aside, as `ClientPermissionStore` does. The Mac pushes `defaults` to connected servers; each server keeps its own `probes`.

## SandboxProbe

| Field | Type | Notes |
|---|---|---|
| `version` | String | Runtime or toolset version probed |
| `host` | `mac` / `linux` | |
| `off`, `on` | `confirmed` / `rejected` / `noDifference` | |
| `policyForced` | Bool | A vendor policy requires sandboxing |
| `probedAt` | Date | |

When `version` differs from the installed version, the probe is stale and counts as unconfirmed.

## SandboxCapability (derived, not stored)

| Field | Notes |
|---|---|
| `choices` | The actionable subset of `runtime`, `on`, `off`. `runtime` is always present except for Antigravity |
| `unavailableReason` | Unverified integration, policy, stale probe or unsupported host |
| `route` | `.arguments`, `.environment`, `.mode`, `.meta` or `.none`, from `SandboxCatalog` |
| `couplesApprovals` | True for Codex only |
| `explanation` | Wording for Settings and menus (FR-014) |

## Agent (new fields)

| Field | Type | Notes |
|---|---|---|
| `sandboxOverride` | `SandboxChoice?` | nil means use the runtime default (FR-003b) |
| `effectiveSandbox` | `EffectiveSandbox?` | Written at each spawn, after the handshake |

Both are added to `CodingKeys`, `init(from:)` and `encode`. Older records decode with nil.

## EffectiveSandbox

| Field | Type | Notes |
|---|---|---|
| `state` | `on` / `off` / `runtimeControlled` / `unavailable` | What the header capsule shows |
| `requested` | `SandboxChoice` | After resolution |
| `reason` | String? | For example "limited by the agent that started it", "blocked by policy", "unverified for agy_acp_server 1.2.1" |
| `appliedAt` | Date | The spawn it came from |

For Codex under `runtime`, `state` is read from the mode: `agent-full-access` means `off`; otherwise `on`.

## SandboxFailureRecord (`TranscriptEntry.Kind.sandboxFailure`)

| Field | Type | Notes |
|---|---|---|
| `runtimeID` | RuntimeID | |
| `detail` | String | The matched text, trimmed. Shown under "Show error details" |
| `recoveryOffered` | Bool | Off is actionable for this runtime and host |
| `unavailableReason` | String? | Why recovery is not offered |
| `completedToolCalls` | Int | Nonzero means recovery sends a continuation instead of the prompt |
| `resolution` | `pending` / `keptStopped` / `continued` | The card turns into a plain note once resolved |

## EndedReason

A new `sandboxFailed` value. It ends the turn, leaves the agent stopped and waiting for the person, and never retries automatically.

## Rules

- A resolved `off` needs `off` in `capability.choices`. Otherwise the choice becomes `runtime` and the state is `unavailable` with a reason (FR-008).
- Codex: `sandboxOverride == .off` ⇔ the mode is `agent-full-access`. Setting either updates the other (FR-005a–c).
- Helper: if the caller's `effectiveSandbox.state == .on`, the helper's resolved choice cannot be `off` (R10).
- A change to a default or override never touches a live process. It applies at the next spawn (FR-012).

## State transitions

```text
running ──sandbox startup failure──▶ stopped (sandboxFailed, card pending)
stopped ──Keep stopped──▶ stopped (card keptStopped)
stopped ──Continue without sandbox──▶ override = off ──▶ running (next spawn, re-send)
stopped ──person sends a new prompt──▶ running under the current resolution (it may fail again)
```
