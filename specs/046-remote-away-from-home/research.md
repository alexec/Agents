# Research: Remote Works Away From Home

Each finding says what it decides. 005's research §1–§3 is not repeated: there is still no
first-party way to open a socket between two of a person's devices across the internet, and
CloudKit's private database is still the channel. What is new is what the tree now has, and what
building it on that tree decides.

---

## R1. The relay is a `LineTransport`, not a second protocol

**Decision**: the device end is `RelayTransport: LineTransport`, handed to the same
`DaemonClient` through a `DaemonLink`. Nothing above it changes.

`DaemonClient`'s own doc comment already says "a phone hands it a mailbox". `JSONRPCConnection`
needs only `write(line:)`, `lines()` and `close()`. On the Mac, the bridge's `Relay` already turns
one device into one daemon connection by carrying bytes, and `RelayHost` does the same with frames
instead of a TCP stream. So every daemon method the phone uses today, including 029's start,
033's options, 034's files and 042's events, works over the relay without being ported.

**Alternatives**: a narrow relay-only API (just permissions and prompts). Rejected: it is a
second protocol to keep in step with `DaemonAPI` forever, and the spec asks for the whole
everyday surface (FR-010).

## R2. The Mac end lives in `agents-bridge`

**Decision**: `RelayHost` runs in the bridge beside `MailboxTransport`. For each relayed session
it opens a fresh `SocketLink` connection to the daemon.

The bridge is the one Mac process entitled for CloudKit (021 T056). A connection per session,
not a shared one, for the reason `Relay` gives: the daemon broadcasts to connections, and a
connection is how the daemon knows which device is asking (`surface/identify`).
`AGENTS_BRIDGE_NO_MAILBOX` switches the relay off along with the mailbox.

## R3. Sealing: HPKE in authenticated mode, with the session and number bound in

**Decision**: every frame is `HPKE.Sender(recipientKey:ciphersuite:info:authenticatedBy:)`,
using the suite `Envelope` already uses (P256_SHA256_AES_GCM_256). `info` is
`com.alexecollins.agents.relay.v1`. The associated data is
`sessionID ‖ direction ‖ seq`. A device frame is sealed to the Mac's key and authenticated by
the device's key; a Mac frame the reverse.

- **Who sent it** comes from auth mode. The Mac opens a device frame with each paired device's
  public key as the claimed sender, and only the zone's own device is tried. A frame that does
  not open is dropped and never answered (FR-008).
- **Replay and reordering**: the associated data ties a frame to its session, direction and
  number. A frame copied into another session, or renumbered, does not open.
- **The phone's key is in the Secure Enclave.** `SecureEnclave.P256.KeyAgreement.PrivateKey`
  conforms to `HPKEDiffieHellmanPrivateKey`, and `Envelope.open` already uses it that way as a
  recipient. Being an *authenticating sender* with it is **unverified on hardware**, and the
  spike (Phase 0) checks it first. If it fails, the fallback is a software P256 key made for
  signing frames only and kept in the same keychain group. That is slightly weaker, and the same
  rule holds: the private half never leaves the device.

**Alternatives**: `CKRecord.encryptedValues`. Rejected for 005's reason: it only keeps Apple out
when Advanced Data Protection is on. Base-mode HPKE plus a signature: two primitives where auth
mode is one.

## R4. The Mac's key, and pairing

**Decision**: the bridge makes a P256 key on first run and keeps it in the login keychain, using
`DeviceKey.load(account: "relay-mac-key", accessGroup: nil)`, which is the software key path.
The Mac's Secure Enclave is avoided for now: a `dispatchMain` helper with no UI must not be able
to lose its key when the Mac is locked. The bridge registers the public half with
`relay/register` on its mailbox connection. The daemon keeps it in `devices.json` and returns it
as `macKey` in the `devices/announce` reply. The phone keeps it in its keychain.

`devices/announce` only ever arrives over the direct link, so that key is never learnt through
iCloud (D1). A phone that has no `macKey` is not paired for the relay, and says so (FR-009).

If the bridge's key changes (a new Mac, or a wiped keychain), the next direct connection hands
out the new one. Until then the Mac drops the phone's relayed frames, because they are sealed to
the old key, and the phone shows "Open Agents once on your Mac's Wi-Fi".

## R5. Zones, records and frames

**Decision**: one zone per device, `relay-<deviceID>`, in the private database. One record type,
`Frame`:

| Field | What |
|---|---|
| `session` | UUID, made by the device per relayed session |
| `direction` | `toMac` / `toDevice` |
| `seq` | 0, 1, 2… per session per direction |
| `sealed` | bytes: `encapsulatedKey ‖ ciphertext` of the compressed batch |
| `asset` | `CKAsset` with the same bytes when they are over 700 KB; `sealed` is then empty |
| `sentAt` | date, for the sweep |

Record name: `<session>/<direction>/<seq>`, so a retried save of the same frame overwrites
itself rather than adding a second copy.

- **Order and duplicates**: `FrameOrder` hands on frames in `seq` order, holds early ones, drops
  anything already seen, and after 10 s gives up on a gap by ending the session. The phone then
  reconnects, which is a new session with a full refresh, as a direct reconnect does today.
- **Deleting**: the recipient deletes what it has delivered, in batches of up to 400 IDs. The
  bridge sweeps every zone hourly for anything older than 24 h (FR-017).
- **Why per-device zones** (Complexity Tracking): each side fetches only its own traffic, and
  forgetting a device is one zone delete.

## R6. Batching and size

**Decision**: the bridge's `LineBatcher` sends a frame at 400 ms after the first waiting line, or
at 256 KB of lines, whichever comes first. The device sends each request at once, as a frame
of one. Batches are zlib-compressed before sealing.

A busy Claude turn produces many `agent/entry` lines a second, and every agent's changes are
broadcast to every connection. At home that is free; over the relay it is records. Batching turns
it into about 2–3 writes a second. Compression is what lets a JSON-heavy `agents/list` of several
MB fit in one record almost always. Over 700 KB sealed, the frame travels as a `CKAsset`, which
CloudKit accepts up to far past anything this sends.

The bridge does not filter lines. Terminal output (`shell/output`) and file changes only reach a
device that asked for them, and away the phone never asks (R10).

## R7. How each side notices

**Decision**: pull always, push when it comes.

- **Mac**: `CKFetchDatabaseChangesOperation` to find which zones changed, then
  `CKFetchRecordZoneChangesOperation` on those, with server change tokens kept in memory and in
  the bridge's defaults. Every 1 s while any session has been live in the last 2 min, every 5 s
  otherwise. Whether a push reaches a `dispatchMain` helper on macOS is unproven. It is not
  needed, so it is not attempted (FR-015).
- **Device**: a `CKRecordZoneSubscription` on its own zone (silent, content-available) wakes a
  fetch at once. While the app is in the foreground and on the relay, it also fetches every 1 s.
  Backgrounded, the session ends as a direct one does today, and needs keep reaching the phone
  through the existing mailbox banners.
- **Budget**: about 1 fetch a second each side, plus the writes from R6, against about 40
  requests a second per user.
- **Throttling**: a `CKError` with `retryAfterSeconds` (`requestRateLimited`, `zoneBusy`,
  `serviceUnavailable`) pauses that side for the time asked. If the pause is over 3 s, the phone
  shows "Slower than usual" (FR-014, FR-018).

## R8. Choosing the link

**Decision**: `LinkChooser: DaemonLink`, given to `RemoteModel` in place of `NetworkLink()`.

- `transport()` starts the Bonjour browse and connect and the relay's session opening together.
  The direct link wins if it is ready within 2 s. Otherwise the relay wins as soon as the Mac
  answers `ping` through it. Both failing throws, and `RemoteModel.connect()`'s existing back-off
  takes over.
- **Back home**: while on the relay, an `NWBrowser` stays up. When the Mac appears and a direct
  connection comes up, the chooser closes the relayed transport. `RemoteModel` hears the stream
  end, runs `lostTouch()`, reconnects, and gets the direct link. This is the path the app
  already uses when the Mac restarts, so no new state machine is needed.
- **Leaving home**: the TCP connection fails or stalls. A stall is caught by a `ping` every 5 s
  while on the direct link, with a 3 s deadline. `lostTouch()` then reconnects and gets the
  relay (SC-004 ≤ 10 s).
- **Same Wi‑Fi name, different network**: Bonjour finds nothing there, so the relay is used.
- The chooser publishes `link: .direct | .relayed | .none`, which `RemoteModel` exposes to the
  screens.

**Alternatives**: `NWPathMonitor`-driven switching. Rejected: "on Wi‑Fi" is not "on the Mac's
Wi‑Fi", and only a Mac that actually answers settles it.

## R9. Exactly once

**Decision**: every mutating call from the phone carries an id the daemon already dedups, and
is retried once with the same id after a reconnect.

Already in place: `once(sendID)` in `DaemonCore+Sends.swift` covers `agents/prompt`,
`permissions/answer` and `elicitations/answer`, and `agents/start` has `requestID` (029).
`agents/stop` and `agents/archive` are idempotent. What is missing is the phone's side: its
`agents/prompt` sends no `sendID` today (`RemoteModel.send`), and a call that dies with the
connection is reported as failed rather than tried again. `RemoteModel` gains `sendOnce`, which
makes the id once per action, calls, and on `JSONRPCTransportError.closed` waits for
`connect()` and calls once more with the same params (FR-003, SC-004).

## R10. What is off while away

**Decision**: a `RemoteModel.isAway` flag, read by:

- **Files, Terminal and Page panes**: when away, they show the approved "Needs the same network
  as your Mac" view instead of opening. They call no `files/watch` and open no shell. When the
  link returns to direct, the pane's `task(id:)` is keyed on the link, so it opens the real view
  by itself (FR-012).
- **Prompt bar**: the paperclip is disabled away. Voice and send are unchanged.
- **Banner**: `StaleBanner` gains the Away line ("Away — slower, through iCloud") and the
  never-paired line, in the same slot (look gate A and C).

## R11. Forgetting a device

**Decision**: `devices/forget {id}` removes the record and broadcasts `device/changed` with
`removed: true`. The Mac's Settings ▸ Devices row gets a Forget button with a confirmation.

The bridge hears the change on its own connection, ends that device's sessions, and deletes the
device's zone, well within FR-008's minute. The phone, on its next relayed frame, finds the zone
gone or gets a `relayRefused` frame. It then clears its stored `macKey` and shows the
never-paired line. On the direct link a forgotten device simply announces again, and is paired
again: that is D1.

021 recorded "no approving and no revoking" (Alex, 2026-09-21), when the only thing a paired
device could get was banners. With the relay, a paired device can drive agents from anywhere,
and the spec's FR-008 and SC-007 need a way to take that back.

## R12. iCloud not available

**Decision**: both sides check `CKContainer.accountStatus()`. On the phone, `.noAccount`,
`.restricted` or a different account (the zone is missing and cannot be created) shows "The
relay needs iCloud on your iPhone and your Mac", and the direct link still works. The bridge
logs it and keeps its LAN listener. A full iCloud (`quotaExceeded`) is shown the same way, with
its own words.

## R13. Spike first (Phase 0)

Two things this plan rests on and no test on this Mac can settle:

1. HPKE auth-mode *sending* with the phone's Secure Enclave key (R3). This runs in a
   `-spike-relay` launch of the Remote on Alex's iPhone and prints the result.
2. A round trip over CloudKit on cellular: the phone writes a frame, the bridge polls, opens it,
   answers, and the phone fetches the answer. Ten times, recording the worst case against
   SC-001's 3 s. This runs through the bridge's `--spike-relay`.

If (1) fails, take R3's fallback. If (2) is regularly over 3 s, lower the Mac's poll interval
and tell Alex the figure before building US2.
