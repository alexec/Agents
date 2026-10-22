# Data model: Enterprise T5, policy

All control-plane keys are under `<prefix>/v1/`, as in `specs/058-control-plane/contracts/store.md`. Every record keeps `rev`, and keeps the fields it does not know. Plain JSON files only.

## OrgPolicy (`policy.json`)

One record per organisation. Absent = no policy (US1).

| Field | Type | Notes |
|---|---|---|
| `version` | integer | +1 on each change. A machine refuses a lower one (FR-008). |
| `issued` | Stamp | when it was saved |
| `changedBy` | Actor | T3's actor: the admin and their client |
| `requires` | `[string]` | capabilities a machine needs to follow it: `host.policy.1`, and one per later rule (FR-014) |
| `modeCeiling` | string? | a mode name of ModeLooseness rank 0–4: `ask` (0), `default` (1), `acceptEdits` (2), `auto` (3), `bypassPermissions` (4). Each runtime's own mode names map by `modeRanks` (`Go/internal/agentsd/helperstart.go`). A mode a machine does not know counts as rank 4. |
| `sandbox` | `"required"`? | Absent = the person's choice. `required` refuses `SandboxChoice.off`, and states `none` and `runtimeControlled`. |
| `runtimes` | `{<runtime id>: RuntimeRule}`? | Absent = every runtime. Present = only those named. |
| `marketplaces` | `{allowed: [string], customServers: "allow"\|"refuse"}`? | marketplace ids as #687 names them |
| `budgets` | Budgets? | |
| `helpers` | `{mostRunning?: int, mostNotArchived?: int}`? | the ceiling over each project's `HelperLimits.running` and `notArchived` (#64, in `.agents/project.json`) |
| `environment` | `{passThrough: [string]}`? | names, `*` at the end allowed. The person's own list (`<settings>/runtime-environment.json`, `RuntimePassThrough`, #727) is cut to these. The built-in allowlist (`allowed` in `runtimes.go`) and each runtime's own `passed` names are not changed. |
| `stopAll` | `{on: bool, by: Actor, at: Stamp, note?: string}`? | the kill switch |
| `requireFollowing` | bool? | the router refuses agent starts on a machine that does not follow this version |
| `groups` | `{}` | empty. Kept for later layers that only tighten. |

**RuntimeRule**: `{models?: [string], reach?: [string]}`. `models` absent = every model. `reach` is T6's (#999): `signIn`, `orgKey`, `gateway`; absent = every way.

**Budgets**: `{daily?: number, dailyTokens?: int, perAgent?: number, perAgentTokens?: int, allowUnmetered: [runtime id], raises: [Raise]}`. Money is US dollars. These are the fields of `CostLimits`, per person.

**Raise**: `{user, day (UTC, YYYY-MM-DD), daily?: number, dailyTokens?: int, by: Actor, request?: id}`. Swept the day after.

**Bounds**: under 64 KiB. Lists up to 200 items. A budget from $0 to $1,000,000 a day, so a slip of the keyboard is refused.

**States**: no policy → policy (version 1) → policy (version n+1) … A policy is never deleted; "no rules" is a policy with no fields set, so a machine never takes the absence of a file as a loosening.

## Signature (`policy.sig`)

`{version, keyID, alg: "ed25519", sig: base64}` over the canonical JSON (sorted keys, no spaces) of the OrgPolicy without `rev`. Written after `policy.json`, in the same change. A copy that reads a `policy.sig` of another `version` waits for the change to finish, and sends nothing.

## SignedPolicy (wire, and `<root>/policy.json` on a machine)

`{policy: OrgPolicy, signature: Signature}`. On a machine it is kept beside its other files, written 0600. The machine checks the signature with the control key it trusts (and the old key during the 30 days after a rotation, T4).

## PolicyRefusal (wire error data)

`{reason: "policy"|"budget"|"stopAll"|"noPolicy"|"mustJoin"|"update", rule?: string, words: string, until?: Stamp}`. `words` is the client line ("Your organisation allows modes up to Accept Edits."). The title is always **Set by your organisation**, except for `mustJoin` and `noPolicy`, which say what to do.

## Choice marks (wire, on existing lists)

The lists a machine sends (runtimes, models, modes, marketplaces, pass-through names, helper limits, cost limits) gain an optional `setBy: {by: "organisation", rule, words}` on each item or value the policy refuses or caps.

## Usage roll-up row (extended)

`UsageRollupRow` gains `limitTokens` (integer): the row's tokens as `limitTokens` counts them, so the control plane adds the same number a machine does. An older machine's rows read as `inputTokens + outputTokens`.

## Person budget state (control plane, memory)

As `botCaps` today: which users are at a budget, until the end of the UTC day. Sent to their machines as `host/user` → `capReachedUntil`, which a person's machine now honours too. Not stored: it is worked out again from the roll-ups at start.

## Request (Console ▸ Requests, extended)

A new kind `budget`: `{user, day, spent, spentTokens, note?}`. Answering it writes a Raise.

## Machine pin (not in the store)

| Source | Keys |
|---|---|
| Mac managed preferences, in the domains `com.alexecollins.agents.host` (Agents Host) and `com.alexecollins.agents.store` (the window); one profile sets both | `ControlPlaneAddress` (string), `ControlPlaneKey` (the key fingerprint a code carries), `MustJoin` (bool) |
| Linux `/etc/agents/policy.json`, owned by root, not writable by others | `{"controlPlane": {"address": "...", "key": "..."}, "mustJoin": true}` |

Any other key is ignored and logged once (FR-029).
