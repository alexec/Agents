---
diataxis: reference
devices: [mac, iphone, ipad]
description: Groups of people, and the machine providers each group may start machines from.
---

# Groups

**Settings ▸ Control plane ▸ Groups** lists the groups on the control plane (#1761). A group
is **everyone**, or the people you name. A group owns machine providers: only its people
see a provider and start machines from it. A machine that a person starts is theirs.

## What an admin does

- **Make a Group…** gives the group a name, and either turns on **Everyone** or names the
  people. Everyone takes in each person who joins later too.
- **Edit…** changes the name or the people. **Remove…** removes the group. You cannot remove
  a group that a provider still has: give the provider to another group first.
- On **Machine Providers**, each provider has a group picker. **Admins only** is the
  default, and every provider made before groups has it.

Only an admin adds, changes or removes a provider. An admin sees every provider, but starts
machines only from the providers of a group the admin is in, or from those for admins only.

## What a member sees

A member sees the groups they are in, and only the providers of those groups. On a provider,
a member sees only the workspaces of their own machines, and those on no machine.

## On the wire

`groups/list`, `groups/set`, `groups/remove` and `providers/setGroup`, with
`control/groupsChanged` when a group changes (`Packages/Wire/control.openrpc.json`). Groups
are kept in the control plane's store at `v1/groups/<id>.json`.

## Bots

A bot does the team's work on events (#1761). It is a user with no clients and no sign-in,
in one group. Its machines are enrolled by an admin, with a join code made for the bot
(`machines/startEnroll` with `as`).

- **Nobody acts on a bot's machine.** A client cannot start, message or answer an agent
  there. An admin is told the machine is a bot's; anyone else is told there is no such
  machine. An admin can stop a run (`bots/stopRun`).
- **Nobody answers there.** A bot's agents have no ask tools (`ask_question`). A question
  from the runtime is declined, and a permission the bot's permission mode did not already
  allow is refused; the agent carries on. A need for attention goes to the admins.
- **It runs once per trigger.** A workflow whose `runs-on:` names the bot runs on its
  machines. The first machine to claim a trigger runs it (`workflows/claimRun`); the
  others do not.
- **It stops at its cap.** A bot, and a group, can have a daily cap in US dollars
  (`bots/setCaps`, and `caps` in `groups/set`). When the bot's spend today (UTC), or its
  group's bots' spend together, reaches a cap, its machines start no workflow until the
  end of the day, and the admins are told (`control/capReached`). A bot's machine sends its
  spend as each run ends.
