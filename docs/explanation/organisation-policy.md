---
diataxis: explanation
description: How each machine follows the organisation's policy as a ceiling, what it does offline, the kill switch, and what the policy does not protect against.
---

# Organisation policy on a machine

An organisation writes one policy on its control plane (#998). The control plane signs it
and sends it to each machine. This page tells how a machine follows it. The fields are in
[Policy](../reference/policy.md). How the control plane keeps and sends it is in
[The control plane](control-plane.md#policy).

## A ceiling, not a setting

The policy is a ceiling above the settings of the person and of the folder. An agent gets
the tightest of the three:

- The mode is the loosest mode that the policy allows, or the mode that the person chose
  when it is tighter.
- With `sandbox: required`, the command sandbox is on. A person's default of off stays in
  `sandbox.json`, but it has no effect while the policy requires the sandbox.
- A folder's helper limits above the policy's are capped to the policy's numbers.
- The person's own pass-through names (`runtime-environment.json`) are cut to the names that
  the policy allows.
- The daily budget and the budget for each agent are the lower of the policy's and the
  person's own cost limits.

The machine never changes or deletes what the person or the folder wrote. When the
organisation makes the policy looser, each choice comes back as it was.

A choice that the policy refuses is refused with the error `policyRefused`. Its data says
why (`policy`, `budget`, `stopAll`, `noPolicy` or `update`), the rule, and the words that
the clients show under **Set by your organisation**. The lists that the machine sends mark
each refused choice with `setBy`: the runtimes, the modes and models of an agent, the
sandbox, the cost state, the helper limits of a folder and the pass-through names. A
marketplace that the policy does not allow is not listed.

## Who asks matters

- **A person** who asks for a looser mode, a model or a runtime that is not allowed, or the
  sandbox off, gets a refusal.
- **A helper or a workflow** that asks for a looser mode starts in the ceiling, and its chat
  says so. A runtime or a model that is not allowed is refused for it too.
- **A running agent** meets a new policy at its next turn. Its mode goes down to the
  ceiling, and its chat says why. A runtime or a model that is now refused stops the next
  turn: what was sent waits, and the chat says why. A turn that runs is not stopped, except
  by the kill switch.

## Offline

The machine keeps the newest signed policy in `<root>/policy.json` (0600), and the highest
version it applied in `<root>/policy-seen.json`. It checks the signature with the key of its
control plane, also when it starts with no network. So a machine on a plane keeps its
policy.

A machine that had a policy and has none that it can trust starts no agent, turn, helper or
workflow run. It says: "Agents Host has no policy from your organisation. Connect to the
network." This occurs when:

- the file is deleted;
- the file was edited, so its signature fails;
- the file is older than the version that the machine applied.

A policy with a lower version than the one the machine holds is refused. Only a newer
signed policy from the control plane can change the policy on a machine. After a rotation of
the control key, a policy that the old key signed is trusted for 30 days, until the control
plane signs it again.

## The kill switch

When an admin turns on **Stop All Agent Work**, each machine stops each running turn, as
**Stop** does. Then it refuses new agents, new prompts, helpers and workflow runs. Agents,
their conversations and their queued prompts are kept. When the admin turns it off, nothing
starts again by itself. Each person sends their next prompt.

## Budgets

The machine counts the person's spend today as it counts their own limits: the cost that
the runtimes report, in US dollars, and the tokens that a limit counts (fresh input and
output). At a budget, the machine refuses new turns at once. The control plane adds the
spend of all the person's machines, and tells each machine when the person is at a budget
(`capReachedUntil`). The control plane's count wins.

While a budget is set, a runtime that reports neither a cost nor tokens (Cursor,
Antigravity, Grok) is refused, because the organisation cannot measure its use. An admin
can allow one by name in `allowUnmetered`.

## What the policy does not protect against

Agents Host and `agentsd` run as the user of the machine, and never ask for admin rights. A
user who changes the program can avoid the rules. The policy stops mistakes and ordinary
use. The signature makes an edit to the policy file useless, but it is not a security
boundary against the user of the machine.

## See also

- [Set an organisation policy](../how-to/set-an-organisation-policy.md): Console ▸ Policy,
  the Policy pane on every client, and the kill switch.
- [Policy](../reference/policy.md): every field.
- [Pin machines with MDM](../how-to/pin-machines-with-mdm.md): a configuration profile or
  `/etc/agents/policy.json` that says which control plane a machine joins.
