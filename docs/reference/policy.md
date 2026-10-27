---
diataxis: reference
devices: [mac, iphone, ipad]
description: The organisation's policy, its rules, its signature and its methods.
---

# Policy

The organisation's policy (#998): one document on the control plane, signed by its key and
sent to every machine. Each rule is optional. A rule that is not set sets no ceiling. Why
and how it is sent: [Policy](../explanation/control-plane.md#policy).

The types are in `Packages/Wire/daemon.schema.json` (`OrgPolicy`, `SignedPolicy`,
`PolicySignature`, `PolicyRefusal`, `PolicySetBy`), and the methods in
`Packages/Wire/control.openrpc.json`.

## The rules

| Field | Values | What it does |
|---|---|---|
| `modeCeiling` | `ask`, `default`, `acceptEdits`, `auto`, `bypassPermissions` | The loosest mode an agent can have. A mode that a machine does not know counts as the loosest. |
| `sandbox` | `required` | Refuses an agent with no command sandbox, or one that the app cannot vouch for. |
| `runtimes` | `{<runtime id>: {models?: [id], reach?: [way]}}` | Only these runtimes. `models` names the models allowed; `*` at the end matches more than one (`claude-sonnet-*`, which also takes the family `claude-sonnet`). A pattern is matched with the runtime's own value, that value without its context suffix (`opus[1m]` is `opus`) and, for Claude, whose values are aliases, the model the option's name says (`Sonnet 5` is `claude-sonnet-5`) and its family (#2274). Claude's `default` is matched as the model its description names. `reach` (#999) names the ways the runtime may reach the model: `signIn` (the person's own sign-in), `orgKey`, `gateway`. Absent: every way. `[orgKey, gateway]` is the org path only. Console ▸ Policy shows it as **Any way**, **Org key or gateway only** and **Own sign-in only**; to set it with no runtime list, the Console names every runtime. |
| `marketplaces` | `{allowed: [id], customServers: allow \| refuse}` | Only these marketplaces, and whether an MCP server added by hand is allowed. |
| `budgets` | `{daily?, dailyTokens?, perAgent?, perAgentTokens?, allowUnmetered: [runtime id], raises: [...]}` | Each person's budget, in US dollars and tokens, per UTC day and per agent. A ceiling over the person's own cost limits. |
| `helpers` | `{mostRunning?, mostNotArchived?}` | The ceiling over each folder's helper limits. |
| `environment` | `{passThrough: [name]}` | The variable names that a person's own pass-through list can name; `*` at the end allowed. |
| `notices` | `{antigravityTerms?: show \| accepted \| refuse}` | Google's terms notice for Antigravity (#999): `show` (as absent), `accepted` (your organisation reviewed the terms; members see no notice, and the Policy pane says so), `refuse` (Antigravity is refused). Console ▸ Policy names them **Show the notice**, **Reviewed by your organisation** and **Do not allow**. |
| `stopAll` | `{on, by, at, note?}` | The kill switch. Only `policy/stopAll` changes it. |
| `requireFollowing` | `true` | The control plane refuses to start work on a machine that has not kept this version. |
| `groups` | `{}` | Empty. A place for later layers, which can only make a rule tighter. |

The control plane sets these fields itself:

| Field | What it is |
|---|---|
| `version` | One more at each change. A machine refuses a lower version. |
| `issued` | When the change was saved. |
| `changedBy` | The admin and their client, as the audit names them. |
| `requires` | The capabilities a machine needs to follow the policy: `host.policy/1`, and `host.org-routes/1` when `reach` or `notices.antigravityTerms` is set. |

**Bounds.** The document is under 64 KiB. A list has at most 200 items. A budget is from $0 to
$1,000,000 a day. A helper limit is from 0 to 1,000. A value out of bounds is refused, and
nothing is kept.

**Raises.** `policy/raise` gives one person a higher budget for today (UTC). A person has at
most one raise each day; the newest one is kept. Raises of past days are removed at the next
change. A person sees only their own raises.

## The signature

`v1/policy.sig` is `{version, keyID, alg: "es256", sig}`:

- `sig` is ECDSA P-256 with SHA-256 over the canonical JSON of the policy (keys sorted, no
  spaces, numbers as written), as 64 bytes: r, then s.
- `keyID` is the first 8 bytes of the SHA-256 of the control key's public key, base64url.
- A machine checks it with the control key it trusts. `controllink.VerifyPolicy` does this
  for `agentsd`.

## Methods

| Method | Who | What |
|---|---|---|
| `policy/mine` | Any person | The policy in force, with only their own raises. |
| `policy/get` | An admin | The policy, its `rev`, and the version each machine keeps. |
| `policy/set` | An admin | Saves the rules with the `rev` that was read. Fails with `changedElsewhere` when another admin saved first. |
| `policy/stopAll` | An admin | Turns the kill switch on or off. |
| `policy/raise` | An admin | Raises a person's budget for today. |
| `control/policyChanged` | To every client | The policy changed. |
| `control/stopAll` | To every client | The kill switch was turned on or off. |
| `host/policy` | To a machine | The signed policy, or `{none: true}`. |
| `host/policyApplied` | From a machine | The version it keeps. |

## On a machine

A machine says `host.policy/1` when it follows the policy (slice 2a). How it follows it:
[Organisation policy on a machine](../explanation/organisation-policy.md).

| File or method | What it is |
|---|---|
| `<root>/policy.json` | The newest signed policy, as `{policy, signature}`, 0600. |
| `<root>/policy-seen.json` | The highest version applied, and the control key before a rotation, trusted 30 days. |
| `<settings>/runtime-environment.json` | The person's own pass-through names: `{names: [name], runtimes: {<id>: [name]}}`, `*` at the end for a prefix. |
| `daemon/policyState` | The policy as the machine follows it: `version`, the rules with only this person's raises, `stopAll`, `noPolicy`, `update` (the capabilities it lacks) and `refusal`. `daemon/policyStateChanged` says each change. |
| `settings/passThrough` | The person's pass-through names, each marked with `setBy` when the policy refuses it. |

The lists marked with `setBy` (`{by: "organisation", rule, words}`): `runtimes/list` on each
runtime, each mode and model value of an agent's options and of `agents/options`,
`sandbox/state`, `cost/state` (with `organisation`, the budgets in force today), and
`helperLimitsSetBy` on a folder. Each roll-up row of `usage/rollup` has `limitTokens`.

A refusal is the error `policyRefused` (-32076). Its data is a `PolicyRefusal`: the reason
(`policy`, `budget`, `stopAll`, `noPolicy`, `mustJoin` or `update`), the rule, and the
words for the client.
