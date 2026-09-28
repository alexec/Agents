---
name: ship-app
description: Build main and put it live on Alex's own devices. Install the Remote on his paired iPhone and iPad, and relaunch the real Mac app (window, daemon and phone bridge) on the new build. Use when asked to ship, deploy, install, relaunch or restart "the app", "everything" or "the real app" after a merge, or to put the Remote on the phone or iPad. Not for testing a change. That is run-app, on a scratch root.
---

# Ship main to the real app and devices

Run the one script. It builds, installs, and relaunches. Do not reimplement its
checks or write a watcher around it. Say in your report that you shipped it.

```sh
.claude/skills/ship-app/scripts/ship.sh
```

`--no-mac` installs the iPhone and iPad only. `--no-devices --no-build` only
relaunches the Mac. `--device <UDID>` (repeatable) picks one device. `--now`
relaunches the Mac after 3s instead of 20s.

The script prints one line per running Agents window before it builds:

```
app <pid> <worktree> <command>
```

The primary checkout is `main`. A linked worktree is that worktree's directory
name, which is also what the window title leads with. The real app is the debug
build of main with no `--root`. Any other debug process from that checkout means
an agent failed to create a worktree. The script says so and stops. Tell Alex
the line it printed.

It refuses unless the main checkout (found from the script's own path, so a
worktree copy works too) is on `main`. It builds there, into `build/DD` and
`build/DD-ios`, and never edits, stashes, or checks anything out. Logs are
`/tmp/ship-app-<sha>/`. The Mac relaunch is the same script, detached, because
it quits this session's daemon. It checks every pid's command line before
signalling it, and it never kills by pattern. Its log is
`/tmp/main-restart-all-<sha>.log` (appended, so an older block for the same sha
can remain).

It stops without restarting anything if a relaunch is already pending, or if
any other build's window is attached to the real root (no `--root`). In the
second case, ask Alex before quitting those windows.

A device that is not listed is asleep, off Wi-Fi, or unplugged. `xcrun devicectl
list devices` shows it. Ask Alex to wake it. Do not retry in a loop. A launch
fails on a locked device, but the install still counts.

This session may end when the daemon quits. When it comes back, the relaunch
log must contain all of these:

- `new daemon N: …/build/DD/…/agentsd`
- `CLAUDE vars: 0`
- a `window:` line
- a `bridge:` line

Record the new pids in the `agents-app-hosts-this-session` memory, as earlier
restarts did.
