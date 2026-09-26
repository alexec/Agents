# Implementation Plan: A Control Plane, and the Mac Window as One More Remote

**Branch**: `agents/control-plane` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/058-control-plane/spec.md`

## Summary

Grow `agents-bridge` into `agents-control`: one self-run process that every host (`agentsd`)
dials into and every client (the Mac window, the iPhone, the iPad) pairs with, under a grant
(`operator` or `device`). It routes by **channel**, not by method ([research.md](research.md)
R3): for each (client, host) pair it opens a channel over the host's uplink, and the host turns
each channel into a virtual connection with today's per-connection behaviour (credential
lending, surface, presence, broadcast filtering). The window stops spawning `agentsd` and stops
holding ssh connections; it keeps one `DaemonClient` per host, now carried over one
`ControlLink`. On a Mac, **Run one on this Mac** registers two launch agents from the app
bundle. Linux servers join first through the control plane's ssh forward (today's mechanism,
moved), and dial out once spike S1 proves TLS-PSK on Linux (R8).

## Technical Context

**Language/Version**: Swift 6.2, strict concurrency (as today)

**Primary Dependencies**: Network.framework (TLS-PSK, Bonjour), CryptoKit (ECDH, HKDF, HPKE),
CloudKit (relay, notices), ServiceManagement (`SMAppService`) on macOS. Linux: none new until
spike S1, which trials `swift-crypto` + `swift-nio-ssl` in a Linux-only target.

**Storage**: JSON files under the control root (`~/Library/Application Support/Agents Control`,
or `--root`): `clients.json`, `hosts.json`, `control.json` (addresses, home host). Keys in the
keychain on a Mac (existing `relay-mac-key`), `0600` files on Linux. The host's root is today's
root, unchanged.

**Testing**: `swift test` in `Packages/AgentsKit` (XCTest). `PairedTransport.pair()` gives
in-memory line transports for router tests. Scratch walks with the run-app and test-servers
skills.

**Target Platform**: macOS 27 (window, control plane, host); iOS 27 (Remote); Linux arm64/x86-64
musl (host; control plane after S1).

**Project Type**: desktop app + daemons + mobile client, in one Xcode project plus SwiftPM.

**Performance Goals**: SC-004: terminal echo ≤ +10 ms median at home over today; a question
reaches the window ≤ +50 ms.

**Constraints**: nothing through a service we run; the move is one deliberate step; the window
must keep working the old way until the move (R7 "Transition").

**Scale/Scope**: one person; ≤ 5 clients, ≤ 6 hosts, so ≤ 30 channels.

## Constitution Check

The constitution file is the unfilled template, so there are no ratified gates. The project's
working rules (AGENTS.md, memory) stand in:

- *Settle the UX before building depth*: Phase 1 ends at a look gate (wireframes for
  Settings ▸ Control plane and first run). **Pass** (gate held).
- *Walk what you ship*: every phase is walked with run-app on a scratch root before the next.
  **Pass** (in tasks).
- *Main checkout is only main*: work in `.agents/worktrees/control-plane`. **Pass**.
- *Security review before merge* for network-reachable operator role. **Pass** (task in Polish).
- *The move touches Alex's live set-up*: only with his go-ahead. **Pass** (task marked).

Re-checked after design: no change.

## Project Structure

### Documentation (this feature)

```text
specs/058-control-plane/
├── spec.md
├── research.md          # R1–R11
├── plan.md              # this file
├── data-model.md
├── quickstart.md        # the scratch walk
├── contracts/
│   ├── wire.md          # client⇄control and control⇄host framing
│   └── control-api.md   # methods the control plane answers itself
├── look/                # wireframes (look gate)
└── tasks.md
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Control/                         # NEW, portable (no Network/CryptoKit imports)
│   ├── ControlWire.swift            # the {h,m} / {c,m,open,close} framing
│   ├── ControlRouter.swift          # actor: client sessions, host sessions, channels
│   ├── Grant.swift                  # Grant, ClientRecord, HostRecord
│   ├── GrantStore.swift             # clients.json / hosts.json
│   └── ControlLink.swift            # client side: one physical link → a HostLink per HostID
├── Daemon/ConnectionRole.swift      # + .controlPlane (may only open channels)
└── Remote/…                         # reused: NetworkLink, LinkTLS, DeviceKey, Relay/

Packages/AgentsKit/Sources/AgentsKit/
├── Daemon/DaemonServer.swift        # + virtual connections from an uplink's channels
├── Daemon/ControlUplink.swift       # NEW: dial out, reconnect with backoff, demux channels
├── Daemon/DaemonCore+Attention.swift# needs go to the uplink unsealed when under control
└── Hosts/…                          # SSHMaster, ServerInstaller, ToolsetInstaller: used by
                                     #   agents-control now, not the window

Control/ (was Bridge/)
├── Sources/main.swift               # agents-control: listener, Bonjour, router, relay
├── Sources/DirectLink.swift         # + host PSKs (h:, e:)
├── Sources/RelayHost.swift          # attaches relay sessions to the router
├── Sources/MailboxTransport.swift   # seals needs to devices, posts to CloudKit
├── Sources/HostInstall.swift        # hosts/install over ssh (moved from HostSet)
├── Sources/SSHHost.swift            # ssh-reached host session (FR-012, R8)
└── Sources/Migrate.swift            # agents-control migrate --from <root>

Daemon/Sources/main.swift            # + --control <code|home>
App/Sources/
├── AppModel.swift                   # clients from ControlLink when ControlConfig exists
├── Control/                         # NEW: FirstRunView, ControlSettingsView, LocalServices
├── Hosts/                           # HostSet retired after the move; AddServerFlow → hosts/install
└── Sidebar/, AgentList/, Projects/  # "this Mac's host" gates (R11)
App/LaunchAgents/                    # the two plists, copied to Contents/Library/LaunchAgents
Remote/Sources/RemoteModel.swift     # hosts from control/hostChanged; every host's projects
project.yml                          # agents-bridge → agents-control, embedded in Helpers
```

**Structure Decision**: the router and wire live in AgentsKitCore so the window (macOS), the
Remote (iOS), the control plane and the tests share them, and so they stay portable for a Linux
control plane. Everything that needs Network.framework, CryptoKit or CloudKit stays in the
`Control/` executable or behind the existing gates.

## Phases

Each phase is walked with run-app on a scratch root before the next; a phase that touches hosts
is also walked against the devbox with test-servers.

1. **Spec, research, look gate** (this plan). Wireframes in `look/`; Alex approves before code.
2. **Router core** (AgentsKitCore, no UI): wire, `ControlRouter`, grants, `ControlLink`; unit
   tests over `PairedTransport`.
3. **agents-control**: rename the bridge target; router in place of the line pipe; clients
   keyed by `clients.json`; host listener and enrolment; control API. A legacy client (no `h`)
   reaches the home host, so today's Remote keeps working.
4. **Hosts join**: `agentsd --control`, `ControlUplink`, virtual connections, `.controlPlane`;
   ssh-reached hosts in the control plane (`SSHHost`, `hosts/install`); spike S1 for Linux.
5. **Window as a client**: `ControlLink` in `AppModel` behind `ControlConfig`; `AddServerFlow`
   → `hosts/install`; credentials lent over channels; R11's gates.
6. **Run one on this Mac**: launch agents, first run, loopback pairing; `migrate`.
7. **Remote catches up**: every host's projects; host headers.
8. **Docs, security review, measurements** (SC-004), six-run suite comparison.

## Complexity Tracking

| Choice | Why needed | Simpler alternative rejected because |
|---|---|---|
| A new process between every client and host | FR-002, every screen sees every host | Joining in the window (037 R7) cannot reach the phone; joining in `agentsd` makes one host special (R1) |
| Two paths in `AppModel` until the move | FR-025, the move is deliberate | One path would force the move on the first launch of the new build |
| ssh-reached hosts kept, in the control plane | Linux has no TLS-PSK yet (R8); some hosts can't dial out (FR-012) | Dropping them loses servers until S1 lands |
