# Data Model: Remotes for iPhone and iPad

Three new things are stored: a record per paired device on the Mac, a key pair on each device, and a
transient encrypted message in CloudKit that is deleted once it has been read. Nothing else changes.
`agent.json` and `transcript.jsonl` are untouched and the daemon is still their only writer.

## Device

A remote the user has approved. Lives in `AgentsKitCore/Remote/Device.swift`; the Mac stores it.

| Field | Type | Meaning |
|---|---|---|
| `id` | `UUID` | Made by the device on first run. Identity. |
| `publicKey` | `Data` | P256 public key. Everything sealed to this device is sealed to it. |
| `name` | `String` | What the device calls itself — "Alex's iPhone". Shown on the Mac, and in "answered by". |
| `kind` | `Kind` | `iPhone`, `iPad`, `unknown`. Drives an icon and nothing else. |
| `announcedAt` | `Date` | When it first asked. |
| `approvedAt` | `Date?` | When the user approved it. `nil` means it is waiting. |
| `lastSeenAt` | `Date?` | When it last connected. `nil` means never. |
| `wants` | `Notify` | Which notifications it asked for. See below. |
| `unknownFields` | `[String: JSONValue]` | Kept and written back, as `Agent` and `Project` do. |

Derived, never stored:

| Property | Rule |
|---|---|
| `isApproved` | `approvedAt != nil`. An unapproved device is sealed nothing and told nothing. |

`Notify` is three flags — `needsInput`, `finished`, `failed` — defaulting to all three on, held per
device because FR-016 says each kind can be turned off independently and one person's phone and iPad
want different things.

### Invariants

- One record per `id`. A device that reinstalls makes a new `id` and a new key, and asks again. That
  is correct: the old private key is gone, so the old record can never be used again.
- A device is sealed to only while `isApproved`. Revoking deletes the record, and deleting it is what
  makes the device unable to read anything — not a flag anyone has to remember to check.
- The public key is never rewritten. A device that wants a new key is a new device.

### Lifecycle

```text
   (nothing) ── device announces ──▶ waiting (approvedAt nil)
   waiting ──── user approves ─────▶ approved
   waiting ──── user denies ───────▶ record deleted, mailbox emptied
   approved ─── user revokes ──────▶ record deleted, mailbox emptied
```

There is no "suspended". A device is approved or it does not exist, because anything softer would be
a flag standing where a key should be.

## Storage on the Mac

One file, `~/Library/Application Support/Agents/devices.json`, a JSON array, written whole on every
change. `StoreLocations` gains `devices`. This is the same shape as 004's `projects.json` and for the
same reasons: it is a handful of records for one person, it changes when a user taps something, and
it can be read with `cat`.

```json
[
  { "id": "6E1C…", "name": "Alex's iPhone", "kind": "iPhone",
    "publicKey": "BEi…", "announcedAt": "2026-09-18T09:00:00.000Z",
    "approvedAt": "2026-09-18T09:00:11.220Z", "lastSeenAt": "2026-09-18T14:02:11.004Z",
    "wants": { "needsInput": true, "finished": true, "failed": true } }
]
```

Losing this file loses pairings, and every device asks again. That is the right thing to lose: no
agent, transcript or project depends on it.

## DeviceKey

Not stored in any file. Each device makes a P256 key pair on first run and keeps the private half in
its own keychain:

| Attribute | Value | Why |
|---|---|---|
| Class | key | Keys sync and can be Enclave-backed; P256 because the Secure Enclave has no Curve25519. |
| Accessibility | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | The notification extension reads it while the phone is locked. `ThisDeviceOnly` because this key must never sync — a key that syncs cannot be revoked from one device. |
| Access group | shared by the app and its notification extension | The extension decrypts the headline. |
| Enclave | yes, where available | An identity key the Enclave holds cannot leave the phone at all. |

The Mac holds one too, by the same rules, minus the extension.

## Envelope

The sealed form of anything that crosses. Pure, in `AgentsKitCore/Remote/Envelope.swift`, and the most
tested file in the feature.

| Field | Type | Meaning |
|---|---|---|
| `to` | `UUID` | The device it is sealed to. Plaintext, because the mailbox routes on it. |
| `from` | `UUID` | Who sealed it. Plaintext. |
| `sequence` | `Int` | Monotonic per sender. Detects loss and reordering. |
| `sealed` | `Data` | HPKE, P256, to `to`'s public key. Everything that matters is in here. |

`to`, `from` and `sequence` are bound in as associated data, so a record whose routing fields were
edited will not open. What is inside is one JSON-RPC line — the same line that would have gone down
the Unix socket, which is what makes the whole `DaemonAPI` surface work across this with nothing
ported.

### Invariants

- An envelope that does not open is dropped and logged. It is never guessed at, never partially
  applied.
- Nothing is ever sealed to a device without an approved record.
- `sequence` gaps are reported to the reader, not repaired. A remote that has missed messages
  refetches state rather than pretending it is current.

## Mailbox record

The CloudKit record type, in the user's private database, in a custom zone. One record per message
per target device — one device's subscription must be able to filter on plaintext, and encrypted
fields cannot be queried.

| Field | Encrypted | Meaning |
|---|---|---|
| `to` | no | The target device's `id`. The subscription predicate matches on this. |
| `kind` | no | `event`, `request`, `response`. Routing only; says nothing about content. |
| `sealed` | **ours** | The envelope. Up to 1 MB, which is the record ceiling. |
| `h1`, `h2`, `h3` | **ours** | The headline, below. |
| `createdAt` | no | For ordering and for sweeping. |

Nothing in a plaintext field says which project, which agent or what is being asked.

### Headline

Three fields because `desiredKeys` carries at most three, each at most about 100 characters before
CloudKit may truncate. After base64 and AES-GCM overhead that is roughly 45 to 70 bytes of plaintext
each: `h1` the project name, `h2` the agent name, `h3` a short action such as "wants to run
`git push`". Each is sealed separately so each fits, and each is truncated to the measured budget
before sealing — measured in the spike, not assumed.

The notification extension decrypts these three and writes the banner. If any fails, the banner stays
the generic placeholder that CloudKit sent. That is the whole of FR-015 and FR-019 together.

### Lifecycle and sweeping

```text
   written ──▶ delivered ──▶ deleted by the reader
           └─▶ unread for 7 days ──▶ swept by the writer
```

CloudKit has no record expiry we can set, so we delete our own. A reader deletes what it has opened;
a writer sweeps anything older than seven days. Revoking a device deletes everything addressed to it
immediately. An undrained mailbox is both a privacy leak and a bill against the user's iCloud quota.

## Subscription

What a remote is currently watching. Held by the bridge, in memory, never stored — if the bridge
restarts, the remote says again.

| Field | Meaning |
|---|---|
| `device` | Which remote. |
| `watching` | The agent whose transcript it wants, or none. |
| `since` | The last sequence it acknowledged. |

This is what keeps a phone's data small. State changes and questions go to every approved device
always; transcript entries go only to the device watching that agent (FR-037). The daemon's broadcast
stays unconditional, as it is today — the narrowing happens in the bridge.

## What does not change

- **Agent**: no new field. It crosses the wire as the same `Codable` the Mac uses.
- **PermissionRequest and ElicitationRequest**: unchanged in shape. Both already carry a stable `id`,
  which is what lets any client answer any question.
- **Project**: 004's, unchanged. The remote is another view of it.
- **AgentGroup**: 004's, unchanged. The phone groups with the same total function the Mac does, from
  the same file, which is why the two cannot disagree.
- **Transcript paging**: `TranscriptRequest`'s `before` and `limit` already exist and already do what
  FR-037 needs.
