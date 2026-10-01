---
name: ship-app
description: Build main and put it live on Alex's own devices. Install the Remote on his paired iPhone and iPad, and put the new Agents Host (control plane and this Mac's host) and window live on the Mac. Use when asked to ship, deploy, install, relaunch or restart "the app", "everything" or "the real app" after a merge, or to put the Remote on the phone or iPad. Not for testing a change. That is run-app, on a scratch root.
---

# Ship main to the real app and devices

Run the one script. It builds, installs, and relaunches. Do not reimplement its
checks or write a watcher around it. Say in your report that you shipped it.

```sh
.claude/skills/ship-app/scripts/ship.sh
```

`--no-mac` installs the iPhone and iPad only. `--no-linux` skips rebuilding the Linux
hosts (`scripts/build-linux-agentsd.sh`, into `App/Resources/servers`), which the build
otherwise does first, since Agents Host carries them and a stale one cannot join. `--no-devices --no-build` only
relaunches the Mac. `--device <UDID>` (repeatable) picks one device. `--now`
relaunches the Mac after 3s instead of 20s.

## What runs on the Mac

Since 058 the Mac runs:
- **Agents Host**, at `~/Applications/Agents Host.app`. Its two launch agents
  (`com.alexecollins.agentshost.control` and `.daemon`) are the control plane and this
  Mac's host, registered under Login Items. The script swaps the new bundle in and
  `launchctl kickstart -k`s both jobs.
- **The window**: the `AgentsStore` build, a client of the control plane. It runs from
  `~/Applications/AgentsLive/<sha>-<time>/Agents.app`, never from `build/DD-store`. Any
  build in the main checkout writes over `build/DD-*`.

There is no phone bridge to start. The Remote reaches the control plane itself.

The script builds `AgentsHost` into `build/DD-host`, `AgentsStore` into `build/DD-store`
and the Remote into `build/DD-ios`, one after another in the main checkout. Logs are
in `/tmp/ship-app-<sha>/`. It refuses when:
- the main checkout is not on `main`;
- a build is running from the main checkout's `build/` (an agent forgot its worktree);
- the build is not signed by the team;
- a relaunch is already pending.

The Mac half runs detached (`--restart`), because restarting the host ends this
session's turn. Its log is `/tmp/main-restart-all-<sha>.log`. When the session comes
back, the log must show:
- both `com.alexecollins.agentshost.*` jobs with pids and `CLAUDE vars: 0`;
- a `window:` line.

## Since the switch

The developer window and its own jobs (`com.alexecollins.agents.control` / `.host`) are
gone: T105a moved this Mac to Agents Host on 2026-09-30, and T106 removed that window
and the bridge. If `launchctl print gui/$(id -u)/com.alexecollins.agents.control` still
finds a job, it is a leftover: ask Alex before booting it out, and turn "Agents" off
under Login Items.

## Devices

A device that is not listed is asleep, off Wi-Fi, or unplugged. `xcrun devicectl
list devices` shows it. Ask Alex to wake it. Do not retry in a loop. A launch
fails on a locked device, but the install still counts.

Record the new pids in the `agents-app-hosts-this-session` memory, as earlier
restarts did.
