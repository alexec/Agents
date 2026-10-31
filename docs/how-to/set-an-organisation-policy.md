---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Set your organisation's policy in Console ▸ Policy, read it on every client, and stop all agent work in an incident.
---

# Set an organisation policy

The organisation's policy (#998) is one document of rules on your control plane. Every
machine follows it as a ceiling above each person's and each folder's own settings. A
person can choose the same or less, never more. See
[Organisation policy](../explanation/organisation-policy.md) for why, and
[Policy](../reference/policy.md) for each field.

A control plane with no policy works as before. Nothing is capped until an admin saves one.

## Before you start

- You are an admin of the control plane. The local owner is an admin.
- You use the web page. Console ▸ Policy is on the web page only. The Mac and the Remote
  show the policy, read only, and give admins the kill switch.
- Your machines run this version of Agents Host or later. A machine that is older does not
  follow the policy. Console ▸ Machines says **Does not follow policy** under it.

## Set the rules

1. On the web page, choose **Console** at the top, then **Policy**.
2. Set each rule that you need. A rule that you do not set has no ceiling.
   - **Loosest mode**: the loosest permission mode that any agent can use, from **Ask** to
     **Bypass Permissions**.
   - **Require the command sandbox**: refuses a runtime that has no command sandbox that the
     app can turn on, and refuses the sandbox choice **Off**. Today only Claude, Codex and
     Grok have one.
   - **Runtimes**: turn on **Allow only the runtimes chosen**, then choose the runtimes. For
     each runtime, you can type the models that are allowed, with commas between them and
     `*` at the end (`claude-sonnet-*`). An empty field allows every model.
   - **Marketplaces**: turn on **Allow only the marketplaces named**, type their ids, and
     choose whether to refuse MCP servers added by hand.
   - **Budget for Each Person**: dollars and tokens a day, and dollars and tokens an agent.
     A day is a UTC day. A runtime that reports tokens and no cost (for example, one on a
     subscription) counts against the token budget. A runtime that reports neither (Cursor,
     Antigravity, Grok) is refused while a budget is set, unless you allow it by name.
   - **Helper Sessions in a Folder**: the most helper sessions running, and not archived,
     in one folder.
   - **Variables Passed to Runtimes**: turn on **Allow only the variables named**, and type
     the variable names that a person's own pass-through list can name, with `*` at the end.
   - **Machines**: **Refuse agents on machines that do not follow the policy**.
3. Read **What Changes**. It lists each rule that changes, and what the new policy refuses:
   no runtime left, runtimes that the sandbox or the budget refuses, and machines that do not
   follow the policy.
4. Choose **Save**. If no runtime is left, the page asks you first.

Every online machine has the new policy within seconds. A machine that is offline gets it
when it connects. Until then, it keeps the last policy that it had.

Your edits stay on the page while you open another Console page. The Console's list says
**Not saved** beside Policy until you save or choose **Revert**.

If another admin saved the policy after you opened it, **Save** is refused. Open the page
again, then make your change again.

## See which machines follow it

Choose **Console ▸ Machines**. Under each machine's version:

- **Follows policy v4**: the machine has this version of the policy.
- **Has v3 of v4**: the machine has an older version. It gets the new one when it connects.
- **Has no policy yet**: the machine follows policies, but has not said that it has this one.
- **Does not follow policy**: the machine is too old. Update Agents Host on it.

## Read the policy on any client

Every person can read the rules that apply to them:

- **Mac**: **Agents ▸ Settings…**, then **Policy** under Control plane.
- **iPhone and iPad**: **Settings…**, then **Policy**.
- **Web page**: **Settings**, then **Policy** under Control plane.

The pane lists each rule in words, the version, and who changed it last. With no policy, it
says "Your organisation sets no policy." An admin also sees **Edit in Console**, which opens
Console ▸ Policy on the web page.

## See what the policy refuses

Every client shows a choice that the policy refuses. The choice is dimmed, and
**Set by your organisation** is under it. On the Mac, hold the pointer over the line to read
the rule. On the iPhone, the iPad and the web page, the rule is on the line.

- **New agent**: a runtime that is not allowed is under its own heading, or under
  *Can't start* on the web page. A mode above the ceiling, a model that is not allowed, and
  each sandbox choice except **On** when the sandbox is required are dimmed.
- **Chat**: the mode menu, the model menu and the sandbox menu are the same. The sandbox
  failure card does not offer **Continue without sandbox** when the sandbox is required.
- **Runtimes**: Settings ▸ Agent Runtimes on the Mac, Runtimes on the iPhone and the iPad,
  and Activity ▸ Runtimes on the web page. A runtime that is not allowed says so. Each list
  also shows your own pass-through variables. A variable that the policy does not allow is
  dimmed, and the machine does not pass it.
- **Cost**: Settings ▸ Cost on the Mac, and Spending on the other clients, show the
  organisation's budget under your own limits. The lower number applies.
- **Folder Settings** on the Mac: a helper limit above the organisation's cap says so.
- **Connectors** on the Mac: a marketplace that is not allowed is not listed.
  **Add by Hand** does not add a machine when servers added by hand are not allowed.

When a machine refuses a turn or a start, the error says **Set by your organisation** and
the rule.

## Stop all agent work

Use this in an incident, for example a leaked key or a runaway cost.

1. Open **Policy** in Settings on any client, or **Console ▸ Policy** on the web page.
2. Choose **Stop All Agent Work**. The question says how many agents are running now.
3. Confirm.

Every online machine stops each running turn, refuses new agents and prompts, and pauses
every workflow. Machines of bots stop too. Agents and their conversations are kept. Every
client shows a red strip at the top: "Your organisation has stopped all agent work.", with
who stopped it. The prompt field says why it cannot send.

To start again, choose **Resume Agent Work**, then confirm. Nothing starts again by itself.
Each person sends their next prompt, and paused workflows run at their next trigger.

## See also

- [Organisation policy](../explanation/organisation-policy.md)
- [Policy](../reference/policy.md)
- [Limit spending](limit-spending.md)
- [Settings](../reference/settings.md)
