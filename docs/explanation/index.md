---
diataxis: index
description: Why the app works the way it does.
---

# Explanation

Why the app works the way it does: the ideas behind it and the trade-offs it makes.
Nothing here needs doing; it is for understanding.

- [The window and the daemon](window-and-daemon.md): why agents keep working when the
  window is closed, and what happens to them when the Mac restarts.
- [Why agents' own tools are taken away](scoped-tools.md): what a runtime loses in the
  app's sessions, what it keeps, and why your own setup is untouched.
- [Projects, hosts and worktrees](projects-hosts-worktrees.md): a project is a folder on
  one machine, and an agent can have a worktree of its own.
- [Leases on shared resources](leases.md): how agents take turns with the screen, a
  browser or a simulator, and what you can end.
- [How the phone and iPad reach the Mac](phone-and-ipad.md): the local connection,
  notifications, and what each device can do.
