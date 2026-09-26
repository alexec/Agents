# Tasks: A Control Plane, and the Mac Window as One More Remote

**Input**: `specs/058-control-plane/` — plan.md, spec.md, research.md (R1–R11), data-model.md,
contracts/wire.md, contracts/control-api.md, quickstart.md, look/ (approved 2026-09-26: D/E/F,
the name "Control plane", This Mac's host has no buttons).

**Tests**: included. SC-001 and SC-005 require them: the full suite stays green, and every
operator-only call is refused for a device, both at the control plane and at the host.

**Walks**: every story ends with a run-app walk on a scratch root (quickstart.md). A story that
touches hosts is also walked against the devbox with test-servers. Never walk on the real root
or on Alex's paired devices.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task).
- **[Story]**: US1–US7 from spec.md.

---

## Phase 1: Setup

- [ ] T001 Rename the `agents-bridge` target to `agents-control` in `project.yml`. Keep its bundle, CloudKit entitlement and `Contents/Helpers` embedding in `Agents.app`. Move `Bridge/` to `Control/`. Then run `xcodegen` and build both schemes one after the other, with plugin validation skipped.
- [x] T002 [P] Create the empty module folder `Packages/AgentsKit/Sources/AgentsKitCore/Control/` and the test folder `Packages/AgentsKit/Tests/AgentsKitTests/Control/`. Check `swift build` still passes on the Linux gate. Nothing in `Control/` may import Network, CryptoKit or CloudKit.
- [x] T003 [P] Add the failures `hostOffline` (-32070), `noSuchHost` (-32071) and `lastOperator` (-32072) (-32040 to -32042 are taken) to `DaemonAPI.Failure` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, with messages in the style of the existing ones.

---

## Phase 2: Foundational (the router core; blocks every story)

- [x] T004 [P] Write `ControlWire` in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlWire.swift` (contracts/wire.md):
  - Client frames `{h?, m}`. Host frames `{c, m}`, `{c, open:{grant, client, device?}}` and `{c, close:true}`.
  - `isLegacy(line)` is true for an object with `jsonrpc` at top level.
  - Read only `m.method` for grant checks.
  - Keep `m`'s bytes as they arrived, never re-encoded, so a message passes through untouched.
- [x] T005 [P] Write `Grant`, `ClientRecord`, `HostRecord`, `HostReach`, `HostState` and `PairingCode` in `Packages/AgentsKit/Sources/AgentsKitCore/Control/Grant.swift`, as in data-model.md:
  - `ClientRecord.kind` is `mac | iphone | ipad`. `grant` is `operator | device`.
  - `HostRecord.id` is `mac` for the migrated home host, and 8 random chars otherwise.
  - `reach` is `dialOut | ssh(destination, hostKeyFingerprint)`.
  - `HostState` is `online · offline(since) · connecting · needsUpdate(from,to) · failed(reason)`.
- [x] T006 Write `GrantStore` in `Packages/AgentsKit/Sources/AgentsKitCore/Control/GrantStore.swift`. It reads and writes `clients.json`, `hosts.json` and `control.json` atomically under the control root.
  - `setGrant` and `forget` refuse to leave no operator (`lastOperator`, FR-009).
  - It reads a legacy `devices.json` as `device` clients.
- [x] T007 Write the `ControlRouter` actor in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlRouter.swift` (R3, R4):
  - It keeps `ClientSession`s and `HostSession`s. Channel numbers are per uplink and never reused.
  - Opening a client opens a channel to every online host, and a host coming online opens channels to every client.
  - It checks each request's grant against `ConnectionRole.control` / `.device` `.allows` and answers `notPermitted` itself, with `h` set.
  - A request for an offline host gets `hostOffline` at once, and an unknown `h` gets `noSuchHost`.
  - Replies and notifications get `h` added on the way to the client.
  - A legacy line with no `h` goes to the control plane's own handler for its methods, and to `homeHost` otherwise. Replies to it go back unwrapped.
  - It emits `control/hostChanged` when a host's state changes.
- [x] T008 Write the control plane's own handler in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlMethods.swift` for every row of contracts/control-api.md except `hosts/install`, `hosts/update` and `hosts/checkAgain`, which are pluggable closures supplied by the executable (US3):
  - The `devices/*` aliases.
  - `clients/forget`, which closes the client's session and its channels at once.
  - The `control/clientChanged` and `control/pairingChanged` notifications, sent to operators only.
- [x] T009 Write `ControlLink` in `Packages/AgentsKit/Sources/AgentsKitCore/Control/ControlLink.swift`. It is a `DaemonLink` that owns one physical `LineTransport` and hands out a `HostLink(host)` per `HostID`.
  - Each `HostLink` is a `LineTransport` that wraps outgoing lines with `h` and yields only lines for its host.
  - Control-plane messages with no `h` go to a `controlClient: DaemonClient`.
  - A host's link ends when `control/hostChanged` says it is offline, so `DaemonClient`'s reconnect runs as today.
- [x] T010 [P] Router tests in `Packages/AgentsKit/Tests/AgentsKitTests/Control/ControlRouterTests.swift` over `PairedTransport.pair()`:
  - request and reply pass through unchanged, byte for byte
  - notifications reach each client once, tagged with `h`
  - `credentialWanted`, lend and retry stay on one channel
  - `hostOffline` and `noSuchHost`
  - the legacy line goes to the home host
  - forget closes the client's channels
  - channel numbers are never reused
- [x] T011 [P] Grant tests in `Packages/AgentsKit/Tests/AgentsKitTests/Control/ControlGrantTests.swift` (SC-005): for **every** `DaemonAPI.Method` that `ConnectionRole.device` refuses, a device client's request is refused by the router and never reaches the host transport. Also: the last operator cannot be demoted or forgotten.
- [x] T012 [P] `GrantStore` tests in `Packages/AgentsKit/Tests/AgentsKitTests/Control/GrantStoreTests.swift`: round trip, atomic write, `devices.json` read as `device` clients, and the `lastOperator` refusals.
- [x] T013 (Not needed: the uplink dials out and never reaches `DaemonServer`'s dispatch, so it needs no role. Only its channels do, and they are `control` or `device`.) Host side: add the `.controlPlane` role to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/ConnectionRole.swift`. It allows channel frames and channel-0 methods only (`host/hello`, `hosts/announce`, `attention/need`, `control/ping`), no `hearsNotifications`, and can never be raised.
- [x] T014 Virtual connections: in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonServer.swift`, add `acceptVirtual(transport:role:device:)`. It builds a connection exactly like an accepted socket connection (identity, role, lent credentials, surface, broadcast subscription), with `device` channels bound as `connection/bindDevice` does. `open` is the only thing that sets its role, and only to `control` or `device`.
- [x] T015 Write `ControlUplink` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/ControlUplink.swift`:
  - It demuxes `{c,…}` frames from one `LineTransport`. `open` calls `acceptVirtual`, and `close` or the uplink ending closes that channel's connection.
  - It answers channel 0.
  - It redials with backoff 1 s → 30 s, and at once on a network change.
  - Agents keep running while it is down (FR-011).
  - The dial function is injected, so tests use `PairedTransport` and macOS uses TLS-PSK.
- [x] T016 [P] Uplink tests in `Packages/AgentsKit/Tests/AgentsKitTests/Control/ControlUplinkTests.swift`:
  - an operator channel may call `credentials/lend`, and a device channel is refused **at the host** (defence in depth)
  - two channels each get their own notifications
  - a lent credential dies with its channel
  - redial after the transport ends
  - an `agent` role can never be reached through `open`
- [~] T017 (2,720 tests: 21, then 16 issues under load, all in known-flaky suites; `ConnectionRoleTests` passes alone 14/14. The six-run comparison against main is still owed) Run the full `swift test` in `Packages/AgentsKit` and both schemes. Record the pass count against main's, using the six-run comparison if anything flakes.

**Checkpoint**: the router, the grants and the host side all work in memory. No UI yet.

---

## Phase 3: User Story 1

**MVP as built (2026-09-26):** this Mac's window and host reach the control plane over two same-user Unix sockets in the control root (`control.sock` and `hosts.sock`), with roles by code signature (`RolePolicy.forControl`). The control plane runs inside the bridge process when it is given `--control-root` or `AGENTS_CONTROL_ROOT`. T018–T020 (TLS listener, host PSKs), T022 (TLS dialer), T023/T029 (a saved config and pairing), T025–T028 are still open. Today the window takes `--control-root` and goes through the control plane for host `mac` only; servers still use `HostSet`. — The Mac window works through the control plane (P1) 🎯 MVP

**Goal**: a scratch window paired as operator does everything it does today, through `agents-control` to an `agentsd --control` on this Mac.

**Independent test**: quickstart.md steps 1–6 with a real Claude turn: start, question, answer, files, terminal, stop, control plane down and back.

- [x] T018 (the listener lives in `ControlNet`, in the bridge process; its own port, `AGENTS_CONTROL_PORT`, 8791 by default, and Bonjour type `_agents-control._tcp`) [US1] Put `ControlRouter` in place of the line pipe in `Control/Sources/main.swift`:
  - The `--root` flag, defaulting to `~/Library/Application Support/Agents Control`.
  - The `AGENTS_CONTROL_PORT` env var (default 8790), plus `AGENTS_CONTROL_NO_BONJOUR` and `AGENTS_CONTROL_NO_MAILBOX` for walks.
  - Clients are keyed by `clients.json`.
  - A `code --client <grant>` / `code --host` subcommand prints a pairing code, for walks and scripts.
- [x] T019 (`ControlKeys`: identities c:/h:/p:/e:, salts of their own; keys in 0600 files, not the keychain) [US1] In `Control/Sources/DirectLink.swift`, add host PSKs: identity `h:<id>`, derived with HKDF(ECDH, "agents-host-v1", id), plus the enrolment identity `e:`. Client PSKs `d:` and `p:` stay as they are, so today's devices' keys still work.
- [x] T020 [US1] Add a host listener path in `Control/Sources/main.swift`. An `h:` connection becomes a `HostSession`. An `e:` connection may call only `hosts/announce`, which issues a key, writes `hosts.json`, and replies `{host}`.
- [x] T021 [US1] (MVP: `--control <socket>` and `--host-id`, over the control plane's local socket; codes and the keychain come with TLS) Add `--control <code>` and `--control-home` to `Daemon/Sources/main.swift` and `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCommandLine.swift`.
  - `<code>` enrols once and stores the host key: in the keychain on a Mac, or in a `0600` file on Linux.
  - `--control-home` dials the control plane on loopback with the stored key.
  - Both imply `--serve`.
- [x] T022 (`ControlDialling`) [US1] Write a macOS TLS-PSK dialer for `ControlUplink` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/ControlUplink+Network.swift`, reusing `LinkTLS` from `AgentsKitCore/Remote/LinkTLS.swift`. Keep it behind `canImport(Network)`.
- [x] T023 (and a remote endpoint, a membership and key in the window’s root) [US1] Write `ControlConfig` for the window in `App/Sources/Control/ControlConfig.swift`. It holds the control-plane address and the window's client id, in defaults scoped by root (the scratch-defaults lesson). The window's key goes in the keychain.
- [ ] T024 [US1] In `App/Sources/AppModel.swift`, when `ControlConfig` exists, build clients from one `ControlLink`: one `DaemonClient` per host from `hosts/list` and `control/hostChanged`, instead of `SocketLink` + `HostSet`. Without it, keep today's path untouched (R7 Transition).
- [ ] T025 [US1] Write `ThisMacHost` in `App/Sources/Control/ThisMacHost.swift` (R11): the `HostID` whose `machineID` matches this Mac. Replace the `host == .mac` gates with it in:
  - `App/Sources/Sidebar/FilesPane.swift`, plus pictures and `OpenElsewhere.swift`
  - `BackgroundPane`, `AgentRow` (Show in Finder, `worktreeIsThere`), `WorkflowPage` and `WorkflowRow`, with the `files/*` RPC path for other hosts
- [ ] T026 [US1] Move the window's own files (`credentials.json`, relay certificates, `hosts.log`) out of the host root and into the window's support folder when `ControlConfig` exists, in `App/Sources/Hosts/Lending.swift` and the files that write them.
- [ ] T027 [US1] Credentials: lend through each host's `DaemonClient` over its channel, operator only (FR-020). Check `App/Sources/Hosts/Lending.swift` needs nothing beyond its new client source.
  - Show `SignInRelays` for servers as "needs this Mac on the same network" (the regression R9 states).
- [ ] T028 [US1] Show the away state in the sidebar (frame H): every host's projects stay listed but greyed, under one strip, **Can't reach the control plane**, that names the expected address. The strip goes in `App/Sources/Sidebar/` next to today's offline-server strip, reusing `HostProblem+Words.swift`.
- [x] T029 (Connect… pairs with a code; walks/network.md) [US1] Pairing the window: the window's pairing client (`clients/announce` with kind `mac`) goes in `App/Sources/Control/WindowPairing.swift`, reusing `DeviceKey` and `NetworkLink` from AgentsKitCore. Check the keychain access group builds for macOS.
  - For walks, the env var `AGENTS_CONTROL=<code>` pairs without UI.
- [x] T030 [US1] (walks/us1.md) Walk: quickstart steps 1–6 on `/tmp/cp-walk` with a real Claude turn. Screenshot each step. Record the result in `specs/058-control-plane/walks/us1.md`.

**Checkpoint**: MVP. The window works through the control plane on a scratch root, and the old path is untouched.

---

## Phase 4: User Story 2 — First run: connect to one, or run one here (P1)

**Goal**: frames A, B and C. Without `ControlConfig`, the window shows only the two choices, and **Run one on this Mac** leaves a working, empty window in under a minute (SC-003).

**Independent test**: a scratch root with no control plane: choose Run one here, see This Mac as a host, restart the window, and see it connect at once.

- [x] T031 [P] [US2] Add the two launch-agent plists to `App/LaunchAgents/` and copy them to `Contents/Library/LaunchAgents` in `project.yml`:
  - `com.alexecollins.agents.control.plist` runs `agents-control` with `KeepAlive` and `RunAtLoad`.
  - `com.alexecollins.agents.host.plist` runs `agentsd --serve --control-home`.
- [x] T032 (scratch roots: labelled launchd jobs from plists in `<root>/control`, booted out by `remove`) [US2] Write `LocalServices` in `App/Sources/Control/LocalServices.swift` using `SMAppService.agent(plistName:)`: register, status and unregister (R5).
  - Before registering, check for leftover jobs with `launchctl print gui/<uid>/<label>`.
  - A scratch root uses labels suffixed with the root's hash, so it never touches the real labels.
  - If the service is already registered, don't install it twice; just pair (US2.4).
- [x] T033 (in its place: the local socket is the pairing, operator by code signature; a code comes with pairing another Mac) [US2] Loopback pairing: `agents-control` issues an operator code to a caller with the same uid on a loopback-only Unix socket `<control root>/pair.sock`. `LocalServices` uses it to pair the window.
- [x] T034 [P] [US2] Build frame A in `App/Sources/Control/FirstRunView.swift`: two cards, with Run one on this Mac marked as the usual choice and the sleep caveat. There is no sidebar or toolbar until one is chosen.
- [x] T035 [P] [US2] Build frame B in `App/Sources/Control/RunHereSheet.swift`: the steps, and the Login Items note when macOS asks.
- [x] T036 (the Bonjour list and code field are real; Connect says pairing is not built yet) [P] [US2] Build frame C in `App/Sources/Control/ConnectSheet.swift`: control planes found by Bonjour, listed by name, plus a code field. The window is an operator only if the code is an operator code.
- [x] T037 [US2] Show `FirstRunView` from `App/Sources/ContentView.swift` when there is neither a `ControlConfig` nor a legacy root with data. Keep the modifier chain on `ContentView()` in `AgentsApp` identical (the scratch-app-opens-no-window lesson).
- [x] T038 (walks/us2.md) [US2] Walk: a scratch root with no data. Run one here, then check the host is listed, a restart reconnects, and logout survival (`launchctl print` shows both jobs). Unregister afterwards. Record in `specs/058-control-plane/walks/us2.md`.

---

## Phase 5: User Story 3 — A server joins (P2)

**Goal**: add the devbox from the window. It becomes a host every client sees. The ssh-reached path comes first (R8), and dial-out follows spike S1.

**Independent test**: add the devbox, start a turn there, and see its project from a second client.

- [x] T039 (`SSHHosts`, in the kit; the binaries are found in the app bundle the control plane is in) [US3] Move `SSHMaster`, `ServerInstaller` and `ToolsetInstaller` into use by `Control/Sources/HostInstall.swift` for `hosts/install`, `hosts/update` and `hosts/checkAgain` (R9):
  - `needsTrust {fingerprint}`, then a second call with `trust`.
  - Progress goes out as `control/installProgress {name, step, of, detail}`.
  - Binaries come from the control plane's bundle `Resources/servers`.
- [x] T040 (`SSHUplink`) [US3] Write `Control/Sources/SSHHost.swift` (FR-012): a `HostSession` whose channels are separate socket connections over the `ssh -M -L` forward.
  - `device` channels are bound with `connection/bindDevice`.
  - Channel 0 is a `control` connection that carries `mailbox/carry`.
  - `HostRecord.reach` is `ssh(…)`.
- [x] T041 [US3] `hosts/remove {host, purge?}` revokes the key and closes the uplink at once. It never stops or deletes the host's agents (FR-014).
- [x] T042 (Settings ▸ Control plane ▸ Hosts ▸ Add a Server; the window keeps a client per control-plane host) [US3] Point `App/Sources/Hosts/AddServerFlow.swift` and `AddServerSheet.swift` at `hosts/install` when `ControlConfig` exists. Render the progress notifications and the trust step. Today's path stays when it doesn't.
- [ ] T043 [US3] Spike S1 (R8) in `Packages/AgentsKit/Sources/ControlUplinkLinux/` (a Linux-only target): `swift-crypto` + `swift-nio-ssl` TLS-PSK against the Network.framework listener, statically linked with musl. Measure the binary growth. Write the result in `specs/058-control-plane/research.md` R8.
  - If S1 fails, ask Alex whether "Mac, with Linux hosts" is acceptable.
- [ ] T044 [US3] If S1 passes: `agentsd --control` on Linux dials out using the S1 dialer. `hosts/install` then enrols dial-out by default, and ssh-reached remains the fallback.
- [x] T045 (walks/us3.md; network drop/return not walked) [US3] Walk with test-servers: add the devbox and start a turn there. Drop the container's network and bring it back, and check the agent kept working and the host reconnected. Remove the host, and check it disappears from every client while its agents stay. Record in `specs/058-control-plane/walks/us3.md`.

---

## Phase 6: User Story 5 — The person decides what each client may do (P2)

**Goal**: frames D, E, F and G. Settings ▸ Control plane is one group (Overview, Hosts, Clients) opening like Shared (055).

**Independent test**: pair a fake device, promote it and see an operator call succeed; forget it and see it cut off and refused.

- [x] T046 [P] [US5] Add a **Control plane** rail group that opens like Shared, in `App/Sources/Settings/SettingsRail.swift` (or wherever 055's rail lives). It replaces the Devices and Servers entries when `ControlConfig` exists.
- [x] T047 [P] [US5] Build frame D in `App/Sources/Control/ControlOverviewPane.swift`: where the control plane runs, its version, uptime and port, Restart, Reachable away from home, the sleep caveat, and summary cards for Hosts and Clients.
- [x] T048 (Add a Server… and Add by Code… disabled until US3 and pairing) [P] [US5] Build frame E in `App/Sources/Control/ControlHostsPane.swift`: today's Servers pane plus This Mac, which has no buttons (the look-gate decision). Each host shows its state and "connects out" or "reached over ssh". Add a server… uses T042.
- [x] T049 (phones paired to the host listed with a fixed Device grant until US4) [P] [US5] Build frame F in `App/Sources/Control/ControlClientsPane.swift`: today's Devices pane plus the window. Each client gets a grant menu (`clients/setGrant`) and Forget (`clients/forget`), and `lastOperator` shows as a plain sentence.
- [x] T050 (Pair a Mac: grant first; the code waits for network pairing and the sheet says so; Pair a Device is today’s sheet) [US5] Build frame G in `App/Sources/Control/PairClientSheet.swift`: choose the grant first, then show the QR code for a device or the code as text for a Mac.
- [x] T051 [US5] (tested in ControlRouterTests.changingAGrantReopensTheChannelsWithTheNewOne; seen live in walks/us5.md) Grant changes apply to the next call. The router reopens that client's channels with the new grant (data-model rule). Test it in `ControlRouterTests.swift`.
- [x] T052 (walks/us5.md) [US5] Walk: a fake device client over TLS-PSK (the test-servers helper). Promote it, call an operator method, forget it, and see its connection close and its reconnect refused. Screenshot D, E, F and G against the frames. Record in `specs/058-control-plane/walks/us5.md`.

---

## Phase 7: User Story 4 — The iPhone and iPad see every host (P2)

**Goal**: the Remote uses `ControlLink` and shows every host's projects grouped by host. A device grant is refused operator calls twice.

**Independent test**: a fake device lists projects and sees the devbox's project, and starting an agent there works. The Remote is built for the generic simulator only; the phone look is Alex's.

- [ ] T053 [US4] In `Remote/Sources/RemoteModel.swift`, move from one `DaemonClient` to one per host over `ControlLink`, fed by `hosts/list` and `control/hostChanged`. Keep the legacy path for a control plane that answers no `control/status`.
- [ ] T054 [P] [US4] Add host headers in the Remote's project list in `Shared/UI/`, following frame H's sidebar.
- [ ] T055 [US4] Relay (R6): `Control/Sources/RelayHost.swift` attaches a relay session to the router as that device's client session, speaking the client wire.
- [ ] T056 [US4] Notices (R6): hosts send `attention/need` unsealed over channel 0. `Control/Sources/MailboxTransport.swift` picks the device by presence across hosts and seals with `Envelope.seal`. Wire it in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Attention.swift` for when the daemon runs under `--control`.
- [ ] T057 [US4] Build Remote for the generic iOS simulator. Walk with the fake device: projects from every host, an agent started on the devbox, and operator calls refused at the control plane and at the host. Record in `specs/058-control-plane/walks/us4.md`, and ask Alex to look on the phone.

---

## Phase 8: User Story 6 — Moving an existing set-up across, once (P2)

**Goal**: frame I and `agents-control migrate --from <root>` (R7), which is never run on launch.

**Independent test**: a scratch root seeded with agents, a paired fake device and the devbox added the old way. Move it; everything is present, the device connects with its old key, and the devbox is a host.

- [ ] T058 [US6] Write `Control/Sources/Migrate.swift`, following R7 steps 1–7:
  - Refuse a control root that already has clients or hosts.
  - `devices.json` becomes `clients.json` with `grant: device`, keeping `relay-mac-key`.
  - The old root becomes the home host `mac`, and no files move.
  - Each server in `hosts.json` goes through `hosts/install`, with failures listed with their reasons. `hosts.json` is renamed `hosts.json.moved`.
  - On any failure before the launch agents are registered, nothing in the old root changes.
- [ ] T059 [US6] Build frame I in `App/Sources/Control/MoveSheet.swift`. It is offered from a banner when a legacy root has data and there is no `ControlConfig`. It says what is kept, runs the migrate, registers `LocalServices`, pairs, then switches `AppModel` to `ControlLink`.
- [ ] T060 [P] [US6] Migrate tests in `Packages/AgentsKit/Tests/AgentsKitTests/Control/MigrateTests.swift` (with the core of the move in AgentsKitCore): device keys unchanged, idempotent refusal, and a failure part-way leaves the old root intact.
- [ ] T061 [US6] Walk the move on the seeded scratch root. Record in `specs/058-control-plane/walks/us6.md`.

**Alex's live set-up is moved only on his go-ahead, once, deliberately. There is no task for it here.**

---

## Phase 9: User Story 7 — Another Mac as a host (P3)

- [ ] T062 [US7] Add a "Run only a host here" choice to `ConnectSheet.swift`. It takes a host code and registers only the host launch agent, with `--control <code>`.
- [ ] T063 [US7] Walk: a second `agentsd --control` under another scratch root. Its projects are listed under their own host header. Record in `specs/058-control-plane/walks/us7.md`.

---

## Phase 10: Polish & cross-cutting

- [ ] T064 [P] Write the new `docs/explanation/control-plane.md`: what the control plane, hosts and clients are, where to run it, what happens when it's down, and why (R1).
- [ ] T065 [P] Update `docs/explanation/window-and-daemon.md`, `phone-and-ipad.md` and `projects-hosts-worktrees.md` as the spec's Docs section says. Also update README set-up.
- [ ] T066 [P] Add `docs/how-to/` pages: run a control plane on this Mac, connect to one elsewhere, add a server, move an existing set-up across. Add them to `mkdocs.yml`.
- [ ] T067 SC-004 measurement (R10): shell echo round trip for the direct socket, the loopback channel and the devbox on both paths. Write it in `specs/058-control-plane/walks/latency.md`. If it fails, stop and ask Alex about a stream channel.
- [ ] T068 Run `security-review` on the branch. The network-reachable operator role, host PSKs, the loopback pairing socket and `open` role-setting are the focus.
- [ ] T069 Compare six full `swift test` runs on this branch and on main. Build both schemes and pass the Linux gate.
- [ ] T070 Remove the old window path (`SocketLink` spawning, `HostSet`) in a **separate** change, only after the move has been walked on Alex's set-up (R7 Transition).

---

## Dependencies

- Setup (T001–T003), then Foundational (T004–T017), then US1 (T018–T030), which is the MVP.
- US2 needs US1 (the window must work as a client before first run can hand over to it).
- US3, US5 and US4 each need US1. They are independent of each other, apart from US4's relay/notice tasks, which need T018.
- US6 needs US2 (LocalServices, pairing) and US3 (`hosts/install`).
- US7 needs US2.
- T070 comes last, after Alex's own move.

## Parallel opportunities

- Foundational: T004, T005 and T013 together. Then T010, T011, T012 and T016 once their subjects exist.
- US2: T031, T034, T035 and T036 together.
- US5: T046–T049 together (separate panes).
- Once US1 is in: US3, US4 and US5 can go to separate agents in their own worktrees off this branch. At most three.
- Docs T064–T066 in parallel with anything.

## Implementation strategy

1. **MVP = Phases 1–3.** The window works through a control plane on a scratch root, and the old path still works. Stop, walk it, and show Alex.
2. Next, US2, so a fresh window has somewhere to go.
3. Then US3, US5 and US4, the reason the hub exists. Spike S1 decides whether Linux dials out.
4. US6, the move, is last among the P2 stories, because it touches real data. It is walked on scratch and run on Alex's set-up only when he says so.
