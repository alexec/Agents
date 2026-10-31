# Data model: Policy layers

All types go in `Packages/Wire/daemon.schema.json` first. `scripts/wire.sh gen` makes the Go and the TypeScript; `WireSchemaTests` says what to write in Swift (#1135). Every field of `PolicyRules` is optional: a field that is absent sets nothing.

## PolicyRules

The same shape in every layer (FR-002). The order of each rule is in research R6 and the spec's FR-004.

| Field | Type | Values, range | Unset means |
|---|---|---|---|
| `permissionMode` | `PermissionLevel` | `plan`, `ask`, `approveForMe`, `bypassPermissions` | a new agent gets Ask; any level may be chosen |
| `permissionRequests` | `ClientPermissionMode` | `default` (Ask me), `alwaysApprove` (Approve for me) | each runtime's default (Agent Runtimes) |
| `sandbox` | `SandboxChoice` | `off` (Off allowed), `runtime` (The runtime's), `on` | each runtime's default |
| `budgets` | `PolicyRuleBudgets` | `perAgent`, `daily`: `Cost`; `perAgentTokens`, `dailyTokens`: integer ≥ 1 | no limit |
| `helpers` | `PolicyHelpers` (existing) | `mostRunning` 1–10, `mostNotArchived` 1–20, in each folder | 3 running, 5 not archived |
| `workflows` | `PolicyWorkflows` | `mostOn` 1–100, in each folder | 20 |
| `noticeLimits` | `PolicyNoticeLimits` | `burst` 1–20, `waitMinutes` 1–1440 | 3, 10 minutes |
| `archiveMyChats` | boolean | `false` is tighter | `true` |
| `runtimes` | map runtime id → `PolicyRuntimeRule` (existing: `models`, `reach`) | a runtime not named is not allowed | every runtime and model |
| `marketplaces` | `PolicyMarketplaces` (existing: `allowed`, `customServers`) | `customServers`: `allow`, `refuse` | every marketplace; connectors by hand allowed |
| `environment` | `PolicyEnvironment` | `passThrough`: names, a trailing `*` a prefix; `runtimes`: runtime id → names | the runtime's own names only |

`noticeLimits` is not `notices`, because `OrgPolicy.notices` already means the Antigravity terms (spec 998).

**Validation** (the same on every machine, in `policylayers.Validate`): each number in its range; each enum value known; lists with no empty name; under 16 KiB. A layer that fails is not used: your layer keeps its last good copy (FR-011), a folder's layer keeps its last approved copy (R10). An unknown field is ignored and logged once, so a newer file works on an older machine.

## The organisation layer: OrgPolicy (changed)

Today's fields keep their meaning (FR-003), with these changes:

- **New** optional fields with the types above: `permissionMode`, `permissionRequests`, `workflows`, `noticeLimits`, `archiveMyChats`.
- `modeCeiling` **goes**. The control plane reads it once into `permissionMode` (research R5) and signs a new version.
- `sandbox` gains the value `runtime`; `required` means `on`.
- `budgets` keeps `allowUnmetered` and `raises`, which only this layer has (FR-003). `stopAll`, `requireFollowing`, `requires`, `groups` and `notices` stay on this layer only.
- `requires` gets `host.policy-layers/1` when any new field is set, so an older machine refuses work rather than ignore a rule (spec 998, `policyRequires`).

## Your layer

### YourPolicy

| Field | Type | Notes |
|---|---|---|
| `rules` | `PolicyRules` | |
| `revision` | integer | one higher at each save. A machine refuses a lower one (FR-011). |
| `changed` | `WireDate` | |
| `changedFrom` | `{client: string, kind: mac | remote | web}` | which client saved it |
| `person` | string | the person's id (the user scope's user, or `local` for a person with no control plane) |
| `keeper` | string | the host id of the keeper (research R4) |

### SignedYourPolicy

| Field | Type | Notes |
|---|---|---|
| `policy` | string | the exact `CanonicalJSON` bytes of `YourPolicy`, base64 |
| `signature` | `PolicySignature` (existing) | `alg: es256`, `keyID`, `sig` |
| `rotation` | `PersonKeyRotation`? | present only on the first copy after a new key |

### PersonKeyRotation

`{newKey: string (X9.63, base64), newKeyID: string, signature: PolicySignature}`: the new public key, signed by the old key. A machine moves its pin only with one that checks.

### PinnedPersonKey (on each machine, `<root>/person-key.pub.json`, 0600)

`{key, keyID, from: joinCode | window | controlPlane, at: WireDate}`. `from: controlPlane` is the trust-on-first-use case of research R3.

### State transitions (a machine that is not the keeper)

```text
no pin ──(join code / window / first control-plane copy)──▶ pinned
pinned ──(copy, signature checks, revision higher)──▶ applies it; keeps it in policy-yours.json
pinned ──(copy, signature fails or revision not higher)──▶ keeps its own; logs once
pinned ──(rotation record checks)──▶ new pin, then as above
```

## A folder's layer

### `.agents/policy.json` (in the folder, committed)

A `PolicyRules` object, and nothing else. The app writes only the rules the folder sets, with sorted keys and two-space indents, and a newline at the end, so a diff shows only the changed rule (FR-014, US3 scenario 3). A folder layer has no signature: the guard protects it (research R10).

### FolderPolicyState (on each machine)

The last approved copy is the existing guarded-file record in `<root>/guarded-files.json` (`approvedDigest`, `approvedContent`, `pending`), keyed by the file's path, so each worktree has its own (Edge Cases).

```text
approved ──(change in the app: policy/setFolder)──▶ approved (new)
approved ──(outside change, Looser = false)──▶ approved (new); notice "tighter"
approved ──(outside change, Looser = true, or invalid)──▶ pending; the old copy applies
pending ──(Allow)──▶ approved (new)
pending ──(Keep <old> / Undo)──▶ approved (old); the file is written back
```

### `.agents/folder.json` (changed)

`helperLimits.running` and `helperLimits.notArchived` are no longer read (FR-015). The other `helperLimits` keys stay.

## The effective policy

### PolicyLayerRef

`{kind: organisation | you | folder, name: string, folder?: string}`. `name` is the organisation's name, "You", or the folder's name.

### EffectiveRule

| Field | Type | Notes |
|---|---|---|
| `rule` | `PolicyRuleName` | `permissionMode`, `permissionRequests`, `sandbox`, `budgets.perAgent`, `budgets.daily`, `budgets.perAgentTokens`, `budgets.dailyTokens`, `helpers.mostRunning`, `helpers.mostNotArchived`, `workflows.mostOn`, `noticeLimits.burst`, `noticeLimits.waitMinutes`, `archiveMyChats`, `runtimes`, `marketplaces.allowed`, `marketplaces.customServers`, `environment` |
| `value` | JSON value | the effective value |
| `words` | string | the value in the clients' words, for example "Approve for me", "$40.00 a day" |
| `decides` | `PolicyLayerRef`? | absent when no layer sets it (today's default applies) |
| `layers` | `[EffectiveLayerValue]` | every layer from the top down |
| `cap` | JSON value? | the tightest value of the layers **above** the one being edited; a menu dims what is looser |
| `capLine` | string? | for example "Acme: at most Approve for me" |

### EffectiveLayerValue

`{layer: PolicyLayerRef, value?: JSON, words: string ("Not set" when absent), kept: bool}`. `kept` is "Kept, not used": the layer sets a value and a layer above caps it (FR-006).

### EffectivePolicy

`{folder?: string, rules: [EffectiveRule], organisation?: string, foldersWithRules: [{folder, name, count}], behind: [{host, name}]}`. `behind` is the person's machines that do not say `host.policy-layers/1` (Edge Cases). Made by `policylayers.Resolve`; never stored.

**Resolve**: for each rule, take the layers that set it, from the top down (organisation, then the empty `groups` slot, then you, then the folder); the effective value is the tightest by the rule's order; `decides` is the highest layer that has the effective value; every other layer whose value is looser is `kept`. A list rule is the intersection, and `decides` is the highest layer whose list removes a name that a lower layer allows.

## Refusals and marks (changed)

- `PolicyRefusal`: gains `layer: PolicyLayerRef` and `value: string`. `rule` takes a `PolicyRuleName`. `reason` keeps its values (`policy`, `budget`, `stopAll`, `noPolicy`, `mustJoin`, `update`).
- `PolicySetBy`: `by` becomes `organisation | you | folder`, and gains `layer: PolicyLayerRef`.
- Events: `policy.refused` (rule, layer, agent) for the report "What the limits have stopped"; `policy.folderTightened`; `policy.yoursApplied` (revision).

## Sizes

A layer under 16 KiB (validated). Under 10 machines and 200 folder layers per person. One `EffectivePolicy` in memory per folder with a layer, under 4 KiB each.
