---
name: ship-app
description: Build main and install the Remote on Alex's paired iPhone and iPad. Copying the Mac app into Applications and restarting its login items happens only with --install-mac, and only when Alex asks to install on this Mac. A merge wave does not run this. Not for testing a change. That is run-app, on a scratch root.
---

# Ship main to the real app and devices

Run the one script. It builds, and installs the Remote. It does not copy the Mac app
into Applications or restart login items. Do not reimplement its checks or write a
watcher around it.

```sh
.claude/skills/ship-app/scripts/ship.sh
```

Pass `--install-mac` only when Alex has asked to install on this Mac. That copies
Agents Host and the window into `~/Applications` and `launchctl kickstart`s the
login-item jobs. A development run, a test, and a merge wave never pass it.

`--no-linux` skips rebuilding the Linux hosts (`scripts/build-linux-agentsd.sh`, into
`App/Resources/servers`), which the build otherwise does first, since Agents Host
carries them and a stale one cannot join. `--no-devices` skips the iPhone and iPad.
`--device <UDID>` (repeatable) picks one device. `--now` relaunches the Mac after 3s
instead of 20s, and only with `--install-mac`. `--build-only` builds in the checkout
the script is in (run a worktree's copy to build that worktree), checks the products,
and stops: nothing is installed or relaunched. Use it to prove a change to this script.

## What it builds

Everything ships in the **Live** configuration (#220, Alex 2026-10-04): optimised like
Release (`-O`, whole module, no `DEBUG`), but signed for development like Debug.
`Release` is the App Store archive's (Apple Distribution, App Store profiles and
entitlements), which neither `devicectl` nor a copy in `~/Applications` can run. The
products are under `build/DD-*/Build/Products/Live/` (`Live-iphoneos/` for the Remote).
The script refuses to install a bundle holding a `*.debug.dylib` or `__preview.dylib`.

Debug-only scratch hooks (`-open-agent`, `AGENTS_TEST_*`, `events/raise`,
`disk-free-override`, the reconnect notification) are absent from the live app. Scratch
walks (run-app), merge-wave's checks and the tests stay on Debug.

## What runs on the Mac

This section is `--install-mac` only. Without that flag, none of it happens.

Since 058 the Mac runs:
- **Agents Host**, at `~/Applications/Agents Host.app`. Its two launch agents
  (`com.alexecollins.agentshost.control` and `.daemon`) are the control plane and this
  Mac's host, registered under Login Items. The script swaps the new bundle in and
  `launchctl kickstart -k`s both jobs.
- **The window**: the `AgentsStore` build, a client of the control plane. It runs from
  `~/Applications/AgentsLive/<sha>-<time>/Agents.app`, never from `build/DD-store`. Any
  build in the main checkout writes over `build/DD-*`.

There is no phone bridge to start. The Remote reaches the control plane itself.

The script builds `AgentsHost` (Live) into `build/DD-host`, `AgentsStore` into `build/DD-store`
and the Remote into `build/DD-ios`, one after another in the main checkout, through
`scripts/build-cache.sh` (#234): the packages and compiled outputs come from the cache in
`~/Library/Caches/Agents-build/` that every worktree and wave shares, so a ship after a
wave recompiles little. Logs are in `/tmp/ship-app-<sha>/`. It refuses when:
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
