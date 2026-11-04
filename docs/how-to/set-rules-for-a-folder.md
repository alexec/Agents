---
diataxis: how-to
devices: [mac, web]
description: Make the policy tighter for the agents in one folder with Project Settings ▸ Policy, commit the rules with the folder's code, and answer a change that makes them looser.
---

# Set rules for a folder

A folder can have its own layer of the policy (#2957). Its rules apply to every agent that
works in the folder, and they can only make your rules tighter. The rules are kept in the
file `.agents/policy.json` in the folder. Commit the file, and each person who opens the
folder gets the same rules. See [Policy layers](../explanation/policy-layers.md) for how
the layers work together.

## Set a rule

On the Mac:

1. Open the folder, then choose **Project Settings…** (⌥⌘,) and **Policy** in the rail.
2. Each row says **Same as yours** and your value, until the folder sets it.
3. Choose a value. The menu dims each value that is looser than yours, with the reason.
4. Commit `.agents/policy.json` with the folder's code.

On the web page:

1. Open **Settings ▸ Agents ▸ Policy**.
2. Choose the line that says how many folders have their own rules, then choose the folder.
3. Set the rules as on the Mac. Choose **Back** to go back to your own rules.

To remove a rule from the folder, choose **Same as yours**.

A value in the file that is looser than yours stays in the file, and the row says
**Capped by yours**. Your value applies until you loosen yours.

## Answer a change made outside the app

A change to `.agents/policy.json` that only makes the rules tighter applies at once, for
example from a pull. A change that makes a rule looser waits for your OK. Until then, the
rules that you approved last apply. The card names each rule that the change makes looser,
from the old value to the new value:

- **Allow** applies the change.
- **Keep `<old value>`** puts the file back as you approved it last.
- **Show Change** shows the whole change.

A file that is not a valid policy also waits, with the reason.

## When a rule stops an agent

When a rule holds what you sent, or stops a turn at a budget, the chat shows a
**Stopped by a policy** card. It names the rule, the layer that decides and its value. For a
folder's rule, **Change in Project Settings ▸ Policy** opens the folder's layer.
