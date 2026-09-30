---
description: "Tasks for 058, re-planned 2026-09-28: apps that are only clients, and a control plane that runs as copies"
---

# Tasks: A Control Plane, and Apps That Are Only Clients

**Input**: the design documents in `specs/058-control-plane/`. They were re-specified and
re-planned on 2026-09-28: spec.md, plan.md, research.md (R1–R14, S2–S5), data-model.md,
`contracts/` (wire, store, control-api) and quickstart.md.

**Tests**: the plan asks for them where the design is new: the store, the key exchange, leases,
peer links and grants across copies. Walks follow quickstart.md, and each is recorded in
`walks/`. Scratch roots only, never Alex's devices or real home (plan, Constitution Check).

**The first build**: tasks done under the first plan (at `117f858f`) whose code research R2 keeps
are listed as done in the section below, with their old numbers. Its other done tasks are
replaced, and removing what they left is a task in this list.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1–US9, as in spec.md

## Carried over from the first build (done; research R2 "Keep")

- [x] T001 The wire, in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlWire.swift`. Unchanged inside the WebSocket (was T004).
- [x] T002 Records and grants in `Packages/AgentsKit/Sources/AgentsKitCore/Control/Grant.swift`. `owner`, `rev` and the new code text are added in T030 (was T005).
- [x] T003 The `ControlRouter` actor in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlRouter.swift`: channels per client and host, grant check, generations. Proxied host sessions are added in T061 (was T007).
- [x] T004 `ControlMethods` in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlMethods.swift`. It is made store-backed in T032 (was T008).
- [x] T005 `ControlLink` and `HostLink` in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlLink.swift`. They get a WebSocket transport in T040 (was T009).
- [x] T006 Router and grant tests in `Packages/AgentsKit/Tests/AgentsKitTests/Control/ControlRouterTests.swift` and `ControlGrantTests.swift` (was T010, T011).
- [x] T007 Virtual connections on the host, `acceptVirtual`, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonServer.swift` (was T014).
- [x] T008 `ControlUplink` (backoff, redial on a network change, channel demux) and its tests, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/ControlUplink.swift`. It gets a WebSocket dialer in T038 (was T015, T016).
- [x] T009 `ThisMacHost` in `App/Sources/Control/ThisMacHost.swift` (was T025).
- [x] T010 Credential lending on a host's channel, operator only (was T027).
- [x] T011 The away strip, `App/Sources/Sidebar/ControlAwayStrip.swift` (frame H) (was T028).
- [x] T012 Settings ▸ Control plane: Overview, Hosts, Clients and the pair sheet (frames D–G), in `App/Sources/Control/ControlSettingsView.swift` and its panes. Grant changes reopen channels (was T046–T051).
- [x] T013 `hosts/install` over ssh with trust asked back, in `Packages/AgentsKit/Sources/AgentsKit/Control/SSHHosts.swift`, and `hosts/remove`. They move into the service in T072 (was T039, T041).
- [x] T014 Add a Server in Settings, pointed at `hosts/install` (was T042).
- [x] T015 Host headings in the Remote's project list, `Shared/UI/HostListHeading.swift` (was T054).
- [x] T016 A host sends `attention/need` unsealed on channel 0, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Attention.swift`. The host side is kept, and the sealing moves in T097 (was T056).
- [x] T017 `ControlMove` and its tests, in `Packages/AgentsKit/Sources/AgentsKit/Control/ControlMove.swift`. It writes the store in T084 and is run by the host app in T086 (was T058, T060).
- [x] T018 `ControlAgreement`, pure-Swift P-256, HKDF and HMAC matching CryptoKit, in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/ControlAgreement.swift`, with `ControlAgreementTests` (was part of T044).
- [x] T019 Spike S1: BoringSSL speaks the listener's suite from a musl binary, and the libraries add 51.5 MB (was T043).
- [x] T020 `ConnectSheet` with Bonjour browsing, and `FirstRunView` (frame A), in `App/Sources/Control/`. Both are reworked by frame K in T051 (was T034, T036).

---

## Phase 1: Setup and spikes (plan Phase 0)

**Purpose**: prove the risky parts before any code rests on them. Record each result in
`research.md` under its spike. If S2 or S4 fails, stop and ask Alex.

- [x] T021 (53fc1e5e; both schemes build, 64 control tests pass) Merge `main` into `agents/control-plane`. It is 99 or more commits ahead. Check with `git merge-base` afterwards that the merge landed on this branch (memory: a branch can move under a merge). Build both schemes one after the other with plugin validation skipped, and pass `swift build` in `Packages/AgentsKit`.
- [x] T022 (passed: spikes/s2-sandbox-ws/RESULTS.md; the Local Network prompt is left for T053) [P] Spike S2, the sandboxed window's WebSocket, in `specs/058-control-plane/spikes/s2-sandbox-ws/`. Make a throwaway macOS app target with only `com.apple.security.app-sandbox` and `com.apple.security.network.client`, and `NSBonjourServices` = `_agents-control._tcp`. Using `URLSessionWebSocketTask` with a delegate that checks a SHA-256 SPKI pin, it must:
  - dial `wss://127.0.0.1:<port>` and `wss://<this Mac>.local:<port>`, served by a throwaway NIO WebSocket server with a self-signed certificate;
  - exchange a line each way;
  - browse Bonjour with `NWBrowser`.

  Record pass or fail for each in research.md S2.
- [x] T023 (passed: +5.9 MB for NIOSSL and WebSocket; the pinned path needs an empty trust store; spikes/s3-linux-ws/RESULTS.md) [P] Spike S3, the host dialer on Linux, in `specs/058-control-plane/spikes/s3-linux-ws/`. Build a static musl aarch64 program with `NIOWebSocket` and NIOSSL that dials `wss://` in two ways:
  - through Caddy terminating TLS, with a publicly trusted-style local CA;
  - to a self-signed server by pin.

  Run it in the devbox container against servers on this Mac. Measure the stripped size against the 5.8 MB baseline from S1, and record it in research.md S3.
- [x] T024 (passed on MinIO; five store rules added, conditional delete dropped for tombstones; no real S3 bucket was used; spikes/s4-conditional/RESULTS.md) [P] Spike S4, conditional writes, in `specs/058-control-plane/spikes/s4-conditional/`. Run MinIO in Colima beside `agents-devbox`. Against MinIO, and against one real S3 bucket if Alex provides one (ask; otherwise MinIO and R2's documented behaviour only), test:
  - `PUT` with `If-None-Match: *` twice (the second gets 412);
  - `PUT` with `If-Match: <etag>` (a stale ETag gets 412);
  - two writers racing one lease key 100 times (exactly one wins each round).

  Record the results in research.md S4.
- [x] T025 (48 files fail; eight types move to Core; disk and NSWorkspace calls need a grep gate; spikes/s5-sandbox-build/RESULTS.md) [P] Spike S5, a sandboxed archive. On a throwaway branch in a scratch worktree (never this tree), turn on `com.apple.security.app-sandbox` in `App/Agents.entitlements` and link only `AgentsKitCore` for the Agents target in `project.yml`. Run `xcodegen`, then build. List every file that fails and why. Record the list in research.md S5; it sizes US1's tasks T044–T053. Delete the scratch worktree afterwards.
- [x] T026 (builds on macOS and for aarch64 musl) Create the package skeleton `Packages/ControlPlane/Package.swift`:
  - platforms macOS 27, and Linux via the static SDK;
  - targets `ControlPlaneKit`, `agents-control` and `ControlPlaneKitTests`;
  - dependencies: `AgentsKitCore` (path `../AgentsKit`), swift-nio (`NIOCore`, `NIOPosix`, `NIOHTTP1`, `NIOWebSocket`), swift-nio-ssl and async-http-client.

  Check `swift build` on macOS and a Linux build with `scripts/build-linux-agentsd.sh`'s SDK.

---

## Phase 2: Look gate (plan Phase 1)

**Purpose**: settle the new and changed screens before any UI code. Alex approves them.

- [x] T027 (K, K2, L, M, M2, N; look/README.md) [P] Draw frames K–N in `specs/058-control-plane/look/wireframes.html`, the same style as A–J, and export `k.png`–`n.png`. The frames:
  - **K**: the window's first run, in two states: the host app is absent, which gives *Connect to a control plane* and *Set one up on this Mac*, pointing to the download; and the host app is found by Bonjour, which gives *Pair with “Alex's Mac”*.
  - **L**: the host app's window: this host's state, the code to pair a window or phone, *Run the control plane here*, *Join one elsewhere*, *Relay for my devices*, and the move. Also where the control plane keeps its store: *This Mac* (the default) or *A bucket* (endpoint, bucket, prefix, access key, secret, and a Check button), plus *Switch store…* once it is running.
  - **M**: Add a Server, with two tabs: *Run a command*, showing a host code and the one-line command; and *Install over ssh*, with the destination and a key used once.
  - **N**: Clients, with a relayed device and its away marker, and the "reached through <Mac>" line.
- [x] T028 (approved by Alex 2026-09-28: all of K–N, and the name Agents Host) Update `specs/058-control-plane/look/README.md` with what each of K–N shows and why. Ask Alex to approve with AskUserQuestion. Record his decisions in the README and stop UI work until he answers.

---

## Phase 3: Foundational (plan Phase 2; blocks every story)

**Purpose**: `agents-control` as a single-copy service over the store, the key exchange and
WebSockets, with hosts and clients able to dial it. There is no UI change here beyond the
transport.

- [x] T029 (in AgentsKitCore, beside the protocol, so the old bridge path can use it too) [P] Write `ControlStore` in `Packages/ControlPlane/Sources/ControlPlaneKit/Store/ControlStore.swift`, as contracts/store.md gives it: `get`, `put(when: .absent | .matching(etag) | .always)`, `delete` and `list(prefix:)`. Also write the errors `StoreError.conflict` and `.unavailable`, and a `MemoryStore` for tests.
- [x] T030 (`HostLease`, since `Lease` was taken; `reach` stays until T073; the code keeps the control key) [P] In `Packages/AgentsKit/Sources/AgentsKitCore/Control/Grant.swift` and `ControlCode.swift`:
  - Add `owner: PersonID` and `rev: Int` to `ClientRecord` and `HostRecord`. Add `relay: Bool`, `machineID` and `installedBy: command | ssh(destination)` to `HostRecord`, and remove `reach`.
  - Add `PersonID`, `Lease`, `CopyRecord` and `ControlEvent` as in data-model.md.
  - Change the code text to `agents-control:2:<c|h>:<grant|->:<url>:<pin|->:<secret>:<name>`, keeping a reader for version 1.
- [x] T031 [P] In `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`:
  - move the control plane's failures to -32090…-32094, since main took -32070 (`signInWanted`) and -32080 (`catalogRefused`): `hostOffline`, `noSuchHost`, `lastOperator`, and the new `changedElsewhere` and `storeUnavailable` (contracts/control-api.md);
  - update every use and test.
- [x] T032 (through `ControlRecords`, a records layer in AgentsKitCore that the bridge's control plane and the move use too) Make `ControlMethods` read and write through `ControlStore` instead of `GrantStore`, in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlMethods.swift`:
  - a record cache with ETags;
  - store first, then change;
  - `lastSeen` written at most hourly;
  - `lastOperator` checked with `.matching`;
  - a conflict answered with `changedElsewhere`.

  The store protocol moves to AgentsKitCore if `ControlMethods` needs it; otherwise it takes an injected store. Delete `GrantStore.swift` and its tests.
- [x] T033 (in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlStore.swift`, so both the bridge and the service use it) [P] Write `FolderStore`:
  - the ETag is SHA-256 of the contents;
  - `put` takes `flock` on `<key>.lock`, compares, writes a temporary file, `fsync`s it and renames it into place;
  - `list` walks the prefix.
- [x] T034 (StoreConformanceTests on memory, folder and MinIO with AGENTS_TEST_S3) [P] Store conformance tests in `Packages/ControlPlane/Tests/ControlPlaneKitTests/StoreConformanceTests.swift`. Run them against `MemoryStore` and `FolderStore`, and against `S3Store` when `AGENTS_TEST_S3` is set:
  - create-only conflicts;
  - a stale `matching` conflicts;
  - `list` sees new keys;
  - a spent code is written once when 20 tasks race;
  - 412, 409 and 404 on a conditional put all surface as `conflict`, and a stale write after A→B→A is refused because `rev` changed (store.md rules 8–10);
  - forgetting writes a tombstone that reads as absent (rule 11);
  - the start-up probe fails on a store that ignores conditions (a test double).
- [x] T035 (a code's secret is its id and a tag any copy can remake, so no copy needs another's secret) [P] Write `ControlAuth` in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlAuth.swift`. It covers both sides of the three messages in contracts/wire.md (hello, auth, ok or refused):
  - the transcript `"agents-auth-v1" | sn | pn | id | origin`;
  - the MACs tagged `c` and `s`;
  - K for `c:`, `h:`, `p:`, `e:` and `x:` using `ControlAgreement`;
  - `origin` normalised to lowercase scheme, host and port.
- [x] T036 (11 tests) [P] Key exchange tests in `Packages/AgentsKit/Tests/AgentsKitTests/Control/ControlAuthTests.swift`:
  - each identity kind round-trips;
  - a wrong key, a replay to another origin, a flipped nonce, an expired code and a spent code are each refused with the contracts' reason;
  - the server's MAC is checked by the client;
  - a device key made by today's `DeviceKey` proves itself as `c:` under the Mac's relay key (FR-038).
- [x] T037 (the pipeline is `ControlWebSocketServer` in the kit's `ControlDial` target, shared with the dialler; the self-signed certificate is made in two openssl steps, since BoringSSL refuses LibreSSL's one-step key) Write the HTTP and WebSocket server in `Packages/ControlPlane/Sources/ControlPlaneKit/Server/HTTPServer.swift`:
  - `GET /v1/connect` upgrades;
  - `GET /healthz` gives 200;
  - `GET /readyz` gives 200 after a store read and 503 otherwise;
  - optional NIOSSL termination from `AGENTS_CONTROL_TLS_CERT` and `_KEY`, or `--self-signed <dir>`, which makes the certificate and prints the pin;
  - pings every 20 s, closing after two missed;
  - a 64 MB message cap.
- [x] T038 (as the `ControlDial` target, with `ControlJoin`; `LinuxControlDial` goes with the removals in T042) [P] Rework `Packages/AgentsKit/Sources/LinuxControlDial/LinuxControlDial.swift` into `HostDial`, a `NIOWebSocket` client over NIOSSL. It checks either a publicly trusted certificate or a pin, runs `ControlAuth` as the peer, and returns a `LineTransport`. It is linked into `AgentsKit` on macOS and Linux both (drop the Linux-only condition in `Packages/AgentsKit/Package.swift`), and `ControlUplink` uses it.
- [x] T039 (in `ControlService.accept`; codes are `ControlCodes`, spent by `.absent`) Write `Session` in `Packages/ControlPlane/Sources/ControlPlaneKit/Server/Session.swift`. After `ControlAuth`, a WebSocket becomes a router client session, a host uplink, or a code session:
  - a code session may send only `clients/announce` or `hosts/announce`;
  - it creates `codes/<hash>.spent` with `.absent` before admitting;
  - it closes after the reply.

  Every text message is one wire line.
- [x] T040 (pin from the P-256 header and point, as in S2; tested against the service in `ControlServiceTests`; the Remote builds) [P] Write the apps' transport in `Packages/AgentsKit/Sources/AgentsKitCore/Control/WebSocketLink.swift`: `URLSessionWebSocketTask` with a pin-checking delegate, `ControlAuth` as the peer, and one message per line. It is gated on `canImport(Foundation) && !os(Linux)`. `ControlLink` takes it in place of the TLS-PSK dial.
- [x] T041 (s3:// waits on T062; smoke-run on /tmp/cpsmoke: serve, pin, /healthz, /readyz, codes, SIGTERM) Write `ControlService` and the `agents-control` CLI in `Packages/ControlPlane/Sources/ControlPlaneKit/ControlService.swift` and `Sources/agents-control/main.swift`:
  - `serve`: store from `AGENTS_STORE`; key from `AGENTS_CONTROL_KEY_FILE`, `AGENTS_CONTROL_KEY` or an inherited descriptor, `--key-fd`; URL from `AGENTS_CONTROL_URL`;
  - `code --client operator|device` and `code --host`;
  - `hosts` and `clients` (list);
  - `--store` for `code`, `hosts` and `clients`.

  On first start it writes `control.json` and `people/<id>.json` with `.absent`. It refuses to start if the key does not match `control.json`'s `controlKey`.
- [ ] T042 (the join is done: a version 2 code or membership goes over `ControlJoin` on a Mac and on Linux, walked with the real agentsd and agents-control on /tmp/cpjoin, across a restart; the removals wait until the window has moved, T049c/T050) Point `agentsd --control <url|code>` at `HostDial`. The membership stores `url` and `pin` instead of addresses, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/Daemon.swift` and `LinuxControlJoin.swift`. Then:
  - remove `ControlNet`, `ControlDialling`, `UnixSocketListener`'s control use and `ControlPlane.swift`'s bridge wiring, once `ControlServiceTests` (T043) passes;
  - keep `daemon.sock` for agent tools (FR-021);
  - check that `ControlNetTests` is replaced by T043.
- [x] T043 (`ControlServiceTests`, 10; walks/foundational.md) End-to-end tests in `Packages/ControlPlane/Tests/ControlPlaneKitTests/ControlServiceTests.swift`. Using a `FolderStore` in a temporary folder, a self-signed copy on a loopback port, a host dialled with `HostDial`, and a client over `WebSocketLink`, check:
  - enrolment by code;
  - `agents/list` routed to the host;
  - an operator-only call refused for a device;
  - a code used twice is refused;
  - a forgotten client is cut off;
  - the copy restarting and both sides redialling.

**Checkpoint**: one copy serves a host and a client over WebSockets with state in a folder.
Walk quickstart Walk 1, steps 1–2, with `agentsd` and a scripted client.

---

## Phase 4: User Story 1 — The Mac window works through the control plane, sandboxed (P1) 🎯 MVP

**Goal**: the window, built with `AGENTS_STORE`, is sandboxed, links only `AgentsKitCore` and
`Shared`, and does everything through the control plane.

**Independent test**: quickstart Walk 1, steps 3–7, with no child processes and no sandbox
violations.

- [x] T044 (a second target, `AgentsStore`, over the same sources, with its own bundle id `com.alexecollins.agents.store` so a walk never shares the real app's defaults; the ssh servers, launch agents and move files are excluded; a store-only `HostSet` and `ControlConfig` stand in) [US1] Add the `AGENTS_STORE` configuration to the Agents target in `project.yml`:
  - `App/Agents-Store.entitlements` with `com.apple.security.app-sandbox`, `network.client`, `device.audio-input` and `files.user-selected.read-only`;
  - `NSBonjourServices` = `_agents-control._tcp`, and `NSLocalNetworkUsageDescription`;
  - link `AgentsKitCore` only;
  - no `Contents/Helpers`, `Resources/servers` or `Resources/toolsets` in that configuration.

  - swap `import AgentsKit` for `import AgentsKitCore` in every `App/` and `Shared/UI` file the store configuration builds (95 files, S5);
  - build with `-IDEBuildingContinueBuildingAfterErrors=YES`, and add `-continue-building-after-errors` to the target's Swift flags while US1 is under way (S5).

  The developer configuration stays as it is until T112.
- [x] T044a (whole files for CredentialStore/Check, BrowserPolicy, FileProbe, StoreLocations with StoreCoding and Lossy, MachineID; `WorkflowPaths`, `MCPCatalogWords` and `ControlBonjour` split out, since WorkflowFile needs the YAML parser) [US1] Move the pure types the window needs into `Packages/AgentsKit/Sources/AgentsKitCore/` (S5):
  - `CredentialStore` and `CredentialCheck` (from `AgentsKit/Credentials`);
  - `MCPCatalogWords` (from `AgentsKit/Daemon/DaemonCore+MCPCatalog.swift`);
  - `BrowserPolicy`, and the `FileProbe` value type without its `read` (from `AgentsKit/Files`);
  - the path part of `WorkflowFile` (from `AgentsKit/Workflows`);
  - `ControlNet.serviceType`;
  - a window-root part of `StoreLocations`;
  - `MachineID`, if its `gethostuuid` works in the sandbox (checked in T053).

  `agentsd` and the tests keep building, and nothing moved imports `Process` or POSIX file calls.
- [x] T044b (`scripts/check-store-window.py`, a build phase of AgentsStore; 17 allowed lines carry `// store-ok:` with their reason) [US1] Write `scripts/check-store-window.sh`, run by the store build: under `AGENTS_STORE`, fail on `FileManager`, `contentsOf:`, `NSWorkspace` given a path, `dlsym`, `Process` or `posix_spawn` in `App/` and `Shared/UI` outside an allow-list (the container, and `mac/*` results). Linking only Core does not catch these (S5).
- [x] T045 (in `DaemonCore+Mac.swift`, with `/usr/bin/open`; `DaemonAPI+Mac.swift` in Core) [P] [US1] Write the Mac host methods in `Packages/AgentsKit/Sources/AgentsKit/Daemon/MacHostMethods.swift`:
  - `mac/reveal {path}`, `mac/open {path, app?}` and `mac/terminal {path?, command?}`, operator only, answered only on macOS with `NSWorkspace`;
  - Linux answers `unsupportedHere`;
  - add them to `DaemonAPI.Method` and to the device refusal list, and add grant tests.
- [x] T046 (changed: the shared pages already read over RPC, so `shared/*` was not needed; `files/browse` already answers whether a path is there, so no `files/stat`; added `files/readText` and `files/saveText` by full path, operator only, 1 MB) [P] [US1] Write the shared-folder host methods in `Packages/AgentsKit/Sources/AgentsKit/Daemon/SharedMethods.swift`: `shared/list` and `shared/read` for any grant, and `shared/write` and `shared/remove` for operators, over the host's `~/.agents` (054's layout). Add `files/stat {path}` → `{exists, kind, size, modified}`, and add grant tests.
- [x] T047 (`readsDisk(of:)` is false in the store window; `readText`/`saveText` over files/readText and files/saveText; the plugins list over files/browse; the clone hint says `~/<name>`) [US1] Replace every `isOnThisMac` direct read with host calls. The places:
  - in `App/Sources/AppModel.swift`, `textFile` becomes `files/read` and `pathIsThere` becomes `files/stat`;
  - `App/Sources/Projects/WorkflowPage.swift`, `WorkflowRow.swift`, `App/Sources/Sidebar/BackgroundPane.swift`, `FilesPane.swift` and `App/Sources/AgentList/AgentRow.swift`;
  - the shared pages (`App/Sources/Settings/SharedSettingsView.swift` and its pages), which use `shared/*`;
  - `App/Sources/Projects/AgentsSetup.swift` (reads, writes and lists `AGENTS.md`), `ProjectRow.swift` (home folder), `ImageFile.swift` and `MacPageActions.swift` (S5);
  - `CloneSheet.swift`, which uses a new host field, the host's clone parent, instead of `DaemonCore.defaultCloneParent()` (S5).

  Keep `ThisMacHost` only to decide whether Reveal and Open are offered.
- [x] T048 (`model.reveal`/`open`/`openTerminal`, and `SharedFiles` through the model in the store window) [US1] Send Reveal in Finder, Open in another app and open Terminal through `mac/*` on this Mac's host. The places are `App/Sources/Sidebar/OpenElsewhere.swift`, `App/Sources/Commands/AgentsCommands.swift`, `AgentRow.swift`, `BackgroundPane.swift` and `RuntimeAccountView.swift`, and also `PluginsSection.swift`, `SharedSettingsView.swift`, `AgentsSetup.swift` and `ChatView.swift` (S5: 16 files use `NSWorkspace` on paths).
- [x] T049a (the store build reaches the host only through controlHosts and ControlConfig.macClient; DaemonClient() and DaemonLock are fenced out) [US1] `AppModel` reaches every host only through the control plane's host list (`controlHosts`), and drops `DaemonClient()` (the `SocketLink` default) and `DaemonLock`, under `AGENTS_STORE` (S5: about 24 sites in `AppModel`).
- [x] T049b (the store build has a stand-in HostSet filled from the control plane's hosts; the developer HostSet stays until T106) [US1] Retire the window's ssh servers under `AGENTS_STORE`:
  - remove `HostSet`, `ServerConnection`, `SSHCommand`, `SSHMaster`, `ServerBinaries`, `AddServerFlow`'s ssh path and `RebuiltServerSheet`;
  - move `ClaudeKeychainSignIn`, `MacSignInRelay` and `SignInRelays` out, in T091;
  - make the views that read `model.hosts` read the control plane's hosts: `ChatView`, `PromptBar`, `OfflineStrip`, `AgentsCommands`, `HostHeading`, `Lending`, `RemoteFolderSheet`, `ProjectAgentsView`, `ProjectSettingsSheet`, `ProjectListView`, `WorkflowPage`, `FilesPane`, `MacPageActions`, `CloneSheet`, `ServersSettingsView`, `ContentView`, `ArchiveSettingsView` and `CostSettingsView` (S5).
- [x] T049c (the store build has no errors; LocalServices, MoveAcross and WindowFiles are excluded from it) [US1] `ControlConfig` is a remote endpoint only under `AGENTS_STORE`: no local socket, `Daemon.platform`, or *run a host here*. `LocalServices`, `MoveAcross`, `WindowFiles` and `FirstRunView`'s *Run one here* leave the window (they move to the host app in T055 and T086). Afterwards the store configuration builds with no errors (the S5 list, `spikes/s5-sandbox-build/pass2-after-moves.errors`, is the checklist).
- [x] T050 (StoreControlConfig: the membership and key are files in the container, not the keychain, until the build is signed; walks/us1-store.md) [US1] In `App/Sources/Control/ControlConfig.swift`, the config holds `url`, `pin` and the client id in the container's defaults, with the key in the window's keychain. `AppModel` builds every client from one `ControlLink` over `WebSocketLink`. It has no path without a control plane under `AGENTS_STORE` (FR-028).
- [x] T051 (StoreFirstRunView: K and K2, with AgentsHostDownloadURL in Info-Store.plist) [US1] Build frame K in `App/Sources/Control/FirstRunView.swift` and `ConnectSheet.swift`, after Alex approves it (T028). It has the two states. *Set one up on this Mac* opens the host app's download page URL, taken from `Info.plist` `AgentsHostDownloadURL`, and Bonjour finds an installed host app.
- [x] T052 (the store window reports only its own activity; the lock probe is the host's) [US1] Presence under the sandbox: in `App/Sources/Presence/PresenceReporter.swift`, drop the `CGSSessionScreenIsLocked` probe. The window reports only its own activity, and the Mac host reports the lock state. Check with 043's presence tests.
- [x] T053 (walked on screen 2026-09-29: K, K2, pairing through the sheet, a real Claude turn, Reveal through the host, the shared page answered by the host, no children or sandbox denials; open: the Local Network prompt needs a second machine, and the Skills page needs a host with shared on; walks/us1-store.md) [US1] Walk quickstart Walk 1, steps 1–7, with the store configuration on a scratch root and a real Claude turn:
  - screenshot each step;
  - check the window has no child processes and there is no sandbox violation in `/usr/bin/log`;
  - open the store build from Finder and dial a control plane on another machine, and record the Local Network prompt and what refusing it does (S2 left this open);
  - check Reveal and the shared skills page reach the host;
  - check `MachineID` works inside the sandbox, or record what `ThisMacHost` uses instead (S5);
  - run `scripts/check-store-window.sh` (T044b) and see it pass.

  Record it in `specs/058-control-plane/walks/us1-store.md`.

**Checkpoint**: the sandboxed window works end to end against one copy (SC-001).

---

## Phase 5: User Story 2 — First run: connect to one, or set one up here (P1)

**Goal**: Agents Host.app installs outside the store, runs a host and, if chosen, a
single-copy control plane, and the window pairs with it.

**Independent test**: quickstart Walk 1 with the host app's scratch build instead of
hand-started processes, and SC-006 timed.

- [x] T054 (built: Helpers agentsd + agents-control, LaunchAgents, servers/toolsets copied (the Agents target keeps its own until T106); agents-relay waits on T096; signed Apple Development locally, Developer ID with T089) [US2] Add the `Agents Host` target to `project.yml`:
  - Developer ID signing, bundle `com.alexecollins.agents.host`, `LSUIElement`;
  - `Host/Sources`;
  - embedded helpers in `Contents/Helpers`: `agentsd`, `agents-control` (macOS build of `Packages/ControlPlane`) and `agents-relay` (T096);
  - `Contents/Resources/servers` and `toolsets` moved here from the Agents target;
  - `Host/LaunchAgents/*.plist` in `Contents/Library/LaunchAgents`.
- [x] T055 (Host/Sources/LocalServices.swift; scratch roots bootstrap their own labelled jobs; the window's copy stays for the developer build until T106) [US2] Move `LocalServices` from `App/Sources/Control/LocalServices.swift` to `Host/Sources/LocalServices.swift`:
  - `SMAppService.agent` for `agentsd`, always;
  - `agents-control` only when *Run the control plane here* is on;
  - `agents-relay` only when relaying (T097).

  Keep the scratch-root labelled jobs.
- [x] T056 (keychain, handed over on fd 3 by the app's own program as launcher; scratch roots use a 0600 file; reusing relay-mac-key waits on the move (US7)) [US2] The control plane's key in the host app, in `Host/Sources/ControlKey.swift`: made once and kept in the keychain. On a Mac with today's set-up, it is the existing `relay-mac-key`. It is handed to `agents-control` through an inherited descriptor (`--key-fd`) by a small launcher, `Host/Sources/ControlLauncher.swift`, that the launch agent runs. The key is never written to disk (FR-010).
- [x] T057 (agents-control serve --home: TLS and store in the folder, 8791, the .local URL, Bonjour with the pin in TXT) [US2] On first start, the single copy makes a self-signed certificate in its folder and a store in `~/Library/Application Support/Agents Control/store`. It advertises `_agents-control._tcp` with the pin in its TXT record, and listens on 8791 with URL `https://<.local name>:8791`.
- [x] T058 (walked; the relay row greyed until T096, the move strip with T086) [US2] Build frame L in `Host/Sources/HostWindow.swift`, after approval (T028): state, the code to pair, *Run the control plane here*, *Join one elsewhere* (a host code, which gives only the host), *Relay for my devices*, and the move entry (T086).
- [x] T058a (walked against MinIO: Check, keys on fd 4) [US2] Store choice in the host app, in `Host/Sources/StoreChoice.swift` (FR-024a, research R9):
  - *This Mac* (the default), a folder, or *A bucket*: endpoint, bucket, prefix, access key and secret;
  - *Check* runs the start-up probe (contracts/store.md rule 4) before saving;
  - the keys are kept in the host app's keychain and handed to `agents-control` through `--store-credentials-fd`, never in a plist, file or environment variable;
  - `agents-control serve` reads that descriptor in `Packages/ControlPlane/Sources/agents-control/main.swift`.
- [x] T058b (walked folder→MinIO→folder; 3 StoreCopyTests) [US2] Write `agents-control store copy --from --to` in `Packages/ControlPlane/Sources/ControlPlaneKit/Store/StoreCopy.swift`, following contracts/store.md "Copying a store":
  - refuse a destination that has `control.json`;
  - skip `leases/` and `copies/`;
  - verify the count and SHA-256 of each object.

  Add *Switch store…* in the host app: stop the copy, copy, point the copy at the new store, and start it. The old store is kept until removed. Add tests in `Packages/ControlPlane/Tests/ControlPlaneKitTests/StoreCopyTests.swift`: folder to memory and back, a non-empty destination refused, and every record intact.
- [x] T059 (K2's Pair opens agents-host://pair and Agents Host shows the code; typed or pasted into the sheet) [US2] The window pairs with a host app it found (frame K, second state): a code handed over through the host app's window, or typed. Installing twice registers nothing twice (US2-4).
- [x] T060 (walks/us2-host-app.md; log out/in replaced by launchctl print; a bucket chosen after first run, then switched) [US2] Walk US2 on a scratch root:
  - install the host app's scratch build and choose *Run the control plane here*;
  - pair the store-configured window and time it (SC-006);
  - log out and in (or `launchctl print` shows the jobs);
  - set up once with *This Mac* and once with *A bucket* on MinIO;
  - switch a running set-up from the folder to MinIO and back, and check the window and a host carry on without pairing again (US2-5, US2-6);
  - unregister the jobs afterwards.

  Record it in `specs/058-control-plane/walks/us2-host-app.md`.

---

## Phase 6: User Story 3 — The control plane keeps going when one copy stops (P1)

**Goal**: several copies over S3 or a folder, any copy serving anyone, with failover.

**Independent test**: quickstart Walk 2 in full.

- [x] T061 (ControlRouter: local or proxied host sessions, peer streams mapped at the holder; router tests are the copies tests) [US3] Proxied host sessions in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlRouter.swift`. A `HostSession` is either local or proxied, and a proxied one is a stream on a peer link with this copy's own channel numbers. Add router tests for:
  - a client on B reaching a host on A;
  - a `gone` closing B's channels;
  - a grant check at B.
- [x] T062 (pulled forward for US2: S3Store, SigV4 against AWS's example, conformance on MinIO) [P] [US3] Write `S3Store` in `Packages/ControlPlane/Sources/ControlPlaneKit/Store/S3Store.swift` over async-http-client, following contracts/store.md:
  - SigV4 signed with `ControlAgreement`'s HMAC-SHA256;
  - `If-None-Match`, `If-Match` and ETags;
  - path-style when `AGENTS_STORE_PATH_STYLE=1`;
  - `AGENTS_STORE_ENDPOINT`;
  - credentials from the environment or `~/.aws`.

  Run T034's conformance against MinIO.
- [x] T063 (Copies/Leases.swift: take on an authenticated uplink, renew every 10 s, lost → close and gone, released when the uplink ends) [US3] Write leases in `Packages/ControlPlane/Sources/ControlPlaneKit/Copies/Leases.swift`, following data-model.md's Lease states:
  - create or take over on an authenticated uplink (epoch + 1);
  - renew every 10 s with `.matching`;
  - on a lost renewal, close the uplink and broadcast `hostMoved`;
  - on an expired lease, mark the host offline.
- [x] T064 (Copies/PeerLinks.swift: copies/<id>.json heartbeat, the smaller id dials, x: bound to the peer origin) [US3] Write the copy registry and peer links in `Packages/ControlPlane/Sources/ControlPlaneKit/Copies/PeerLinks.swift`:
  - `copies/<id>.json` with a heartbeat every 10 s, and gone after 30 s;
  - one WebSocket for each pair of copies, with `ControlAuth` identity `x:`;
  - the `{p, c, open|m|close|gone}` streams;
  - `event`, `presence` and `host` messages;
  - redial while both copies are registered.
- [x] T065 (ProxyUplink at the proxying copy; the holder maps (peer, c) in the router) [US3] Channel mapping at the holding copy, in `Packages/ControlPlane/Sources/ControlPlaneKit/Copies/ProxyUplink.swift`: `(peer, c)` maps to a fresh uplink channel and back. A peer dropping closes its channels on the host.
- [x] T066 (broadcast then events/<day>/…; applied at every copy; catch-up by reconciling sessions on link up and every 15 s instead of replaying events/) [US3] Changes across copies:
  - store first, then broadcast `event` on every peer link, then write `events/<day>/<ulid>.json`;
  - apply received events (close forgotten clients, reopen channels on a grant change, mark hosts);
  - catch up from `events/` when joining;
  - re-list every 15 s.
- [x] T067 (7 CopiesTests over one MemoryStore) [P] [US3] Copies tests in `Packages/ControlPlane/Tests/ControlPlaneKitTests/CopiesTests.swift`, with three in-process copies over one `MemoryStore`:
  - a client on each copy sees every host;
  - killing the holder moves the lease and the host redials;
  - a code shown at one copy is used at another, once;
  - a forget reaches every copy within 2 s;
  - two grant changes race and one gets `changedElsewhere`;
  - with the store down, live calls carry on and pairing gets `storeUnavailable`.
- [x] T068 (deploy/: Containerfile, compose.yaml, Caddyfile, make-secrets.sh, README; scripts/build-linux-control.sh) [P] [US3] Write `deploy/Containerfile` for `agents-control`, with a static musl build and a non-root user. Write `deploy/compose.yaml` with MinIO from `cgr.dev/chainguard/minio` (bucket `agents-walk`), three copies, and Caddy terminating TLS with a local CA whose pin goes in the codes. Add `deploy/README.md`.
- [x] T069 (walks/us3-copies.md; the devbox and fake device not walked (one URL, T078)) [US3] Walk quickstart Walk 2, steps 1–10, in Colima with the devbox, a scratch host, the store-configured window and the fake device. Screenshot and time the failovers (SC-003). Record it in `specs/058-control-plane/walks/us3-copies.md`.

---

## Phase 7: User Story 4 — A server joins by connecting out (P2)

**Goal**: servers join by a shown command, or by an ssh install that keeps nothing.

**Independent test**: quickstart Walk 3.

- [x] T070 (HostInstallScript in ControlPlaneKit, served at /v1/install.sh with the host at /v1/servers/…; scripts/host-install.sh is its text (a test keeps them equal); pinned with curl --pinnedpubkey) [P] [US4] Write `scripts/host-install.sh`, served by the control plane at `GET /v1/install.sh` and linked from the command. It checks for system CA roots when the control plane's certificate is publicly trusted (S3), downloads the Linux host tarball for the machine (from the release, or from the copy with `--from-control`), installs it for the user with a systemd user unit, and runs `agentsd --control <code>`.
- [x] T071 (ControlCodeShown.command, pinned) [US4] `hosts/startEnroll` returns `{code, command}` in `ControlMethods.swift`, with the command built from `url`, `pin` and the code.
- [x] T072 (Hosts/HostInstall.swift: key 0600 in a folder of its own removed on every way out, host key into a temporary known_hosts, the code left in the host's root, no master or forward) [US4] Move `hosts/install` into the service, in `Packages/ControlPlane/Sources/ControlPlaneKit/Hosts/HostInstall.swift`, from `SSHHosts`:
  - `{name, destination, key, trust?}`;
  - the key is held in memory for the one call, with a private `ssh-agent` or `-i` on a 0600 temporary file deleted in `defer`;
  - the host enrols over its own uplink afterwards;
  - no master or forward is kept (FR-018a);
  - the Linux binaries come from the host app's or container's resources.
- [x] T073 (SSHUplink and HostReach.ssh gone (old records read as dialOut); SSHHosts only installs and restarts dial-out hosts. hosts/update over the uplink not built: a host updates by running the command again) [US4] Remove `SSHUplink.swift`, ssh-reached `HostRecord.reach`, and `hosts/checkAgain`'s ssh path. `hosts/update` asks the host to update itself over its uplink.
- [x] T074 (App/Sources/Control/ControlAddServerSheet.swift: Run a command (closes when the server joins) / Install over ssh (key read once from Choose…)) [US4] Build frame M in `App/Sources/Control/AddServerSheet.swift`, after approval: *Run a command* shows the code and command with a copy button; *Install over ssh* picks a key file, whose contents are sent once and never kept.
- [x] T075 (walks/us4-servers.md; Walk3LiveTests on the devbox: command and ssh install both joined, nothing left behind, back 2.1 s after a 60 s drop, removed while still running; frame M not walked on screen) [US4] Walk quickstart Walk 3 with test-servers on the devbox, both ways:
  - no ssh process and no key file is left afterwards;
  - a network drop and return;
  - remove.

  Record it in `specs/058-control-plane/walks/us4-servers.md`.

---

## Phase 8: User Story 5 — The iPhone and iPad see every host, at home and away (P2)

**Goal**: the Remote dials the control plane over WebSockets, falls back to the relay, and is
told when it is needed.

**Independent test**: quickstart Walk 5 with the fake device.

- [x] T076 (Remote/Sources/Link/ControlPlaneLink.swift, RemoteApp picks it once paired, pair(scanned:) takes v2 device codes; AwayLink kept for an unmoved Mac) [US5] Move `Remote/Sources/RemoteModel.swift` onto `WebSocketLink` and `ControlLink`, with `url` and `pin` from the pairing code. Remove the Remote's TLS-PSK `NetworkLink` path for the control plane, keeping it only for a not-yet-moved Mac (until T112).
- [x] T077 (built: `ControlPlaneLink` tries the address, then `ControlCodeUse.relayedDial` with the relay key `control/status` named, and goes back to the address every 30 s; the second, wrapped connection stays address-only, as the relay carries one session per device; built for the generic simulator; the fallback on a phone is Alex's to look at) [US5] Relay fallback in `Remote/Sources/`: when the control plane's URL cannot be reached, use the CloudKit relay. The device runs `ControlAuth` end to end through `agents-relay` (T096).
- [x] T078 (pairs with a v2 device code and dials over WebSocketLink; with AGENTS_FAKE_DEVICE_RELAY=1 it goes through a scratch agents-relay over a folder standing in for iCloud, and reads a notice back) [P] [US5] Update `FakeDeviceLiveTests` in `Packages/AgentsKit/Tests/AgentsKitTests/` to dial over `WebSocketLink`, and with `AGENTS_FAKE_DEVICE_RELAY=1` to go through a scratch `agents-relay`.
- [x] T079 (walks/us5-phones.md: direct and relayed paths walked with the fake device, and a notice read back with its key, over a folder standing in for iCloud; real CloudKit and the phone look are Alex's) [US5] Build the Remote for the generic iOS simulator. Walk quickstart Walk 5, steps 1–2, with the fake device. Record it in `specs/058-control-plane/walks/us5-phones.md`, and ask Alex about looking on the phone.

---

## Phase 9: User Story 6 — The person decides what each client may do (P2)

**Goal**: frames D–G, done under the first build (T012), hold across copies, and relayed
clients show as such.

**Independent test**: US6 scenarios over two copies, as part of Walk 2 steps 8–9.

- [x] T080 (built, not yet on screen: `clients/connections` across copies through a `link` frame between copies; the pane moved to ControlClientsPane.swift with "connected directly", "connected through <Mac> (iCloud relay)" and *away*; the relaying Mac is the first relay host, as a relayed session does not say which carried it) [US6] Build frame N in `App/Sources/Control/ControlClientsPane.swift`, after approval: a relayed client's marker, and "reached through <Mac>".
- [x] T081 (built: `HostProblem.controlRefusal`; the last-operator refusal did NOT hold across copies — two operators demoting each other at two copies both went through — fixed with `v1/operators.json`, rewritten conditionally on every change of operator, and tested in `CopiesTests.theLastOperatorHoldsAcrossCopies`) [US6] The Settings panes read `changedElsewhere` and `storeUnavailable` and say so in words in `App/Sources/Hosts/HostProblem+Words.swift`. The last-operator refusal holds across copies, as tested in T067.
- [x] T082 (walked on two copies over MinIO: D, E, F, G, N, promote, forget across copies, race, store down in words — walks/us6-grants.md; four found and fixed, and the fixes seen on screen) [US6] Walk: promote, forget and race over two copies, with screenshots of frames D–G and N. Record it in `specs/058-control-plane/walks/us6-grants.md`.

---

## Phase 10: User Story 7 — Moving an existing set-up across, once (P2)

**Goal**: the host app takes over today's root in place, and devices move without pairing
again.

**Independent test**: quickstart Walk 4, steps 1–3.

- [x] T083 (HostPaths: a scratch AGENTS_ROOT holding an old set-up is the host root; the real one already is) [US7] In the host app, point `agentsd` at the existing root `~/Library/Application Support/Agents` when it has data, copying nothing (FR-025). On a scratch root, this is `AGENTS_ROOT`.
- [x] T084 (`agents-control move --from`, into whichever store the copy uses; servers join with `code --host --command` run over the person's ssh by Agents Host, or are listed with it) [US7] Write the store from `ControlMove` in `Packages/AgentsKit/Sources/AgentsKit/Control/ControlMove.swift`:
  - `devices.json` entries become `clients/<id>.json` with grant `device` and their existing key;
  - `hosts.json` servers are enrolled over ssh (T072), or listed with their command;
  - the Mac's own host becomes `mac`.
- [x] T085 (`control-moved.json` in the root; the daemon tells each device that binds or identifies itself; the Remote keeps it and dials with its own key; the old bridge is never stopped by the move, so the old link lasts until the earlier app is quit — no frame L button to end it yet) [US7] Tell moved devices the new URL and pin over the old bridge link and the relay (`control/moved {url, pin}`, a new notification to devices). Keep the old bridge's `DirectLink` running until every moved device has connected over WebSockets, or the person ends it from frame L.
- [x] T086 (Host/Sources/MoveView.swift: frame L's strip and frame I's sheet; MoveAcross.swift was already out of AgentsStore) [US7] Run the move from frame L in `Host/Sources/MoveView.swift`, reusing frame I's content, instead of `App/Sources/Control/MoveAcross.swift`, which is removed under `AGENTS_STORE`.
- [x] T087 (ControlMoveTests: the store a copy serves, a failed move leaves the root; MoveTests: a moved device proves itself as c:, another key is refused; ConnectionRoleTests: the notice to a device, not to one pairing) [P] [US7] Extend `ControlMoveTests` to cover the store output, a device key proving itself as `c:` afterwards, and a failed move leaving the old root working (FR-039).
- [x] T088 (walks/us7-move.md: seeded root, the move from frame L, the agent kept, the devbox joined over ssh, the fake iPhone told over the old link and connecting the new way as itself) [US7] Walk quickstart Walk 4, steps 1–3, on a scratch root seeded the old way, with `FakeDeviceMoveLiveTests` (`pair`, then `again` over WebSockets). Record it in `specs/058-control-plane/walks/us7-move.md`.

---

## Phase 11: User Story 8 — The apps pass App Store review (P2)

**Goal**: all three apps pass App Store Connect validation, and a demo is ready for App Review.

**Independent test**: quickstart Walk 6.

- [x] T089 (AgentsStore and Remote schemes archive Release; Remote/Remote-AppStore.entitlements with production push and iCloud for Release; distribution signing and upload are Alex's) [US8] Add an App Store archive scheme and configuration for Agents (store configuration) and the Remote in `project.yml`, with production `aps-environment` from the distribution profile. Signing credentials are Alex's: ask before any upload.
- [x] T090 (passes both archives, fails the developer build) [US8] Write `scripts/check-store-archive.sh`. It lists every Mach-O in an `.xcarchive` and fails on anything but the app's own executable and its frameworks. It also checks the Mac archive's entitlements match T044's list.
- [x] T091 (walks/us8-signin.md: the card, Allow, the grant, the tunnelled offer, and Claude on the devbox reaching the Mac's relay through the control plane with a stand-in sign-in; two fixes found on the way) [US8] Move the Claude sign-in reading and the sign-in relay to the Mac host: `ClaudeKeychainSignIn` (`/usr/bin/security`) and `MacSignInRelay` (`openssl`, listener) go to `Packages/AgentsKit/Sources/AgentsKit/Daemon/`. Lending to a server goes host to host through the control plane, after an operator client approves the request in the window (a question card).
- [x] T092 (deploy/demo: compose, Caddyfile, codes job, demo host image, REVIEW-NOTES.md; compose.local.yaml + local-cert.sh for a walk; `agentsd acp-echo` behind AGENTS_TEST_RUNTIME=echo) [US8] Write the demo control plane in `deploy/demo/`: a compose file with one copy, one demo host with a canned runtime (`AGENTS_TEST_RUNTIME=echo`), and a long-lived device code. Also write `deploy/demo/REVIEW-NOTES.md`.
- [x] T093 (walks/us8-store.md: archives checked and validated by altool, uploaded as build 1 unsubmitted; the notes walked on a fresh store window against the local demo, which paired and answered; the demo host's restart and the demo turn's Needs you fixed; the window on a control plane with no Mac host is T093a) [US8] Validate both archives with `xcrun altool --validate-app`. Walk quickstart Walk 6 from a fresh scratch window against the demo. Record it in `specs/058-control-plane/walks/us8-store.md`. Uploading or submitting is Alex's call.
- [ ] T093a [US8] The store window on a control plane with no host on this Mac (the demo's shape): show no THIS MAC heading and no lasting Connecting… row, count the window connected once the control plane answers, and send an agent's calls to its own host rather than `.mac` (a Send raised "Could not reach the helper that runs the agents"). Found walking REVIEW-NOTES.md, walks/us8-store.md.

---

## Phase 12: User Story 9 — Another Mac as a host (P3)

**Goal**: the host app on a second Mac joins as a host only.

**Independent test**: quickstart Walk 4, step 4.

- [ ] T094 [US9] *Join one elsewhere* in frame L takes a host code and registers only `agentsd` with `--control <code>`. This replaces T062's choice in the window's `ConnectSheet`, which is removed under `AGENTS_STORE`.
- [ ] T095 [US9] Walk: a second host app under another scratch root joins, and its projects show under their own heading. Record it in `specs/058-control-plane/walks/us9-second-mac.md` (was T063).

---

## Cross-cutting: relay and notices (US5 and US2 both need them)

- [x] T096 (built: `ControlRelay` in AgentsKit, `Host/Relay/Sources/main.swift`, the `agents-relay` target signed as the bridge with its container and embedded in Agents Host's Helpers; `FolderRelayChannel`/`FolderMailbox` for walks. The bridge keeps its own relay and mailbox until the move (T112), since the live app's away path uses them. Frame L's relay toggle is still greyed: registering agents-relay as a launch agent is not built) Cut `agents-relay` out of `Bridge/` into `Host/Relay/`: `RelayHost.swift` and `MailboxTransport.swift`. Remove `DirectLink` and the control plane from it. Add a background-only app bundle target with the CloudKit entitlement and a Developer ID provisioning profile. A relayed device gets a WebSocket to the control plane (`kind: relay`, `for: <device>`), with the key exchange passed through untouched.
- [x] T097 (built: `NoticeDesk` in Core, the service's `heard`/`deliver`, a `need` frame between copies, `relay/devices`, `hosts/setRelay`; `NoticesTests` (5) and a two-copy test in `CopiesTests`) Notices: a copy forwards `attention/need`, with folded presence, to a relay host as `relay/deliver` on channel 0. `agents-relay` seals the need and posts it to the CloudKit mailbox, as `MailboxTransport` does today. Add `hosts/setRelay`. With no relay host, needs go only to connected clients. Add tests in `Packages/ControlPlane/Tests/ControlPlaneKitTests/NoticesTests.swift`.

---

## Phase 13: Polish and close (plan Phase 9)

- [ ] T098 [P] Write `docs/explanation/control-plane.md` as the spec's Docs section gives it: copies, the store, hosts and clients, where to run it, what happens when it or the store is down, and why.
- [ ] T099 [P] Update `docs/explanation/window-and-daemon.md`, `phone-and-ipad.md`, `projects-hosts-worktrees.md` and the `README.md` set-up, following the spec's Docs section.
- [ ] T100 [P] Add `docs/how-to/` pages and put them in `mkdocs.yml`:
  - set one up on this Mac;
  - run the control plane as several copies with a bucket;
  - connect a window or phone;
  - add a server;
  - move an existing set-up across.
- [ ] T101 Measure R14: terminal echo and question delivery, median of 200, each compared with `daemon.sock`, through one copy, through two copies and through Caddy. Write the results in `specs/058-control-plane/walks/latency.md`. If SC-004 fails, stop and ask Alex.
- [ ] T102 Run `security-review` on the branch. Focus on:
  - the operator role reachable from the network;
  - the key exchange and its lack of TLS binding;
  - the shared control key across copies and its delivery;
  - the store layout and its secrets;
  - the ssh key given for an install;
  - the relay passing the exchange through.
- [ ] T103 Compare six full runs of `swift test` in `Packages/AgentsKit` and `Packages/ControlPlane` on this branch and on main. Build both schemes and the store configuration, and pass the Linux gate.
- [ ] T104 Merge `main` again before closing, and re-run T103's builds.
- [ ] T105 Alex's own move: only with his go-ahead (AskUserQuestion), and with the hand-started bridge on 8790 stopped first.
- [ ] T106 In a **separate** change, after T105 is walked, remove:
  - the developer window path (`SocketLink` spawning, `HostSet`, `LocalServices` in the window);
  - the bridge's `DirectLink` and `Bridge/`;
  - the `AGENTS_STORE` switch, so the store configuration is the only one;
  - the Remote's old TLS-PSK path.

---

## Dependencies

- **Setup and spikes** (T021–T026) come first. T025 (S5) sizes Phase 4. A failed S2 or S4 stops
  the work for Alex.
- **The look gate** (T027–T028) blocks every UI task: T051, T058, T074 and T080.
- **Foundational** (T029–T043) blocks every story.
- **US1** (P1) and **US3** (P1) can proceed in parallel after Foundational. They share only
  `ControlRouter` (T061 touches it) and the MVP walk.
- **US2** depends on T096 for the relay helper's target, but not on its behaviour. Its walk
  needs US1's window.
- **US4** needs Foundational, and T072 needs `HostInstall`'s resources from T054.
- **US5** needs T096–T097.
- **US6** needs US3.
- **US7** needs US2 and T072.
- **US8** needs US1 and T091.
- **US9** needs US2.
- **Polish** comes last, and T106 only after T105.

## Parallel opportunities

- **Spikes:** T022, T023, T024 and T025 are independent. So are T027 and the spikes.
- **Foundational:** T029, T030, T031, T033, T035, T036, T038 and T040 touch different files.
- **US1 and US3:** T045 and T046 (host methods) run alongside T062 (S3Store) and T068 (deploy).
- **Docs:** T098, T099 and T100.

## Implementation strategy

1. **The MVP.** Spikes, the look gate, Foundational, then US1. A sandboxed window works
   against one copy on this Mac, which is the App Store goal's heart, proven early.
2. **Then US3,** the scaling goal, proven with three copies, MinIO and Caddy.
3. **Then US2 and US7:** the host app and the move, which unblock Alex's own set-up.
4. **Then US4, US5, US6, US8 and US9,** each walked on its own.
5. **Close.** Nothing merges to main until Polish, and Alex decides when.
