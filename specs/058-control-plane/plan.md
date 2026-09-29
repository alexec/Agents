# Implementation Plan: A Control Plane, and Apps That Are Only Clients

**Branch**: `agents/control-plane` | **Date**: 2026-09-28 (re-plan; first plan 2026-09-26) |
**Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/058-control-plane/spec.md`, re-specified 2026-09-28.

## Summary

The control plane becomes a service of its own, `agents-control`, in a new package. It runs as
a single copy inside a new host app on a Mac, or as several copies in a container behind a load
balancer. The copies share a folder or an S3-compatible bucket.
- **Store** ([research.md](research.md) R4): one object per record, with conditional writes.
- **Copies** (R5): a lease names the copy holding each host's uplink, and copies proxy each
  other's channels over peer links.
- **The wire** (R6, R7): everyone speaks WebSockets over HTTPS, and proves their keys with an
  HMAC under the keys they already hold. Inside the socket, the first build's line wire is
  unchanged.

**Agents Host.app** (R9), signed with Developer ID and outside the App Store, carries:
- `agentsd`;
- `agents-control`;
- `agents-relay`, which is today's bridge cut down to the iCloud relay and mailbox (R10);
- the Linux programs used to install servers.

It registers its launch agents and runs the move across (R11).

**The Mac window** (R12) becomes a sandboxed App Store app. It links only `AgentsKitCore` and
`Shared`, and reaches everything, this Mac included, through the control plane. The first
build's router, grants, codes, methods, host-side channels, `ThisMacHost` and Settings pages
carry over (R2).

## Technical Context

**Language/Version**: Swift 6.2, strict concurrency (as today).

**Primary Dependencies**:
- *`agents-control`:* swift-nio (`NIOHTTP1`, `NIOWebSocket`, `NIOPosix`), swift-nio-ssl, and
  async-http-client (for S3).
- *Hosts:* the same NIO dialer (R7).
- *Apps:* `URLSessionWebSocketTask`, CryptoKit and Network.framework (Bonjour browse only).
- *Host app:* ServiceManagement and CloudKit (relay).
- *Cryptography:* `ControlAgreement` (pure Swift) wherever CryptoKit is absent.

**Storage**:
- *`ControlStore`* (R4): a folder (single machine) or an S3-compatible bucket, one JSON object
  per record, with conditional writes.
- *Host roots:* unchanged.
- *Control plane key:* the host app's keychain (`relay-mac-key`), or a mounted secret or
  environment variable in a container.

**Testing**:
- `swift test` in `Packages/AgentsKit` and in the new `Packages/ControlPlane`.
- An in-memory store and in-memory WebSocket pairs for the router, lease and peer tests.
- MinIO (in Colima, beside the devbox) for the S3 store.
- A local load balancer (a Caddy container) in front of three copies for the US3 walk.
- The run-app and test-servers skills for the scratch walks.

**Target Platform**:
- macOS 27: the sandboxed window, the host app, and `agents-control` in the host app.
- iOS 27: the Remote.
- Linux arm64 and x86-64, musl static: hosts, and `agents-control` in a container.

**Project Type**: two App Store apps (Mac, iOS), a Developer ID host app with helpers, a Linux
service and host, in the Xcode project plus SwiftPM.

**Performance Goals**:
- **SC-003:** failover within 10 seconds.
- **SC-004:** through one copy, terminal echo at most 10 ms (median) slower than today, and a
  question at most 50 ms slower.
- **SC-005:** a server shows everywhere within 5 seconds.
- **FR-009:** revocations reach every copy within 2 seconds.

**Constraints**:
- self-hosted only;
- no database;
- the control plane's key is never in the store;
- the App Store window starts no process and links no `AgentsKit`;
- the move is one deliberate step, and the old set-up works until then.

**Scale/Scope**: one person (owner-keyed for a team later): about 5 clients, up to 20 hosts,
2–3 copies.

## Constitution Check

The constitution file is the unfilled template, so there are no ratified gates. The project's
working rules (AGENTS.md, memory) stand in:

- **Settle the UX before building depth.** Phase 1 is a look gate for the new or changed
  screens: first run with the host app, the host app's window, and Add a Server showing a
  command. **Pass** (gate held in the tasks).
- **Walk what you ship.** Every phase is walked on a scratch root (run-app, test-servers)
  before the next one starts. **Pass**.
- **The main checkout is only main.** The work stays in `.agents/worktrees/control-plane`.
  **Pass**.
- **Security review before merge.** A network-reachable operator role, a shared control key
  across copies, and a public bucket layout all need it. **Pass** (Phase 9).
- **The move touches Alex's live set-up.** It happens only with his go-ahead. **Pass**.
- **Never touch the real home or devices in walks.** Walks use scratch roots, a scratch
  keychain service, a scratch bucket, the fake device, and the Remote built for the generic
  simulator. **Pass**.

Re-checked after design: no change. The Complexity Tracking table below records the new
moving parts.

## Project Structure

### Documentation (this feature)

```text
specs/058-control-plane/
├── spec.md              # re-specified 2026-09-28
├── research.md          # R1–R14, spikes S2–S5
├── plan.md              # this file
├── data-model.md        # records in the store, leases, copies, sessions
├── quickstart.md        # the scratch walks
├── contracts/
│   ├── wire.md          # WebSocket, the key exchange, client/host/peer lines
│   ├── control-api.md   # methods the control plane answers itself
│   └── store.md         # key layout and conditional-write rules
├── look/                # first look gate (A–J); new frames K–N for this re-plan
├── walks/               # records of the first build's walks (kept)
└── tasks.md             # redone by speckit-tasks after this plan
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Control/                 # KEPT: ControlRouter (+ proxied host sessions), ControlWire,
│                            #   Grant, ControlMethods (store-backed), ControlCode (URL + pin),
│                            #   ControlLink, ControlNotices
├── Control/ControlAuth.swift        # NEW: the R6 exchange, both sides, on ControlAgreement
└── Remote/ControlAgreement.swift    # KEPT

Packages/AgentsKit/Sources/AgentsKit/
├── Daemon/ControlUplink.swift       # KEPT, over the NIO WebSocket dialer
├── Daemon/HostDial.swift            # NEW (from LinuxControlDial): NIOWebSocket + NIOSSL, macOS + Linux
├── Daemon/MacHostMethods.swift      # NEW: mac/reveal, mac/open, mac/terminal, lock state
├── Daemon/SharedMethods.swift       # NEW: shared/* (skills and instructions under ~/.agents)
└── Control/                         # ControlNet, UnixSocketListener (for control), SSHUplink:
                                     #   REMOVED after their replacements are walked

Packages/ControlPlane/               # NEW package: agents-control
├── Package.swift                    # macOS + Linux; NIO, NIOSSL, async-http-client
├── Sources/ControlPlaneKit/
│   ├── Store/ControlStore.swift     # protocol + FolderStore + S3Store (SigV4)
│   ├── Server/HTTPServer.swift      # /v1/connect (upgrade), /healthz, /readyz
│   ├── Server/Session.swift         # a WebSocket after ControlAuth → router session
│   ├── Copies/Leases.swift          # host leases, renewal, takeover
│   ├── Copies/PeerLinks.swift       # copy ⇄ copy links, proxied uplinks, events
│   ├── Hosts/HostInstall.swift      # hosts/install over ssh, key dropped afterwards (from SSHHosts)
│   └── ControlService.swift         # wires store + router + server + copies
├── Sources/agents-control/main.swift
└── Tests/ControlPlaneKitTests/      # store conformance (folder, memory, MinIO), leases, peers, auth

Host/                                # NEW: Agents Host.app (Developer ID)
├── Sources/                         # window, LocalServices (moved), ControlMove (moved), key handoff
└── Relay/                           # agents-relay: RelayHost + MailboxTransport (from Bridge/)

App/                                 # the window; AGENTS_STORE build setting → sandbox, Core-only link
├── Agents.entitlements              # + app-sandbox, network.client, user-selected read-only
└── Sources/                         # HostSet, SocketLink use, LocalServices, SignInRelays,
                                     #   ServerBinaries leave; isOnThisMac reads → files/*, shared/*, mac/*
Remote/Sources/                      # ControlLink over URLSession WebSocket; relay via a Mac host
Daemon/Sources/main.swift            # --control <url|code>, the NIO dialer
Bridge/                              # retired after the move is walked (DirectLink, control in bridge)
deploy/                              # NEW: Containerfile for agents-control, a sample compose file
                                     #   (3 copies + Caddy + MinIO) used by the US3 walk
project.yml                          # + Agents Host target, agents-relay; Agents store config
```

**Structure Decision**:
- *What stays shared.* Router, wire, records and auth stay in `AgentsKitCore`, so the window,
  the Remote, hosts and the service share one copy.
- *The service gets its own package,* so no App Store target can link a server, and it builds
  on Linux without the Xcode project.
- *The host app is the only Mac target* that may spawn, register launch agents or use CloudKit
  for the relay.

## Phases

Each phase ends with a scratch walk recorded in `walks/`. A phase that touches hosts is also
walked against the devbox.

0. **Spikes** (research S2–S5): the sandboxed WebSocket and Bonjour; the Linux NIO dialer and
   its size; conditional writes on MinIO and S3; a sandboxed archive's failure list. Stop and
   tell Alex if S2 or S4 fails.
1. **Look gate**: new frames K–N in `look/`. Alex approves them before any UI code.
   - K: first run, with the host app absent or present.
   - L: the host app's window.
   - M: Add a Server, showing a command or ssh.
   - N: a relayed device in Clients.
2. **`agents-control` as a service, single copy**:
   - the new package, `ControlStore` (memory and folder), and `ControlAuth`;
   - the WebSocket server, and the router moved in;
   - `ControlMethods` backed by the store;
   - codes as URL plus pin.

   Hosts and the window dial it over WebSockets, with the NIO dialer and `URLSession`. This
   replaces `ControlNet` and the control plane in the bridge. The US1 walk is redone through it.
3. **Many copies**: `S3Store`, leases, peer links, proxied uplinks, events, copy registry,
   codes across copies. Walk US3 with three copies, Caddy and MinIO, killing copies mid-turn.
4. **Hosts join**:
   - the join command and Linux tarball, and the container image;
   - `hosts/install` over ssh with the key dropped afterwards;
   - `SSHUplink` removed.

   Walk US4 on the devbox.
5. **Agents Host.app**:
   - the target, the embedded helpers, and `LocalServices` moved in;
   - the key handed over through a file descriptor;
   - `agents-relay` cut from the bridge;
   - `mac/*` and `shared/*` on the Mac host;
   - the move (`ControlMove`) run from here.

   Walk US2 and US7 on a scratch root seeded the old way, then US9 as a second host.
6. **The sandboxed window**:
   - the `AGENTS_STORE` configuration;
   - the link reduced to Core;
   - every `isOnThisMac` read moved to `files/*`, `shared/*` or `mac/*`;
   - sign-in lending host to host;
   - Bonjour discovery, and first run (frame K).

   Walk US1 and US6 with the sandbox on, checking that no process is started (SC-001, SC-002).
7. **The Remote**:
   - the `URLSession` WebSocket and pin;
   - the relay through `agents-relay`;
   - notices through the relay host;
   - production push settings.

   Walk US5 with the fake device, both directly and relayed. The phone look is Alex's.
8. **App Store**: archives and validation for all three apps (US8), the demo control plane
   container, and review notes.
9. **Close**:
   - docs (the spec's Docs section);
   - security review;
   - the R14 measurements;
   - six-run suite comparison against main;
   - Alex's own move, with his go-ahead;
   - then, in a separate change, removal of the old window path, the bridge's `DirectLink` and
     the `AGENTS_STORE` switch.

Main has moved 99 commits since this branch last merged it. Merge main at the start of
Phase 2 and again before Phase 9.

## Complexity Tracking

| Choice | Why needed | Simpler alternative rejected because |
|---|---|---|
| Peer links and proxied uplinks between copies | FR-006: any copy serves any client for every host | A broker (Redis/NATS) is a service the spec rules out. Sticky routing cannot serve a client that needs every host |
| Leases in the store | One holder per host uplink, with takeover when a copy dies | Without them, two copies could both believe they hold a host |
| A third Mac target (host app) plus a relay helper | App Store rules, and CloudKit needs a signed bundle | A bare pkg cannot register `SMAppService` jobs or carry CloudKit |
| Two store backends, both offered at home | Alex asked for disk or S3, and for home users to choose either (FR-024a) | Only S3 would make every home user need a bucket. Only disk cannot share state across machines, or outlive the Mac |
| HMAC proof of keys instead of signatures | It proves the same keys, with no second BoringSSL on Linux (R6) | ECDSA would add swift-crypto or hand-written signing |
| Two window configurations until the move | FR-039: the old set-up works until the person moves | One configuration would force the move on the first launch |
