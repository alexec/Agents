# Implementation Plan: Cloud Agents

**Branch**: `037-cloud-agents` (worktree branch `agents/speckit-specify-cloud-agents`) | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/037-cloud-agents/spec.md`

## Summary

The window already talks to `agentsd` through a `DaemonLink`, and the daemon already does all the
work. So a server is **the same daemon, built for Linux, reached through SSH**:

1. **A Linux `agentsd`.** The same `Daemon/Sources` and `AgentsKit`, cross-compiled from the Mac
   with the Swift Static Linux SDK into two fully static binaries (x86-64, ARM64). The five
   Darwin-only pieces get Linux counterparts or are left out: PTY, FSEvents, IOKit power, the
   CloudKit/CryptoKit device mailbox, and the Unix-socket code (R1, R2).
2. **One SSH master per server, owned by the app.** `ssh -M -N` with a private `ControlPath`,
   keep-alives, and one Unix-socket forward: a local socket under the app's root to
   `~/.agents-server/root/daemon.sock` on the server. This is Alex's suggestion. Every other SSH
   step (probe, install, start, remove) is a short `ssh -S <ctl>` over the same master, so the
   person is asked for a host key or a hardware-key touch once, not per step (R3, R4).
3. **The existing client, pointed at the forward.** `SocketLink` already connects to a socket
   path. A server's link is a `SocketLink` at the forwarded path, plus a `start()` that runs
   `agentsd --root ~/.agents-server/root --serve` detached on the server. `DaemonClient`, the
   JSON-RPC protocol and every daemon method are unchanged (R5).
4. **Install by streaming over the master.** No `scp` dependency. `uname -sm` picks the binary;
   `cat > tmp && chmod && mv` puts it in `~/.agents-server/bin/agentsd-<version>`; a symlink
   `current` is swapped last, so a failed install leaves the old version or nothing (R6, FR-025).
5. **Many daemons in one window.** `AppModel` goes from one `DaemonClient` to a `HostSet`: this
   Mac plus each server, each with its own client, link and connection state. There is still one
   `AgentsModel`. Every project and agent that arrives is tagged with the host it came from, and
   project identity becomes *(host, path)*. Calls go to the client of the project or agent they
   concern (R7).
6. **Servers stay up.** On a server the daemon is started with `--serve`, which turns off
   exit-when-idle. Scheduled workflows keep firing with no Mac connected, and a server has no
   battery to save (R8).
7. **What the Mac window does on its own disk moves behind the daemon for server projects.** The
   files pane, image preview, live pages and attachments use the `files/*` methods 034 adds for
   the phone. Show in Finder, Open in…, and Keep awake are hidden (R9, FR-015/016).
8. **Exactly-once sends.** `agents/prompt` and the two answer methods gain an optional
   client-made `requestID`. The daemon remembers the last few hundred and repeats the first
   answer to a retry, so a send that raced a dropped connection is retried safely (R10, FR-020).

See [research.md](research.md) for each decision, [data-model.md](data-model.md) for the new
records, and [contracts/](contracts/) for the SSH commands, daemon changes and UI.

## Technical Context

**Language/Version**: Swift 6.x (strict concurrency), SwiftUI. Mac: Xcode's toolchain as today.
Linux: a swift.org toolchain of the same Swift version plus the matching Static Linux SDK (musl),
installed on the build Mac (R1).

**Primary Dependencies**:
- AgentsKit / AgentsKitCore (in-repo package)
- The person's own `/usr/bin/ssh` (OpenSSH ≥ 6.7 for Unix-socket forwarding, ≥ 7.3 for
  `ProxyJump`; the Mac ships 10.x) and their `~/.ssh/config`, keys, agent and `known_hosts`
- No new Swift packages. The Linux build must not pull in any that the Mac build does not have.

**Storage**:
- Mac: `hosts.json` in the app's root, beside `projects.json`, written only by the app (the Mac
  daemon never reads it). SSH control and forward sockets in `<root>/hosts/`.
- Server: everything under `~/.agents-server/` — `bin/`, `root/` (a normal daemon root, so
  `projects.json`, `agents/`, `workflows.json`, `daemon.log`…), `install.json`. Mode `0700`.

**Testing**:
- `swift test` on the Mac, as today. The SSH layer is tested against a **fake `ssh`**: a script
  on `PATH` that runs the remote command locally under a temporary `HOME`. Install, start,
  version check, forward and removal can then run end to end with the Mac `agentsd` standing in
  for the Linux one (R11).
- `swift build --swift-sdk <arch>-swift-linux-musl` for both architectures as a build gate.
- A real Linux server for the walks. That is Alex's, or a VM he provides; this Mac has no
  container runtime (R11).

**Target Platform**: macOS 27 app; servers are Linux x86-64 and ARM64 with any libc, since the
binary is static.

**Project Type**: macOS app + helper daemon (existing), plus a Linux build of the helper.

**Performance Goals**: reconnect to current state ≤ 10 s after the network returns (SC-003); a
chat, files or terminal action costs one SSH round trip over the local time (SC-004); add-server
to running agent ≤ 2 min (SC-001).

**Constraints**:
- Nothing listens on a network port on the server (FR-006). The daemon socket is in a `0700`
  directory.
- The app never stores or sees a password, passphrase or private key (FR-002). `ssh` runs with
  `BatchMode=yes` except for the one host-key step, which the app shows and confirms itself (R4).
- The socket path limit of 104 bytes applies to the local forward socket too. Paths are
  `<root>/hosts/<8-char id>.sock` (R3).
- Nothing about the phone changes (spec Assumption).

**Scale/Scope**: a handful of servers per person, tens of projects each. ~15 new files, ~30
touched; the largest change is `AppModel` (1,386 lines) moving from one client to many.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled template, so there are no ratified gates.
The project's standing rules, taken from memory and earlier plans, are applied instead:

| Rule | How this plan meets it |
|---|---|
| Settle the UX before building depth | Phase 2 (the grouped list, Add a server sheet, offline strip) is built against the fake-ssh host and walked before install, update and removal get their depth. |
| One daemon owns the work; windows only ask | Kept. A server daemon is an ordinary daemon; the app gains clients, not logic. |
| The daemon gains no network code | Kept. `agentsd` still only listens on a Unix socket. The SSH master belongs to the app. |
| Never mutate source to prove a test | The fake `ssh` is a test fixture, not a switch in product code. |
| Every lane in its own worktree; merge when Alex says | This worktree. Build after 034 (the `files/*` methods) is merged. |

**Post-design re-check**: still passes. No new package dependency; no listener; no change to the
phone.

## Project Structure

### Documentation (this feature)

```text
specs/037-cloud-agents/
├── spec.md
├── wireframes.md + wireframes/
├── plan.md              # this file
├── research.md          # R1–R11
├── data-model.md        # Host, HostState, ServerInstall, host-tagged records
├── quickstart.md        # how to prove it, fake ssh and real server
├── contracts/
│   ├── ssh.md           # every command the app runs over SSH, and what it expects back
│   ├── daemon.md        # --serve, daemon/version, requestID, Linux build flags
│   └── ui.md            # the five screens, bound to the wireframes
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
Packages/AgentsKit/
├── Package.swift                              # Linux: exclude CloudKit/Network/Security files
├── Sources/AgentsKitCore/
│   ├── Hosts/Host.swift                       # NEW  Host, HostID, HostState (Codable, shared)
│   ├── Daemon/DaemonAPI.swift                 # + daemon/version, requestID fields
│   └── Remote/*                               # #if canImport(CloudKit/CryptoKit) guards
├── Sources/AgentsKit/
│   ├── Hosts/                                 # NEW  (Mac only)
│   │   ├── SSHMaster.swift                    # the ssh -M process, keep-alive, forward
│   │   ├── SSHCommand.swift                   # argv building, BatchMode, error classifying
│   │   ├── HostKeyCheck.swift                 # ssh-keyscan + fingerprint + known_hosts append
│   │   ├── ServerInstaller.swift              # probe, stream binary, swap, remove
│   │   ├── ServerLink.swift                   # DaemonLink: SocketLink at forward + remote start
│   │   └── HostStore.swift                    # hosts.json
│   ├── Terminal/PTY.swift, ShellSession.swift # Darwin → Glibc/Musl
│   ├── Files/FolderWatch.swift                # FSEvents on Mac, inotify on Linux
│   ├── Power/*                                # IOKit on Mac, no-op on Linux
│   ├── Client/SocketLink.swift                # Darwin.connect → platform connect
│   └── Daemon/
│       ├── DaemonCore+Lifetime.swift          # --serve: never idle-exit
│       ├── DaemonCore+Requests.swift          # NEW  requestID memory
│       └── DaemonServer.swift                 # platform socket calls
├── Tests/AgentsKitTests/Hosts/                # NEW  fake-ssh end-to-end, parser, installer
Daemon/Sources/main.swift                      # --serve, --version
scripts/build-linux-agentsd.sh                 # NEW  two static binaries → App/Resources/servers/
project.yml                                    # copy App/Resources/servers into the bundle
App/Sources/
├── AppModel.swift                             # one client → HostSet; route calls by host
├── Hosts/                                     # NEW
│   ├── HostSet.swift                          # connection per host, reconnect, state
│   ├── AddServerSheet.swift                   # wireframe 2
│   ├── RemoteFolderSheet.swift                # wireframe 3B
│   └── ServersSettingsView.swift              # wireframe 5
├── Projects/ProjectListView.swift             # host groups, New project submenus
├── Projects/ProjectRow.swift, CloneSheet.swift
├── Chat/OfflineStrip.swift                    # NEW  wireframe 4
├── Chat/PromptBar.swift                       # disable Send offline; attachments via files/write
├── Sidebar/FilesPane.swift, ImageFile.swift   # files/* for server projects
├── Sidebar/OpenElsewhere.swift                # hidden for server projects
└── AgentsApp.swift                            # Servers settings tab
```

**Structure Decision**: SSH lives in `AgentsKit` (Mac half), not the app target, so it is
reachable from `swift test` like the rest. The shared record (`Host`) is in `AgentsKitCore`. The
Linux build uses the same targets with platform guards. It does not get a separate package,
because a fork of the daemon would drift from the Mac one within a week.

## Phases

| Phase | What | Gate |
|---|---|---|
| 0 | **Linux build spike.** Install the toolchain and SDK; get `agentsd` to build static for both architectures; run it on a real server; talk to it through a hand-made `ssh -L` forward with `socat`. | Alex runs one command on a server and a turn completes. If this fails, the plan stops here. |
| 1 | SSH layer + installer + `ServerLink`, fake-ssh tests. `--serve`, `daemon/version`. | `swift test` green; the fake-ssh host installs, starts, forwards, answers `agents/list`. |
| 2 | `HostSet`, host tags, grouped list, Add a server sheet, New project submenus, remote folder sheet. | **Look gate**: walked on a scratch root against the fake-ssh host. |
| 3 | Offline states, reconnect and catch-up, `requestID`. | Pull the forward mid-turn; the strip shows; Send is disabled; the catch-up matches. |
| 4 | Server files pane, attachments, hidden Mac-only actions, costs by host. | Files, terminal and a live page work on the fake host. |
| 5 | Settings ▸ Servers, remove, update-when-idle, newer-server refusal. | Version swap with a mid-turn agent waits, then swaps. |
| 6 | Real server walk (Alex's): SC-001…SC-007. | Alex. |

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| A second build toolchain (swift.org + Static Linux SDK) | The daemon must run on Linux | Building on the server needs Swift there. A Linux container needs a runtime this Mac does not have. A port to another language is a second daemon. |
| `AppModel` goes from one client to many | A project lives on one host (Alex) | Federating through the Mac daemon means every one of ~90 methods is proxied, and the Mac daemon becomes a single point of failure for server work. Noted in R7 as the way to give the phone servers later. |
| `requestID` on three methods | FR-020 exactly-once over a link that drops | Not retrying loses sends. Retrying without it sends twice. |
