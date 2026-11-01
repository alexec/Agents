---
diataxis: explanation
description: How the policy's three layers (Organisation, You, Folder) decide what agents may do, why each layer can only make a rule tighter, and where each layer is kept.
---

# Policy layers

One policy tells what agents may do (#2957). It has three layers. From the top down, they
are:

- **Organisation**: the organisation's policy, signed on the control plane. See
  [Organisation policy on a machine](organisation-policy.md).
- **You**: your own rules. You edit them in **Settings ▸ Agents ▸ Policy**.
- **Folder**: a folder's rules, in its file `.agents/policy.json`, committed with the
  folder's code.

A slot for a **Group** layer, between Organisation and You, is kept for later.

## The tightest value applies

Each layer can set the same rules, and each rule is optional. A layer can only make a rule
tighter. For each rule, the machine finds the tightest value of all the layers that set it.
That value applies. A rule that no layer sets has its default.

"Tighter" has one meaning for each rule. A lower permission mode is tighter (Plan is the
tightest), a smaller amount of money or tokens is tighter, fewer helpers or workflows is
tighter, a longer wait after a burst of notices is tighter, and **Off** is tighter for
**Agents may archive the chats I start**. For a list (runtimes, marketplaces, variables), a
name that one layer leaves out is not allowed.

## A capped value is kept

When a layer above caps your value, the machine does not change or delete your value. It
caps the effect only. **Settings ▸ Agents ▸ Policy** shows your value with **Kept, not
used**, and a 🔒 line that names the layer that decides, such as **Your organisation: at most
Approve for me**. When that layer lets it, your value applies again.

**Where this comes from**, under each rule, shows every layer from the top down, with its
value or **Not set**, and lights the layer that decides.

## Where each layer is kept

- The organisation's layer is signed by the control plane's key. Every machine of the
  organisation follows it, also offline.
- Your layer is kept on your Mac's host and signed with a key that only that host has. Your
  other machines get a copy through the control plane, or through your Mac window's direct
  link to a server. A machine checks the signature and keeps the newest good copy. An agent,
  an MCP tool, a workflow or a folder file cannot change your layer.
- A folder's layer is a file in the folder. A change from outside the app that only makes
  rules tighter applies at once. A change that makes a rule looser waits for your OK, as a
  change to `.agents/folder.json` does.

## What moved

The limits that were in Settings ▸ Cost, Settings ▸ Notifications, the archive switch of
Settings ▸ Sidebar and the helper limits of Folder Settings ▸ General are rules of your
layer now. On first start, the machine reads your old values into your layer once.
Control plane ▸ Policy is now **Organisation Policy**. Resources stays a setting: it says
what a machine can take, not what an agent may do.

See [Policy](../reference/policy.md) for the fields, and
[Settings and the Resources page](../reference/settings.md) for each control.
