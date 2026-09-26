# Contract: The Relayed Link

What travels through the person's iCloud, and the rules both ends keep. The device end is
`RelayTransport` (AgentsKitCore). The Mac end is `RelayHost` (agents-bridge). Both are written
against the `RelayChannel` protocol, so `swift test` runs them over `FakeRelayChannel`.

## Where

- Container `iCloud.com.alexecollins.agents`, **private** database.
- One zone per paired device: `relay-<deviceID uppercase UUID>`. The device creates it when it
  first opens a relayed session. The Mac deletes it on `devices/forget`.
- The 021 `mailbox` zone is untouched. Banners still go that way.

## `Frame` record

Name `<session>/<direction>/<seq>`. Fields as in [data-model.md](../data-model.md#frame-new-the-cloudkit-record).
Saved with `savePolicy: .allKeys`, so a retried save of the same frame replaces it rather than
adding a copy.

## Sealing

```
suite  = P256_SHA256_AES_GCM_256          (Envelope.suite)
info   = "com.alexecollins.agents.relay.v1"
aad    = session(16 bytes) ‖ direction(1 byte: 0 toMac, 1 toDevice) ‖ seq(8 bytes, big-endian)
plain  = zlib( JSON { "lines": [String], "end": Bool? } )
sealed = encapsulatedKey(65) ‖ HPKE.Sender(recipient, info, authenticatedBy: senderKey).seal(plain, aad)
```

- `toMac`: recipient = the Mac's relay key; sender = the device's key.
- `toDevice`: recipient = the device's key; sender = the Mac's relay key.
- If `sealed` is over 700 KB, it goes in `asset` and `sealed` is empty.

The receiver rebuilds the associated data from the record's own fields and opens the frame with
the claimed sender's public key. On the Mac, that is the paired device the zone is named for.
Any failure drops the frame silently.

## Session

1. **Open.** The device makes `session` and sends frame 0 `toMac`. That frame holds its first
   JSON-RPC line (`ping`, from `DaemonClient.open()`).
2. **The Mac** sees a new session in a paired device's zone and opens a `SocketLink` transport to
   the daemon. It writes the frame's lines, and from then on batches whatever the daemon sends
   into `toDevice` frames.
3. **Both ways**: lines are delivered in `seq` order. A frame below the next expected `seq` is
   dropped. One above it is held, and after **10 s** a gap ends the session.
4. **Keeping alive**: the device sends a frame with no lines every 30 s while it has sent nothing
   else. After **2 min** with no frame, the Mac ends the session.
5. **End**: either side sends `end: true` and closes. The Mac closes the daemon transport; the
   device's `lines()` stream finishes, which `RemoteModel` treats as lost touch.
6. **Deleting**: after delivering a frame, the recipient deletes it (batched, ≤ 400 IDs per
   operation). The Mac sweeps every relay zone hourly for `sentAt` older than 24 h.

## Timing

| Side | What | When |
|---|---|---|
| Mac | send a batch | 400 ms after the first line waiting, or at 256 KB |
| Mac | fetch changes | 1 s while any session was live in the last 2 min, 5 s otherwise |
| Device | send | at once, one frame per write |
| Device | fetch | on a zone push, and every 1 s in the foreground while relayed |
| Both | on `CKError.retryAfterSeconds` | pause that operation for the time asked. The device reports `.slowedDown` if the pause is over 3 s |

## Refusals

- **Frame from an unpaired device, or one that doesn't open**: dropped, and never answered.
- **Device forgotten**: the Mac ends the device's sessions and deletes its zone. The device's
  next fetch or save gets `zoneNotFound` (or `userDeletedZone`), so it clears `macKey` and
  reports `.notPaired`. It does **not** recreate the zone until it has a `macKey` again.
- **No iCloud account on the device**: `.noICloud`, and nothing is written.

## Properties the tests pin

- Nothing in any record, other than ids, numbers and dates, is readable without a private key
  (SC-005).
- A frame whose `seq` has been changed, or which has been copied into another session or
  direction, does not open.
- Duplicated, reordered and delayed frames still give the daemon every line exactly once, in
  order.
- A 5 MB `agents/list` reply arrives whole.
