---
diataxis: index
description: Why the app works the way it does.
---

# Explanation

Why the app works the way it does: the ideas behind it and the trade-offs it makes.
Nothing here needs doing; it is for understanding.

- [Direction](direction.md): what Agents is for, the three ways to run it, how one
  organisation's data is kept apart, and where data lives and is backed up.
- [Why Agents](why-agents.md): why you would run your coding agents here, alongside the
  editor you already use, and when something else is better.
- [The control plane](control-plane.md): hosts, clients, copies and the store, where to
  run it, and what happens when it is down.
- [Org keys and gateways](org-keys-and-gateways.md): where an organisation's keys and
  gateways are kept, how each machine gets them sealed to its own key, and what that does
  not protect against.
- [Org identity](org-identity.md): how an organisation's own sign-in provider, its
  tickets and its claimed domains work, and what they do not protect against.
- [People and machines](people-and-machines.md): why each client is a person's and each
  machine one user's, what an admin sees, and why machines are not shared.
- [Compliance pack](compliance/index.md): for an organisation's IT and security team: the
  data flow, the sub-processors, a security overview, and data and retention.
- [Organisation policy on a machine](organisation-policy.md): how each machine follows the
  organisation's policy as a ceiling, offline too, and what it does not protect against.
- [The window and the host](window-and-daemon.md): why agents keep working when the
  window is closed, what Agents Host does, and what happens when the Mac restarts.
- [Why agents' own tools are taken away](scoped-tools.md): what a runtime loses in the
  app's sessions, what it keeps, and why your own setup is untouched.
- [Views in a conversation](views.md): how a tool's `ui://` view is drawn on every device,
  what it may reach, and what its messages do.
- [Versions and capabilities](versions.md): how the clients, the hosts and the control
  plane work together at different versions, and what a version number means.
- [Connector levels](connector-levels.md): what Tools, Events, Views, Workflows and Tested
  mean, why they exist, and where the connectors that Agents makes come from.
- [Folders, hosts and worktrees](folders-machines-worktrees.md): a folder is a directory on
  one machine, and an agent can have a worktree of its own.
- [Leases on shared resources](leases.md): how agents take turns with the screen, a
  browser or a simulator, and what you can end.
- [How the phone and iPad reach your agents](phone-and-ipad.md): every host, at home and
  away, grants, and forgetting a device.
- [How a Live Activity keeps up](live-activities.md): why a turn from the phone shows on the
  Lock Screen, how updates reach it, and why a pushed update carries no words.
- [Compaction in each runtime](compaction-by-runtime.md): whether a long conversation
  compacts itself in each runtime, what the app sees when it does, and what it could pass.
- [Token-compression tools](token-compression-tools.md): whether rtk or Headroom would cut
  what agents cost, how either would plug in, and what the app could do instead.
- [What agents are sent each turn](token-cost-of-tools.md): what the app's own tools add to
  every request, what is cached, and what was changed to cut it.
