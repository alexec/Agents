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
| `defaults` | `[RuntimeID: SandboxChoice]` | A missing key means `runtime` (FR-003c, SC-006). A choice the catalog does not offer for that runtime is dropped on save |

A missing file is empty; an unreadable one is set aside, as `ClientPermissionStore` does. The Mac pushes it to connected servers. There is no probe result: routes are the catalog's (research R9, Alex 2026-09-29).

## SandboxCatalog.Entry (code, not stored)

| Field | Notes |
|---|---|
| `route` | `.arguments(on:off:)` (Grok), `.environment(on:off:)` (Gemini, On nil), `.claudeMeta`, `.codexMode`, `.fixed(SandboxState)` |
| `measuredOn` | The version the route was measured on |
| `why` | The sentence for a runtime with no choice, or a choice it lacks |
| `failurePatterns` | Setup-failure text from the fixtures, never a bare "Operation not permitted" |
| `readsReply` | Codex: a failed sandbox shows only in the reply |
| `hangsWhenOn` | Gemini: a sandbox that is on never answers `initialize` |

## Agent (new fields)

| Field | Type | Notes |
|---|---|---|
| `sandboxOverride` | `SandboxChoice?` | nil means use the runtime default (FR-003b) |
| `effectiveSandbox` | `EffectiveSandbox?` | Written at each spawn, after the handshake |

Both are added to `CodingKeys`, `init(from:)` and `encode`. Older records decode with nil.

## EffectiveSandbox

| Field | Type | Notes |
|---|---|---|
| `state` | `on` / `off` / `runtimeControlled` / `none` | What the capsule shows (`none`: No sandbox) |
| `requested` | `SandboxChoice` | After resolution |
| `reason` | String? | For example "Limited by the agent that started it" |

For Codex under `runtime`, `state` is read from the mode: `agent-full-access` means `off`; otherwise `on`.

## SandboxFailureRecord (`TranscriptEntry.Kind.sandboxFailure`)

| Field | Type | Notes |
|---|---|---|
| `runtimeID` | RuntimeID | |
| `detail` | String | The matched text, trimmed. Shown under "Show error details" |
| `recoveryOffered` | Bool | Off is actionable for this runtime and host |
| `hang` | Bool | Gemini never answered; the card's words are the app's |
| `completedToolCalls` | Int | Nonzero means recovery sends a continuation instead of the prompt |
| `resolution` | `pending` / `keptStopped` / `continued` | The card turns into a plain note once resolved |

## EndedReason

A new `sandboxFailed` value. It ends the turn, leaves the agent stopped and waiting for the person, and never retries automatically.

## Rules

- A resolved choice must be in `SandboxCatalog.choices` for the runtime; otherwise it becomes `runtime` (FR-002, FR-008).
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
