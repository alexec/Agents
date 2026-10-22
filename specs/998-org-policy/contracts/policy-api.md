# Contract: policy on the wire

The types go in `Packages/Wire/daemon.schema.json`, and the methods in `Packages/Wire/control.openrpc.json` (and `daemon.openrpc.json` for the machine's own errors). `scripts/wire.sh gen` makes the Go and TypeScript, and `WireSchemaTests` says what to write in Swift (#1135).

## Client → control plane

| Method | Who | Params | Result | Notes |
|---|---|---|---|---|
| `policy/mine` | any person | – | `PolicyView` | the rules in force, in words, with `version`, `issued`, `changedBy`. A bot's machine gets the same through `host/policy`. |
| `policy/get` | admin | – | `OrgPolicy` with `rev` | |
| `policy/set` | admin | `{policy: OrgPolicy, rev}` | `OrgPolicy` | conditional on `rev`; refused `conflict` when another admin saved first. Checks the bounds. Raises `version`, signs, audits, pushes. |
| `policy/preview` | admin | `{policy: OrgPolicy}` | `PolicyPreview` | who and what each change would refuse, from what the control plane knows (machines' runtimes, people's spend today). No machine is asked. |
| `policy/stopAll` | admin | `{on: bool, note?: string}` | `OrgPolicy` | the kill switch alone, so the Mac and the Remote need not send the whole document |
| `policy/raise` | admin | `Raise` | `OrgPolicy` | answers a budget request |
| `policy/askForMore` | person | `{note?}` | – | a `budget` request in Console ▸ Requests |

**Notifications to clients:** `control/policyChanged` (`PolicyView`) to every person's clients; `control/stopAll` is the same with `stopAll` set, so a client draws the strip at once.

## Control plane → machine (channel 0)

| Message | When | Body |
|---|---|---|
| `host/policy` | on each connect, and within 5 s of each change, to machines that say `host.policy.1` | `SignedPolicy`, or `{none: true}` when no policy was ever set |
| `host/user` (extended) | as today | `capReachedUntil` now also for a person at a budget |

The `host/hello` reply says nothing new: the policy is its own message, so an older machine is not sent it.

## Machine → control plane

| Message | Body | Notes |
|---|---|---|
| capability `host.policy.1` | in `host/hello` | the machine follows the policy |
| `host/policyApplied` | `{version}` | after it keeps a policy; the Console's Machines page shows it |
| `usage/rollup` (extended) | rows with `limitTokens` | |

## Machine → clients (daemon API)

- Every method that a policy can refuse returns the error `policyRefused` (a new code in the daemon's error list) with `PolicyRefusal` as `data`.
- `runtimes/list`, `models/list` (the model menu), the mode list, `marketplaces/list`, `settings/passThrough`, `settings/helperLimits` and `cost/state` mark items and values with `setBy`.
- `daemon/policyState`: `{version?, stopAll, noPolicy, mustJoin?: {address}, update?: true}`, and a notification when it changes, so a client draws the strip and the Policy pane on the direct path (#1118) too.

## Errors

| Code | When | Client words |
|---|---|---|
| `policyRefused` (`reason: policy`) | a choice above a ceiling | **Set by your organisation.** + the rule's words |
| `policyRefused` (`reason: budget`) | at a budget | "You have used today's budget, set by your organisation. It starts again at 00:00 UTC." + **Ask for More** |
| `policyRefused` (`reason: stopAll`) | the kill switch is on | "Your organisation has stopped all agent work." |
| `policyRefused` (`reason: noPolicy`) | joined, no trusted policy | "Agents Host has no policy from your organisation. Connect to the network." |
| `policyRefused` (`reason: update`) | a capability in `requires` is missing | "Update Agents Host to follow your organisation's policy." |
| `policyRefused` (`reason: mustJoin`) | must join, not joined, or another control plane | "Your organisation requires this machine to join <address>." |
