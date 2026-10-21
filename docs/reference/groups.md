---
diataxis: reference
devices: [mac, iphone, ipad]
description: Groups of people, and the workspace providers each group may start machines from.
---

# Groups

**Settings ▸ Control plane ▸ Groups** lists the groups on the control plane (#1761). A group
is **everyone**, or the people you name. A group owns workspace providers: only its people
see a provider and start machines from it. A machine that a person starts is theirs.

## What an admin does

- **Make a Group…** gives the group a name, and either turns on **Everyone** or names the
  people. Everyone takes in each person who joins later too.
- **Edit…** changes the name or the people. **Remove…** removes the group. You cannot remove
  a group that a provider still has: give the provider to another group first.
- On **Workspace Providers**, each provider has a group picker. **Admins only** is the
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
