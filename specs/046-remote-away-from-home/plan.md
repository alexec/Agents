# Implementation Plan: Remote Works Away From Home

**Branch**: `agents/ios-works-when-not` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/046-remote-away-from-home/spec.md`, with D1 confirmed
by Alex and D2–D5 taken as written. Look gate approved on `look/away-mock.png`.

**Numbering**: 046 is also the Gemini CLI spec on `agents/speckit-specify-support-gemini`. Whichever
merges second is renumbered; nothing here depends on the number.

## Summary

The phone already speaks JSON-RPC to the daemon through `agents-bridge`, and nothing above
`LineTransport` knows what carries the lines. This feature adds a second carrier, CloudKit, and a
chooser that picks between the two. It is 005's plan decision 1, built.

1. **A relayed `LineTransport` on the device.** `RelayTransport` turns lines into sealed,
   numbered **frames**, writes each as a record in a CloudKit zone of the device's own
   (`relay-<deviceID>`) in the private database, and reads the Mac's frames back out of the same
   zone. `DaemonClient`, `AgentsModel` and every screen are unchanged (R1, R5).
2. **The Mac's end lives in the bridge.** `RelayHost` in `agents-bridge` watches every device
   zone, and for each relayed session opens its own daemon connection over the Unix socket,
   exactly as `Relay` does for a LAN device. The daemon still has no network code and no
   CloudKit (R2).
3. **Sealed both ways, and signed by who sent it.** HPKE in authenticated mode: a device frame is
   sealed to the Mac's key and authenticated by the device's key; a Mac frame the reverse. The
   session id and frame number are the associated data, so a frame cannot be replayed into
   another session or out of order. The bridge opens nothing from a key that is not a paired
   device's (R3, FR-005, FR-008).
4. **The Mac gets a key.** The bridge makes a P256 key in the login keychain on first run and
   registers its public half with the daemon (`relay/register`). `devices/announce`, which only
   ever arrives over the direct link, returns it as `macKey`. That exchange is the pairing
   (D1, R4).
5. **Batching makes it affordable.** The bridge gathers a session's outgoing lines for up to
   400 ms, compresses them, seals them and posts **one** record. A reply over the inline limit
   goes as a `CKAsset`. The device sends requests at once. A busy chat is about 2–3 writes a
   second, well under CloudKit's per-user budget (R6).
6. **The Mac notices by polling, pushes are a bonus.** The bridge fetches database changes every
   second while a session is live and every 5 s otherwise. The phone has a zone subscription
   whose silent push triggers an immediate fetch, and while in the foreground it also polls every
   second. Everyone honours `retryAfterSeconds` (R7, FR-015, FR-018).
7. **`LinkChooser` picks the link.** It is a `DaemonLink` that races Bonjour against the relay
   and takes the direct link if it is ready within 2 s. While on the relay it keeps browsing,
   and when the Mac answers directly it closes the relayed transport, so `RemoteModel`'s existing
   lost-touch → reconnect path brings it back on the direct link. `RemoteModel.link` says which
   link is in use, and the screens read it (R8, FR-002, FR-013).
8. **Exactly once across a switch.** The phone's mutating calls — prompt, permission answer,
   question answer, start, stop and archive — carry the ids the daemon already dedups
   (`sendID`, `requestID`). A call that fails because the link closed is sent once more, with the
   same id, after reconnecting (R9, FR-003).
9. **Away is honest.** On the relay, Files, Terminal and Page show "Needs the same network as
   your Mac", and the paperclip is disabled. The "Away — slower, through iCloud" line replaces
   `StaleBanner`'s place. A device that is not paired shows "Open Agents once on your Mac's Wi-Fi"
   and writes nothing (R10, FR-009–FR-014, look gate).
10. **Forgetting a device.** `devices/forget` removes the record. The Devices pane in Settings
    gets a Forget button, the bridge drops that device's sessions and deletes its zone, and the
    phone hears `relayRefused` and says it is no longer paired. This reverses 021's "no
    revoking" note, because the spec's FR-008 needs it (R11).

See [research.md](research.md) for each decision, [data-model.md](data-model.md) for the records,
and [contracts/](contracts/) for the frame format, daemon methods and screens.

## Technical Context

**Language/Version**: Swift 6.x (strict concurrency), SwiftUI; iOS/iPadOS 27 and macOS 27, as today.

**Primary Dependencies**:
- AgentsKitCore (in-repo): `LineTransport`, `LineSplitter`, `DaemonClient`, `DaemonLink`,
  `NetworkLink`, `DeviceKey`, `Envelope`'s HPKE suite, `CloudKitMailbox`'s container and zone
  conventions.
- CloudKit (private database, container `iCloud.com.alexecollins.agents`, already entitled on
  the bridge and the Remote), CryptoKit HPKE, Apple's `Compression` (zlib, so both ends and
  tests agree).
- No new Swift packages, no new entitlements, and no server of ours.

**Storage**:
- CloudKit private DB: one zone per paired device, `relay-<deviceID>`, holding `Frame` records
  that are deleted once read, and swept after 24 h.
- Mac: the bridge's key in the login keychain (account `relay-mac-key`), its public half in the
  daemon root's `devices.json` under `relayKey` (so the daemon can hand it out without CryptoKit).
- Device: the Mac's public key beside its own key in the shared keychain group, so the
  notification extension could use it later.

**Testing**:
- `swift test` with `FakeRelayChannel`, an in-memory stand-in for the zone store that can
  reorder, duplicate, delay and throttle. The whole chain runs end to end in-process: device
  `RelayTransport` → fake channel → `RelayHost` → the real daemon on a scratch root.
- Unit suites cover frame sealing and opening (wrong key, wrong session, replay), `FrameOrder`
  (gaps, duplicates, out of order), the batcher's sizes and times, compression plus the
  asset threshold, `LinkChooser`'s race and handover, retry-once-with-the-same-id, and
  `devices/forget`.
- Live: a spike on Alex's phone for HPKE auth with a Secure Enclave key and for CloudKit round
  trips on cellular (research R13), then the quickstart walk.

**Target Platform**: The iPhone and iPad Remote, and the Mac `agents-bridge`. Linux `agentsd` is
untouched: everything new is under `#if canImport(CloudKit)` or lives in the bridge.

**Project Type**: The mobile app plus the Mac helper, with shared code in the kit.

**Performance Goals**: SC-001 (answer reaches the Mac in ≤ 3 s, 9 of 10), SC-002 (list in ≤ 5 s),
SC-003 (reply text ≤ 3 s behind the Mac), SC-004 (link change ≤ 10 s each way).

**Constraints**: CloudKit limits: 1 MB per record, 400 records per operation, about 40 requests
a second per user, throttling with `retryAfterSeconds`. Nothing legible in any record (FR-005).
The daemon gains no network code.

**Scale/Scope**: One Mac, a handful of devices, one relayed session per device at a time.

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so there are no gates to
check. The standing rules this plan keeps, from the repo and 005:

- **The daemon gains no listener and no network code.** Kept: CloudKit lives only in the bridge
  and the Remote.
- **The bridge parses no protocol.** Mostly kept: `RelayHost` batches and carries lines. The one
  thing it reads is the paired-device list, from its own daemon connection. It does not filter
  or rewrite the device's lines.
- **Same security model on both links (005 FR-004c).** Not met, by D5: the direct link stays
  unsealed, and sealing it is the security-review branch's work. Recorded under Complexity
  Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/046-remote-away-from-home/
├── spec.md
├── plan.md              # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── relay.md         # zones, Frame record, sealing, session rules
│   ├── daemon.md        # relay/register, devices/announce macKey, devices/forget
│   └── ui.md            # link states and what each screen does away
├── look/                # approved mock
└── checklists/requirements.md
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/Remote/Relay/
├── Frame.swift              # numbered batch of lines; seal/open (HPKE auth, AAD = session+seq)
├── FrameOrder.swift         # in-order delivery, duplicates dropped, gaps waited for
├── LineBatcher.swift        # up to 400 ms / 256 KB per frame
├── RelayChannel.swift       # protocol: post, fetchChanges, delete; FakeRelayChannel for tests
├── CloudKitRelayChannel.swift  # zones, Frame records, CKAsset over the inline limit, retry-after
├── RelayTransport.swift     # LineTransport for the device end of one session
└── LinkChooser.swift        # DaemonLink racing NetworkLink and the relay; publishes the link
Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift   # relay/register, devices/forget, macKey, relayRefused
Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Devices.swift  # relay key, forget
Bridge/Sources/RelayHost.swift   # Mac end: sessions → SocketLink, device check, sweeping
Bridge/Sources/main.swift        # starts RelayHost beside MailboxTransport
Remote/Sources/RemoteApp.swift   # LinkChooser instead of NetworkLink
Remote/Sources/RemoteModel.swift # link state, macKey from announce, retry-once, sendID on prompts
Remote/Sources/StaleBanner.swift # the Away line and the never-paired line
Remote/Sources/Panes/{FilesPane,TerminalPane,PagePane}.swift  # the "needs the same network" state
Remote/Sources/Chat/PromptBar.swift  # paperclip disabled away
App/Sources/Settings/DevicesPane.swift  # Forget
Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration}/Relay*Tests.swift
docs/explanation/phone-and-ipad.md, docs/tutorials/follow-from-iphone.md, docs/reference/statuses.md
```

**Structure Decision**: Everything that decides anything (frames, sealing, ordering, batching,
link choice) goes in AgentsKitCore, where `swift test` reaches it. The bridge and the Remote only
wire it up and draw it.

## Complexity Tracking

| Departure | Why needed | Simpler alternative rejected because |
|-----------|------------|--------------------------------------|
| The direct link stays unsealed while the relay is sealed (breaks 005 FR-004c) | D5: sealing the direct link belongs to the security-review branch, and doing it here would double this feature's size | Sealing both here: that is the security branch's scope, and until it lands the home Wi‑Fi is exactly as trusted as today |
| One CloudKit zone per device, not one shared zone | Each side fetches only its own traffic, and forgetting a device deletes one zone | One zone: every device would download every other device's ciphertext, and a clean-up would mean a query instead of one delete |
| Revoking comes back (`devices/forget`) after 021 left it out | FR-008 and SC-007 | Leaving it out: a lost phone could drive agents from anywhere, forever |
