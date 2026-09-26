---
name: ship-app
description: Build main and put it live on Alex's own devices — install the Remote on his paired iPhone and iPad, and relaunch the real Mac app (window, daemon and phone bridge) on the new build. Use when asked to ship, deploy, install, relaunch or restart "the app", "everything" or "the real app" after a merge, or to put the Remote on the phone or iPad. Not for testing a change — that is run-app, on a scratch root.
---

# Ship main to the real app and devices

This replaces Alex's running app, the daemon hosting his chats (and probably this
session), the phone bridge, and the Remote he uses on his iPhone and iPad. Only
ship a build of `main` that works; say in your report that you shipped it.

```sh
.claude/skills/ship-app/scripts/ship.sh            # build, devices, Mac
.claude/skills/ship-app/scripts/ship.sh --no-mac   # just the iPhone/iPad
.claude/skills/ship-app/scripts/ship.sh --no-devices --no-build   # just relaunch the Mac
```

Other options: `--device <UDID>` (repeatable) to pick one device, `--now` to relaunch
the Mac after 3s instead of 20s.

## What it does

1. Refuses unless the main checkout (found from the script's own path, so a worktree
   copy works too) is on `main`. It builds there, into `build/DD` (Mac app, bridge)
   and `build/DD-ios` (Remote), one scheme after another, with
   `-skipPackagePluginValidation -skipMacroValidation`. Logs go to `/tmp/ship-app-<sha>/`.
   It builds only; it never edits, stashes or checks anything out.
2. Installs `Agents.app` (the Remote, `com.alexecollins.agents.remote`) on every
   paired physical iPhone/iPad `devicectl` can see, and relaunches it. A directory lock,
   `/tmp/agents-device-install.lock`, keeps it to one installer at a time; failed installs
   retry three times, 30s apart. A launch fails on a locked device, but the install
   still counts.
3. Writes `/tmp/main-restart-all-<sha>.sh` and runs it with `nohup`. After 20s it quits the
   real window and the daemon in the real root's `daemon.lock`, opens main's build with an
   `env -i` environment (no `CLAUDE_*` vars), then restarts `agents-bridge` with
   `AGENTS_ROOT` set. It checks every pid's command line before signalling it. It
   never kills by pattern.

## Before running

- It stops without restarting anything if another `main-restart-all-*.sh` is still
  pending, or if any other build's window is attached to the real root (no `--root`).
  In the second case, ask Alex before quitting those windows.
- If a device is not listed, it is asleep, off Wi-Fi or unplugged. `xcrun devicectl
  list devices` shows it. Ask Alex to wake it; don't retry in a loop.

## After

This session may end when the daemon quits. When it comes back (or from any
session), read `/tmp/main-restart-all-<sha>.log`. Each of these must hold:
- `new daemon N: …/build/DD/…/agentsd`
- `CLAUDE vars: 0`
- a `window:` line
- a `bridge:` line

Record the new pids in the `agents-app-hosts-this-session` memory, as earlier
restarts did.
