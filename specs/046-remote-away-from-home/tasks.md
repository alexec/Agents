---
description: "Tasks for 046 Remote Works Away From Home"
---

# Tasks: Remote Works Away From Home

**Input**: `specs/046-remote-away-from-home/` — plan.md, spec.md, research.md (R1–R13), data-model.md,
contracts/relay.md, contracts/daemon.md, contracts/ui.md, quickstart.md

**Tests**: Yes. The plan asks for them, and every lane in this repo writes them. The suites go in
`Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration}/`. Assert properties directly, and
never by mutating source (memory).

**Look gate**: already passed. Alex approved `look/away-mock.png` on 2026-09-25, so there is no
look phase. US4 builds to that mock.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no unfinished dependency)
- **[Story]**: US1–US5 from spec.md

---

## Phase 1: Setup

- [X] T001 Merge current `main` into `agents/ios-works-when-not`, resolve any conflicts, and confirm both schemes (`Agents`, `Remote`) and `agents-bridge` build with `-skipPackagePluginValidation`, one after another
- [X] T002 Record the baseline: three full `swift test --package-path Packages/AgentsKit` runs on this merge, listing the failures that are main's own flakes, in `specs/046-remote-away-from-home/walk/baseline.md`
- [X] T003 [P] Create the empty folder `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Relay/`, with every file in it under `#if canImport(CloudKit)` (and `canImport(CryptoKit)` where it seals), so the Linux `agentsd` build is untouched. Check with the Linux gate build 037 uses

---

## Phase 2: Foundational (blocks every story)

**Purpose**: the frame format, sealing, ordering and the channel abstraction, plus the Mac key and
pairing that every relayed frame needs (US5's pairing half lives here because nothing works without it).

### Spike (research R13) — first; if it fails, take R3's fallback before going on

- [X] T004 *(Done differently: the enclave check ran on this Mac's Secure Enclave, and passed both ways; see research R13. The phone confirms it on first use, in T006.)* Add a `-spike-relay` launch argument to `Remote/Sources/RemoteApp.swift`. It loads the device's `DeviceKey` (Secure Enclave on hardware), seals a test plaintext with `HPKE.Sender(recipientKey:ciphersuite: .P256_SHA256_AES_GCM_256, info:, authenticatedBy: <SE key>)` to a software P256 key, opens it with `HPKE.Recipient(…, authenticatedBy: <SE public key>)`, and prints pass or fail to the console and the screen
- [X] T005 *(Done as `agents-bridge --spike-relay`: both ends in one process through the real iCloud. Median 2.57 s, worst 2.90 s; see research R13.)* Add `--spike-relay` to `Bridge/Sources/main.swift` (beside `--spike`): create zone `relay-SPIKE` in the private DB, then 10 times write a `Frame` record, poll with `CKFetchRecordZoneChangesOperation` until the phone's reply record appears, and print each round-trip time and the worst. Add the matching phone half to T004's `-spike-relay`: fetch every 1 s, and write the reply
- [ ] T006 **Alex's phone, Wi‑Fi off.** Run T004 and T005 (install per the real-devices memory, and ask first). Record the SE result and the ten times in `research.md` R13. If SE auth-mode fails, change R3 to the fallback (a software signing key in the shared keychain group) and note it in `data-model.md`

### Frames and sealing

- [X] T007 [P] Write `Frame` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Relay/Frame.swift`: `session: UUID`, `direction: .toMac | .toDevice`, `seq: Int64`, `lines: [String]`, `end: Bool`. Add `seal(to recipient: Data, from sender: some HPKEDiffieHellmanPrivateKey) -> Data` and `open(_:with: some HPKEDiffieHellmanPrivateKey, from senderPublic: Data, session:direction:seq:)`, exactly per contracts/relay.md § Sealing: info `"com.alexecollins.agents.relay.v1"`, aad = session(16) ‖ direction(1 byte: 0 toMac, 1 toDevice) ‖ seq(8, big-endian), plain = zlib(JSON {lines, end}), sealed = encapsulatedKey(65) ‖ ciphertext. Reuse `Envelope.suite`
- [X] T008 [P] Write `FrameSealingTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/FrameSealingTests.swift`: a round trip; the wrong recipient key fails; the wrong claimed sender fails; a changed `seq`, `session` or `direction` fails; the sealed bytes contain none of the plaintext lines (SC-005); compression shrinks a 1 MB `agents/list`-shaped JSON
- [X] T009 [P] Write `FrameOrder` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Relay/FrameOrder.swift`: `accept(_ frame) -> [Frame]` returns frames in `seq` order, drops a `seq` below the next expected one, holds higher ones, and reports `gapExpired` when a held gap is older than **10 s** (injected clock)
- [X] T010 [P] Write `FrameOrderTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/FrameOrderTests.swift`: in order, reversed, duplicated, gap filled late, gap expiring at 10 s
- [X] T011 [P] Write `LineBatcher` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Relay/LineBatcher.swift`: it emits a batch **400 ms** after the first waiting line, or when the waiting lines reach **256 KB**, whichever is first. It has an injected clock and a `flush()`
- [X] T012 [P] Write `LineBatcherTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/LineBatcherTests.swift`: one line waits 400 ms; a burst makes one batch; 300 KB splits at 256 KB; flush

### Channel

- [X] T013 Write the `RelayChannel` protocol and `FakeRelayChannel` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Relay/RelayChannel.swift`. The protocol has `ensureZone(device:)`, `post(device:, record: FrameRecord)`, `fetchChanges(device:) -> [FrameRecord]`, `changedDevices() -> [UUID]`, `delete(device:, names:)`, `deleteZone(device:)` and `sweep(olderThan:)`. `FrameRecord` has the data-model fields (`session`, `direction`, `seq`, `sealed`, `asset` over **700 KB**, `sentAt`; name `<session>/<direction>/<seq>`). The fake can be told to reorder, duplicate, delay, throw a retry-after of N seconds, or report a zone gone
- [X] T014 Write `CloudKitRelayChannel` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Relay/CloudKitRelayChannel.swift`, over `CKContainer(identifier: CloudKitMailbox.containerID).privateCloudDatabase`:
  - zones are `relay-<UUID uppercase>`, and records are type `Frame`, saved with `savePolicy: .allKeys`;
  - a frame over 700 KB is written to a temp file as a `CKAsset`;
  - changes come from `CKFetchDatabaseChangesOperation` and `CKFetchRecordZoneChangesOperation`, with server change tokens kept in `UserDefaults` scoped by root/device;
  - `CKError.retryAfterSeconds` is surfaced as `RelayChannelError.slowDown(seconds)`, `zoneNotFound`/`userDeletedZone` as `.zoneGone`, and `quotaExceeded` as `.full`;
  - deletes go in batches of ≤ 400.
- [X] T015 [P] Write `RelayChannelContractTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/RelayChannelContractTests.swift`, pinning `FakeRelayChannel` to the rules the real channel must keep: a same-name post replaces rather than adds; fetch returns only new records; delete; sweep by `sentAt`

### The Mac key and pairing (contracts/daemon.md)

- [X] T016 Add to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`:
  - the method names `relay/register` and `devices/forget`;
  - `RelayRegistration { publicKey: Data }`;
  - an optional `macKey: Data?` on the `devices/announce` reply, as a wrapper that decodes as `Device` plus `macKey`, so old phones still decode it;
  - `DeviceNotification` gains `removed: Bool?`, and `device` becomes optional;
  - `Failure.notAllowed = -32060`.
- [X] T017 Add a top-level `relayKey` to the daemon's device store in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Devices.swift`, and handle it in `DaemonCore+Dispatch.swift`:
  - `relay/register` stores it, refusing with `invalidParams` any key that is not 65 bytes starting `0x04`;
  - `announce` returns `macKey` when one is stored;
  - `devices.json` keeps the key across restarts and keeps unknown fields.
- [X] T018 [P] Write `RelayPairingTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/RelayPairingTests.swift`: register then announce returns `macKey`; no register means no `macKey`; a bad key is refused; the key survives a daemon restart; an old-shape announce reply decodes on a `Device`-only client
- [X] T019 *(The key is registered on RelayHost's own daemon connection, not the mailbox's.)* Make the bridge's key in `Bridge/Sources/RelayHost.swift` (new file, key part only): `DeviceKey.load(account: "relay-mac-key", accessGroup: nil)` (the software path), plus a `register(on client: DaemonClient)` that calls `relay/register`. Call it from `MailboxTransport.run()` in `Bridge/Sources/MailboxTransport.swift`, right after `mailbox/carry`, on every reconnect
- [X] T020 On the phone, in `Remote/Sources/RemoteModel.swift` `announce()`, decode the reply's `macKey` and keep it in the shared keychain group (account `relay-mac-key-public`, `DeviceKey.sharedAccessGroup`). Expose `macKey: Data?`, loaded at launch

**Checkpoint**: a phone connecting on Wi‑Fi to a bridge from this branch ends up holding the Mac's key.
Frames seal, open, order and batch in tests.

---

## Phase 3: User Story 1 — Answer an agent from anywhere (P1) 🎯 MVP

**Goal**: away from home, a paired phone opens an agent and answers a permission or question, and
the Mac acts on it.

**Independent Test**: phone on mobile data, paired; an agent on the Mac asks a permission; Allow on
the phone; the agent proceeds within ~3 s (spec US1).

- [X] T021 [US1] Write `RelayTransport: LineTransport` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Relay/RelayTransport.swift`, the device end of one session. It is made with `(channel, device: UUID, deviceKey, macKey, clock)` and a new `session` UUID, and follows contracts/relay.md § Session:
  - `write(line:)` posts a one-line `toMac` frame with the next `seq`;
  - a fetch loop every **1 s** (and on `poke()`, for pushes) opens `toDevice` frames with the device key from the Mac key, runs them through `FrameOrder`, yields their lines, and deletes delivered records;
  - a keep-alive frame with no lines goes after **30 s** of silence;
  - `close()` sends `end: true`;
  - the stream finishes on the Mac's `end`, on `gapExpired`, or on `.zoneGone`, and `.slowDown(s)` pauses for `s`.
- [X] T022 [US1] Write `RelayHost` sessions in `Bridge/Sources/RelayHost.swift`:
  - it polls `changedDevices()` every **1 s** while any session was live in the last 2 min, and **5 s** otherwise;
  - it keeps the paired devices from `devices/list`, updated by `device/changed`, on its own `DaemonClient`;
  - for each device zone with a new `session`, it opens `SocketLink().transport()` and pipes lines both ways: device frames go through `FrameOrder` and are written to the daemon, and daemon lines go through `LineBatcher` into sealed `toDevice` frames;
  - it drops frames that don't open with that zone's device key, ends a session after **2 min** of silence or on `end`, and deletes delivered records;
  - it honours `.slowDown`.

  Put the pure session logic (frames in → lines out, lines in → frames out) in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Relay/RelaySessionHost.swift` so it can be tested, and keep only the CloudKit and socket wiring in the bridge.
- [X] T023 [US1] Start `RelayHost` in `Bridge/Sources/main.swift` beside `MailboxTransport`, with the same `AGENTS_BRIDGE_NO_MAILBOX` switch-off, and log "relay: carrying for N devices". Update the file's header comment: the relay is sealed, the LAN listener still is not (D5)
- [X] T024 [US1] Write `RelayEndToEndTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/RelayEndToEndTests.swift`: `DaemonClient(link:)` over a `RelayTransport` → `FakeRelayChannel` → `RelaySessionHost` → an in-process daemon on a scratch root (use the harness the other Integration suites use). It asserts that `ping` works; that `permissions/pending` lists a pending permission and `permissions/answer` with a `sendID` resolves it; that `elicitations/answer` resolves a question; and that a frame from an unpaired key is ignored and gets no answer (FR-008)
- [X] T025 [US1] Write a first `LinkChooser: DaemonLink` in `Packages/AgentsKit/Sources/AgentsKitCore/Remote/Relay/LinkChooser.swift`:
  - `transport()` races `NetworkLink(howLongToLook: 2s)` against a `RelayTransport` whose first `ping` answers, preferring direct if it is ready within **2 s**;
  - it throws `.notPaired` when there is no `macKey`;
  - it publishes `link: .direct | .relayed | .none` through an `AsyncStream`.

  Hand-over back to direct comes in US3.
- [X] T026 [US1] Use `LinkChooser` in place of `NetworkLink()` in `Remote/Sources/RemoteApp.swift:24` (keep `-fake`). Mirror its `link` into `RemoteModel.link` and `RemoteModel.isAway` in `Remote/Sources/RemoteModel.swift`, and give the chooser the device key and `macKey`
- [X] T027 [US1] On the phone, add a `CKRecordZoneSubscription` for `relay-<deviceID>` (silent, `shouldSendContentAvailable`, subscription id `relay-<deviceID>`) beside the existing `subscribeOnce()` in `Remote/Sources/RemoteModel.swift`. In `Remote/Sources/Notifications/PushDelegate.swift`, route a push for that subscription to `RelayTransport.poke()`, not to the mailbox path
- [ ] T028 [US1] Build `agents-bridge` and `Remote`, run the bridge on a scratch root (`AGENTS_ROOT=/tmp/run-046 AGENTS_BRIDGE_PORT=8791`), and walk US1 on Alex's phone with Wi‑Fi off (quickstart § 3, "Pair" and "Answer"). Record the times in `specs/046-remote-away-from-home/walk/README.md`. **Alex's hands.**

**Checkpoint**: MVP. A permission can be answered from mobile data.

---

## Phase 4: User Story 2 — Carry on a conversation away (P1)

**Goal**: projects, agents, chat that follows as it grows, sending prompts, and start, stop and
archive, all over the relay.

**Independent Test**: away, open an agent, send "list the files in this folder"; the full reply
matches the Mac window (spec US2).

- [X] T029 [US2] Add `sendID: UUID()` to the phone's `agents/prompt` in `Remote/Sources/RemoteModel.swift` `send(_:attachments:to:)` (the daemon's `once(sendID)` already dedups it, R9)
- [X] T030 [P] [US2] Extend `RelayEndToEndTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/RelayEndToEndTests.swift` with:
  - an `agents/list` of ≥ 5 MB arriving whole (it goes as an asset);
  - 200 `agent/entry` notifications arriving in order with no duplicates while the fake reorders and duplicates;
  - the same prompt `sendID` posted twice giving one prompt;
  - `agents/start` with a `requestID`, then `agents/stop` and `agents/archive`, taking effect.
- [X] T031 [US2] Check the Mac's batching rate in `RelayEndToEndTests`: a simulated busy turn (50 entries a second for 10 s) posts **≤ 3 frames a second** to the channel
- [ ] T032 [US2] Walk US2 on Alex's phone away (quickstart "Send"): project list and agents within 5 s (SC-002); reply text ≤ 3 s behind the Mac (SC-003). Record in `specs/046-remote-away-from-home/walk/README.md`. **Alex's hands.**

---

## Phase 5: User Story 3 — Moving between home and away without noticing (P1)

**Goal**: the link changes by itself both ways within 10 s, with nothing lost or sent twice.

**Independent Test**: with a chat open, turn Wi‑Fi off, send, turn it on; the mark follows, the
prompt arrives once, and there is no gap (spec US3).

- [X] T033 [US3] Coming home, in `LinkChooser`: while `link == .relayed`, keep an `NWBrowser` on `NetworkLink.serviceType`. When the Mac appears and an `NWTransport` is ready and answers `ping`, close that probe and the current `RelayTransport`, so `RemoteModel`'s existing `lostTouch()` → `connect()` path reconnects and wins direct (R8)
- [X] T034 [US3] Leaving home, in `RemoteModel`: while `link == .direct`, send `ping` every **5 s** with a **3 s** deadline. A miss closes the client's connection, so `lostTouch()` → `connect()` falls to the relay (SC-004 ≤ 10 s)
- [X] T035 [US3] Add `sendOnce(_ method:, params:)` to `Remote/Sources/RemoteModel.swift`. It calls; if the call fails with `JSONRPCTransportError.closed` it awaits `connect()` and calls **once more with the same params** (so the same `sendID`/`requestID`). Use it for prompt, `permissions/answer`, `elicitations/answer`, `agents/start`, `agents/stop` and `agents/archive` (FR-003)
- [X] T036 [P] [US3] Write `LinkChooserTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/LinkChooserTests.swift`, with fake direct and relay links: direct within 2 s wins; direct late gives the relay; the relay gives way to direct when the Mac appears; neither answering throws; no `macKey` gives `.notPaired` with nothing posted (FR-009)
- [X] T037 *(This test is in `RelayCarryingTests`, because `SendOnceTests` already exists as 037's.)* [P] [US3] Write `SendOnceTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/SendOnceTests.swift`: a prompt whose connection closes mid-call is carried out exactly once after reconnecting over the other transport, across 10 forced changes (SC-004)
- [ ] T038 [US3] Walk US3 on Alex's phone (quickstart "Leave" and "Switch mid-send"), and record the link-change times in `specs/046-remote-away-from-home/walk/README.md`. **Alex's hands.**

---

## Phase 6: User Story 4 — Knowing what works away (P2)

**Goal**: the Away line on every screen, and the approved "needs the same network" states (look A, B).

**Independent Test**: away, try Files, Terminal, Page and attach; each shows the state and none
spins; coming home makes them live by themselves (spec US4).

- [X] T039 [P] [US4] Draw the Away rows in `Remote/Sources/StaleBanner.swift`, per contracts/ui.md § The line, in its order of precedence:
  - "**Away** — slower, through iCloud" (`icloud`, "Away" in the accent colour);
  - "**Away** — slower than usual" when slowed down;
  - "The relay needs iCloud on your iPhone and your Mac" / "iCloud is full, so the relay can't carry messages" (`icloud.slash`).

  One accessibility element per row (stacked-labels memory).
- [X] T040 [P] [US4] Write `NeedsSameNetworkView` in `Remote/Sources/Panes/NeedsSameNetworkView.swift`, with the exact words from contracts/ui.md § Files, Terminal, Page: the ⌂ glyph, "Needs the same network as your Mac", and the body text. Use "phone" on iPhone and "iPad" on iPad
- [X] T041 [US4] In `Remote/Sources/Panes/FilesPane.swift`, `TerminalPane.swift` and `PagePane.swift`, show `NeedsSameNetworkView` when `model.isAway`, with no `files/watch` and no shell open. Key the real view's `.task(id:)` on `model.link`, so it opens by itself when the link becomes direct (FR-012)
- [X] T042 [US4] Disable the paperclip away in `Remote/Sources/Chat/PromptBar.swift` (dimmed; the VoiceOver label is "Attach, needs the same network as your Mac"), and the attachments row in `Remote/Sources/StartAgent/StartAgentView.swift`
- [X] T043 [US4] Map relay trouble to `RemoteModel` state in `Remote/Sources/RemoteModel.swift`: `.slowDown > 3 s` gives `relaySlowed`, `CKAccountStatus` other than `.available` gives `relayNeedsICloud`, and `.full` gives `relayFull` (FR-014)
- [ ] T044 [US4] Build `Remote` for the generic simulator (no sim is booted; see the memory) and on Alex's phone, and walk quickstart "Away-only" (SC-006). Put screenshots in `specs/046-remote-away-from-home/walk/` and compare them against `look/away-mock.png`. **Alex's hands.**

---

## Phase 7: User Story 5 — Pairing once, at home; forgetting (P2)

**Goal**: a never-paired device is told what to do and writes nothing, and a forgotten device is
refused within a minute. (Pairing itself is in Phase 2.)

**Independent Test**: a fresh install away shows the never-paired card; Forget on the Mac stops it
within a minute (spec US5).

- [X] T045 [US5] Handle `devices/forget` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Devices.swift` and `DaemonCore+Dispatch.swift`: remove the record, then broadcast `device/changed {id, removed: true}`. Forgetting an unknown id returns `{}`, and a connection that identified as a device is refused `notAllowed` (-32060)
- [X] T046 *(These tests are in `RelayPairingTests`.)* [P] [US5] Write `DeviceForgetTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/DeviceForgetTests.swift`: the record is gone and the broadcast carries `removed`; forgetting twice is `{}`; a device connection is refused; re-announcing afterwards pairs again (D1)
- [X] T047 [US5] In `RelayHost`/`RelaySessionHost`, on `device/changed removed`, end that device's sessions and call `deleteZone(device:)`. Extend `RelayEndToEndTests`: after forget, frames from that device are carried out 0 times (SC-007)
- [X] T048 [US5] On the phone, handle `.zoneGone` in `RelayTransport` by finishing with `RelayError.forgotten`. `RemoteModel` then clears `macKey` from the keychain and shows the never-paired state. `LinkChooser` never calls `ensureZone` without a `macKey`
- [X] T049 [P] [US5] Write the never-paired card (look C) as the project list's empty state in `Remote/Sources/Projects/ProjectListView.swift`, shown when away with no `macKey`: "Open Agents once on your Mac's Wi-Fi", with the body text from contracts/ui.md
- [X] T050 [US5] Add **Forget…** to each row in `App/Sources/Settings/DevicesPane.swift`, with the confirmation text from contracts/ui.md. Add `forgetDevice(_:)` to `App/Sources/AppModel.swift`, calling `devices/forget`, and remove the row on `removed`
- [ ] T051 [US5] Walk quickstart "Forget" and "Re-pair" on a scratch Mac window (run-app skill) with the phone. **Alex's hands for the phone.**

---

## Phase 8: Polish & cross-cutting

- [X] T052 [P] Add the hourly sweep to `RelayHost`: `sweep(olderThan: 24h)` across every `relay-*` zone (FR-017)
- [X] T053 [P] Update `docs/explanation/phone-and-ipad.md` ("Two ways to reach you", "The connection today": the relayed link, pairing at home, what works away, why it is slower), `docs/tutorials/follow-from-iphone.md` (a closing step with the Away mark), and `docs/reference/statuses.md` (the phone's link states). Then run `python3 scripts/docs-check.py`
- [ ] T054 [P] Look in the CloudKit Console (DEVELOPMENT, private DB, `relay-*` zones) during a walk and record in `walk/README.md` that only ids, numbers, dates and ciphertext are there (SC-005). **Alex's sign-in.**
- [X] T055 Merge current `main` in again, then build both schemes and the bridge, and run the Linux gate build. Run the full suite three times and compare with T002's baseline. Update the memory entry
- [ ] T056 Tell Alex the real bridge (8790) must be restarted onto this build for the relay to work day to day (live-bridge memory), and do it only when he says so

---

## Dependencies

- Phase 1 → Phase 2 (T004–T006 spike first; T007–T020) → US1 (MVP) → US2 → US3 → US4 → US5 → Polish.
- US2 and US4 depend only on US1. US3 depends on US1's `LinkChooser` (T025). US5's forget
  depends on T016–T017 and on the host in T022.
- Walk tasks (T028, T032, T038, T044, T051, T054) need Alex's phone, so batch them into as few
  sittings as possible, ideally one after US3 and one at the end.

## Parallel opportunities

- Phase 2: T007/T008, T009/T010, T011/T012 and T015 are independent files; T016–T018 (daemon)
  run alongside the frame work.
- US4's T039, T040 and T042 are separate view files, and can go alongside US3.
- T046 and T049 in US5; T052–T054 in Polish.

## Implementation strategy

1. The spike (T004–T006) settles R3 and SC-001's feasibility before anything else is built on it.
2. The MVP is US1: answering a permission from mobile data is the case that hurts today.
3. Then US2 and US3 make it a whole remote, and US4 and US5 make it honest and safe.
4. Commit per task group in this worktree. Never touch the main checkout, and merge only when
   Alex says so.
