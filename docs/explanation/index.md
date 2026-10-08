---
diataxis: index
description: Why the app works the way it does.
---

# Explanation

Why the app works the way it does: the ideas behind it and the trade-offs it makes.
Nothing here needs doing; it is for understanding.

- [Why Agents](why-agents.md): why you would run your coding agents here, alongside the
  editor you already use, and when something else is better.
- [The control plane](control-plane.md): hosts, clients, copies and the store, where to
  run it, and what happens when it is down.
- [The window and the host](window-and-daemon.md): why agents keep working when the
  window is closed, what Agents Host does, and what happens when the Mac restarts.
- [Why agents' own tools are taken away](scoped-tools.md): what a runtime loses in the
  app's sessions, what it keeps, and why your own setup is untouched.
- [Views in a conversation](views.md): how a tool's `ui://` view is drawn on every device,
  what it may reach, and what its messages do.
- [Projects, hosts and worktrees](projects-hosts-worktrees.md): a project is a folder on
  one machine, and an agent can have a worktree of its own.
- [Leases on shared resources](leases.md): how agents take turns with the screen, a
  browser or a simulator, and what you can end.
- [How the phone and iPad reach your agents](phone-and-ipad.md): every host, at home and
  away, grants, and forgetting a device.
- [Compaction in each runtime](compaction-by-runtime.md): whether a long conversation
  compacts itself in each runtime, what the app sees when it does, and what it could pass.
- [Token-compression tools](token-compression-tools.md): whether rtk or Headroom would cut
  what agents cost, how either would plug in, and what the app could do instead.
