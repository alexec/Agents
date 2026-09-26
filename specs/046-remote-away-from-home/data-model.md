# Data Model: Remote Works Away From Home

## Mac relay key *(new)*

| Field | Where | Notes |
|---|---|---|
| private key (P256, software) | login keychain, account `relay-mac-key`, held by `agents-bridge` | Made on the bridge's first run and never leaves the Mac. |
| `relayKey` (X9.63, 65 bytes) | daemon root `relay.json`, beside `devices.json` | Set by `relay/register`. Handed to devices in the `devices/announce` reply as `macKey`. |

A new `relayKey` replaces the old one. Devices paired to the old key are refused away until they
next connect at home (research R4).

## Device *(exists, 021; unchanged fields)*

`id`, `publicKey`, `name`, `kind`, `announcedAt`, `lastSeenAt`, `mayNotify`, `unknownFields`.

- **Removed** by `devices/forget`. There is no "revoked" flag. A forgotten device that announces
  again at home is a fresh pairing (D1).
- The bridge reads the list on its own connection and keeps it current from `device/changed`.

## What the device keeps *(new)*

| Field | Where | Notes |
|---|---|---|
| `macKey` | shared keychain group, account `relay-mac-key-public` | From the last `devices/announce` reply. Its absence means not paired for the relay. |
| zone change token | memory only | A new session reads the zone whole and ignores other sessions' frames. |

## Relayed session *(new, in memory only)*

| Field | Notes |
|---|---|
| `session` | UUID made by the device when the relay link opens. A reconnect is a new session. |
| `device` | the device id, which is also the zone's name |
| `nextOut`, `nextIn` | frame numbers per direction, from 0 |
| `lastHeard` | ends the session on the Mac after 2 min of silence (the device pings every 30 s) |
| daemon connection | Mac side: one `SocketLink` transport per session, as `Relay` has |

States: `opening` (the device sent frame 0 and is waiting for the Mac's frame 0) → `open` →
`ended` (silence, a gap left for 10 s, the device forgotten, the transport closed, or the bridge
restarted). An ended session is never reopened: the device makes a new one.

## Frame *(new, the CloudKit record)*

Record type `Frame` in zone `relay-<deviceID>`, private database, container
`iCloud.com.alexecollins.agents`. Record name `<session>/<direction>/<seq>`.

| Field | Type | Notes |
|---|---|---|
| `session` | String (UUID) | |
| `direction` | String | `toMac` or `toDevice` |
| `seq` | Int64 | per session per direction |
| `sealed` | Bytes | HPKE `encapsulatedKey ‖ ciphertext`; empty when `asset` is set |
| `asset` | Asset | the same bytes, when over 700 KB |
| `sentAt` | Date | for the 24 h sweep |

**Plaintext inside** (after opening and decompressing): `{ "lines": [String], "end": Bool? }`.
`lines` are daemon JSON-RPC lines, exactly as on the socket. `end` says the sender is closing the
session.

Validation: a frame that does not open, whose associated data does not match its fields, or that
is from a device not in the paired list is dropped without an answer. `seq` below the next
expected number is a duplicate and is dropped. Above it, the frame is held for up to 10 s.

## Link *(new, device side)*

`enum Link { case direct, relayed, none }`, published by `LinkChooser` and read by the screens
through `RemoteModel.link` and `RemoteModel.isAway` (`link == .relayed`).

Relay trouble the device can report: `.notPaired`, `.noICloud`, `.iCloudFull`, `.slowedDown`
(a retry-after over 3 s), `.macNotAnswering`.
