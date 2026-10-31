# Contract: policy layers on the wire

Types are in [data-model.md](../data-model.md). Methods go in `Packages/Wire/daemon.openrpc.json` (machine) and `Packages/Wire/control.openrpc.json` (control plane). Every new daemon method has `x-capability: host.policy-layers/1`.

## Client → machine (daemon API)

| Method | Who may call | Params | Result | Notes |
|---|---|---|---|---|
| `policy/effective` | any client | `{folder?}` | `EffectivePolicy` | no folder: the rules for an agent outside a folder layer, and the list of folders with their own rules |
| `policy/yours` | any client | – | `{policy: YourPolicy, keeper: {host, name}, pinnedKeyID}` | |
| `policy/setYours` | the person's own clients, **on the keeper only** | `{rules: PolicyRules, revision}` | `YourPolicy` | refused `conflict` when `revision` is not the current one (Edge Cases, two clients at once); refused `notKeeper` with the keeper's name on another machine; refused `forbidden` from the agent socket role, an MCP tool and a workflow (FR-010); refused `invalid` when `policylayers.Validate` fails |
| `policy/folder` | any client | `{folder}` | `{rules: PolicyRules, pending?: GuardedChange, invalid?: string}` | the approved copy, and a waiting change |
| `policy/setFolder` | the person's own clients | `{folder, rules: PolicyRules}` | `{rules}` | writes `.agents/policy.json` in a stable order and approves it. A value looser than yours is kept and shows "Capped by yours" (US3 scenario 6) |
| `policy/applyYours` | the Mac window's direct link to a server | `SignedYourPolicy` | `{revision}` | pins the key if none (research R3, path 2); refused `signature` or `older` |

**Notifications**: `policy/effectiveChanged` `{folder?}` when any layer changes; clients call `policy/effective` again.

**A waiting folder change** uses the existing methods `folders/readGuardedChange` (Show Change), `folders/keepGuardedChange` (Allow) and `folders/undoGuardedChange` (Keep `<old>`), and `approvals/*` kind `file`. `GuardedChange` gains `policy: {looser: [PolicyRuleName], words}` so a client draws the frame D words.

**Methods that go** (their rules now come from your layer): `cost/setLimits`, `workflows/setLimit`, `user/setNoticeLimits` (host → control plane), and the keys `noticeBurst`, `noticeCooldownMinutes` and `agentsMayArchiveMyChats` of `preferences/set`. `folders/setHelperLimits` loses `running` and `notArchived`. `cost/state` and `workflows/limit` stay and read the effective values, with `setBy`.

**Errors**: `policyRefused` (-32076) with `PolicyRefusal` as `data`, from every method that a rule can refuse (FR-026). Choice lists (`runtimes/list`, the model and mode lists, `marketplaces/list`, `settings/passThrough`, `cost/state`, `workflows/limit`, `FolderSummary.helperLimits`) mark capped items with `PolicySetBy`, now with the layer.

## Keeper → control plane

| Method | Params | Notes |
|---|---|---|
| `user/setPolicy` | `SignedYourPolicy` | host only, and only from the keeper; the control plane checks the revision goes up, stores it as the user-scope part `policy`, and pushes it. It does not sign or change it. |

## Control plane → machine (channel 0)

| Message | When | Body |
|---|---|---|
| `host/userSettings` (extended) | on connect, and within 5 s of a change, to machines that say `host.policy-layers/1` | the part `policy`: `SignedYourPolicy`. The parts `costLimits` and `notifications` are no longer sent. |
| `host/policy` (unchanged) | as today | the `OrgPolicy` with its new fields |

## Control plane → clients

- `user/settings` returns the part `policy` read only. `user/setSettings` refuses the part `policy` (only the keeper sets it) and the removed parts.
- `control/userSettingsChanged` as today.
- `policy/get`, `policy/set`, `policy/mine`: `OrgPolicy` with the new fields; `modeCeiling` is gone (research R5).

## Join codes

A join code made by the person's Mac window carries `personKey` (X9.63, base64) beside the control key. A machine that joins with it pins the key (research R3, path 1).

## Client words (all three clients, from the machine)

| Where | Words |
|---|---|
| Capped row | `<layer>: at most <value>`, for example "Acme: at most Approve for me" |
| Dimmed menu item | "`<layer>` allows at most `<value>`" |
| Your value under a cap | "Kept, not used" |
| Folder row, nothing set | "Same as yours" |
| Folder value above yours | "Capped by yours" |
| Banner, organisation | "`<organisation>` sets limits above yours" + **Organisation Policy** |
| Banner, alone | "You set every limit" + "`<n>` folders have their own rules" |
| Stop card title | "Stopped by a policy" |
| Stop card actions | **Change in `<pane>`** (you, folder); **Ask for More** (organisation budget); **See Organisation Policy** (other organisation rules) |
| Policy card (frame D) | **Allow**, **Keep `<old value>`**, **Show Change** |
