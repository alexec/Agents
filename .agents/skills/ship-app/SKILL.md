---
name: ship-app
description: Build main and install Agent Loops, the Mac window, and the Remote on Alex's paired iPhone and iPad, and, with --control-plane, deploy main to the live control plane (control.agentloops.dev). The Mac install runs by default; use --no-mac to skip it. A merge wave does not run this. Not for testing a change. That is run-app, on a scratch root.
---

# Ship main to the real app and devices

Run the one script. It builds and installs Agent Loops, the Mac window and the Remote.
Do not reimplement its checks or write a watcher around it.

```sh
.claude/skills/ship-app/scripts/ship.sh
```

Run it from a worktree of your own at origin/main (#797): the worktree's copy builds and
installs that worktree, and refuses unless it is clean and at origin/main. Run from the
main checkout, it builds there instead, which a lane's build can write over.

The script installs the Mac app by default. That copies Agent Loops and the window into
`~/Applications` and `launchctl kickstart`s the login-item jobs. Pass `--no-mac` to skip
the Mac install. `--install-mac` remains accepted as an alias for the default.

`--no-linux` skips rebuilding the Linux hosts (`scripts/build-linux-agentsd.sh`, into
`App/Resources/servers`), which the build otherwise does first, since Agent Loops
carries them and a stale one cannot join. It is Go (#1314) and takes seconds.
`--no-devices` skips the iPhone and iPad.
`--device <UDID>` (repeatable) picks one device. `--now` relaunches the Mac after 3s
instead of 20s. `--build-only` builds in the checkout
the script is in (run a worktree's copy to build that worktree), checks the products,
and stops: nothing is installed or relaunched. Use it to prove a change to this script.

## The live control plane (#4712)

`--control-plane` also deploys the checkout to the live control plane,
control.agentloops.dev, on Google Cloud. It is off by default. Give it when Alex asks
for the control plane to be deployed or shipped, or for main on everything. Alex
approved its restart for a ship with `--control-plane` (2026-11-11). To deploy only the
control plane, give `--control-plane --no-mac --no-devices`.

The script runs `deploy/gcp/up.sh` in the checkout that ships, before the Mac restart:
- On a release tag (`scripts/version.sh` says `X.Y.Z`), the VM pulls that release's image.
- On any other commit, `--build` builds the image here, for linux/amd64, from the
  checkout, and copies it to the VM. This needs Docker with buildx running on this Mac.

It acts as `~/.agents/secrets/gcp-agents-control.json` and keeps the store, the APNs key
and the firewall. It refuses a checkout with uncommitted changes. Lease "build" for 60
minutes for a ship with `--control-plane`: the image build is one more build.

The log is `$LOGS/control-plane.log`. When it ends, the script prints the version that the
control plane serves (`agents-control <version> (go)`), which `up.sh` checks. A failed
deploy does not stop the Mac or the devices, but the script exits 1. Then never roll back
the store and never run `deploy/gcp/down.sh`: file a `bug` with `priority:high`, the step
and its first error (never a secret), as the release skill's step 5 says. After it, check
from this Mac that `curl -fsS https://control.agentloops.dev/healthz` says `ok`.

A release deploys its own version (the release skill, step 5). A ship with
`--control-plane` between releases puts a `-dev` version there, which the next release
replaces.

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

This section runs by default. Use `--no-mac` to skip it.

Since 058 the Mac runs:
- **Agent Loops** (was Agents, and Agents Host), at `~/Applications/Agent Loops.app`. Its two launch agents
  (`com.alexecollins.agentshost.control` and `.daemon`) are the control plane and this
  Mac's host, registered under Login Items. The script swaps the new bundle in and
  `launchctl kickstart -k`s both jobs. The jobs name their app by bundle id only, so
  launchd can start them from any copy that LaunchServices knows (#3451). Before the
  restart, the script unregisters every other copy that is on disk. launchd keeps the
  copy it found while that copy is on disk (#3521), so the script also moves aside the
  copy the jobs run from and restarts them. When a login item was registered from that
  copy, launchd does not start it from another (#4130), so if the jobs do not come up on
  the installed copy, the installed copy registers them again
  (`Agents Host --register-jobs`). Then the copy goes back, and the script checks that both jobs
  run from `~/Applications`. `ship.sh --check-host` shows the copies and where
  the jobs run from, and changes nothing.
- **The window** is the same app since #4225: there is no App Store window to install
  (#4229). Any build in the main checkout writes over `build/DD-*`.

There is no phone bridge to start. The Remote reaches the control plane itself.

The script builds `AgentsHost` (Live) into `build/DD-host` and the Remote into
`build/DD-ios`, one after another in the checkout it runs from, through
`scripts/build-cache.sh` (#234): the packages and compiled outputs come from the cache in
`~/Library/Caches/Agents-build/` that every worktree and wave shares, so a ship after a
wave recompiles little. Logs are in `/tmp/ship-app-<sha>/`. It refuses when:
- the main checkout is not on `main`, or a worktree is not clean at origin/main;
- a build is running from the main checkout's `build/` (an agent forgot its worktree);
- the build is not signed by the team;
- a relaunch is already pending.

The Mac half runs detached (`--restart`), because restarting the host ends this
session's turn. Its log is `/tmp/main-restart-all-<sha>.log`. When the session comes
back, the log must show:
- both `com.alexecollins.agentshost.*` jobs with pids, programs in
  `~/Applications/Agent Loops.app`, and `CLAUDE vars: 0`;
- a `window:` line;
- no `FAILED:` line. That line, and a notification, mean the jobs still run from
  another copy: run `ship.sh --check-host`.

## Since the switch

The developer window and its own jobs (`com.alexecollins.agents.control` / `.host`) are
gone: T105a moved this Mac to Agents Host on 2026-09-30, and T106 removed that window
and the bridge. If `launchctl print gui/$(id -u)/com.alexecollins.agents.control` still
finds a job, it is a leftover: ask Alex before booting it out, and turn "Agents" off
under Login Items.

## Devices

The script checks which devices are available before it builds anything: for each device
devicectl lists, it says whether it will install on it and why, or why it skips it (a
simulator, not paired, not an iPhone or iPad). A paired device that devicectl gives no
hardware details for (a locked iPhone did this on 2026-10-17, #1310) is still installed
on, and the line says what was missing. When neither iPhone nor iPad is available, the
script skips building the Remote too: there is nothing to put it on. `--list-devices`
prints those lines and stops, with nothing built or installed: use it to check which
devices a ship will reach. The choice is `scripts/devices.py`, tested by
`scripts/test_devices.py` against saved listings in `scripts/testdata/` (run in
`scripts/lint.sh`'s checks).

A device that is not listed is asleep, off Wi-Fi, or unplugged. `xcrun devicectl
list devices` shows it. Ask Alex to wake it.

Each device's install runs detached (`--install-device`), the same way the Mac relaunch
does, so it never waits on or delays the Mac. A failed install (a locked phone, a flaky
connection) retries every 2 minutes for up to an hour on its own; `/tmp/ship-install-<udid>-<sha>.log`
says how it went.

Record the new pids in the `agents-app-hosts-this-session` memory, as earlier
restarts did.
