# Contract: the mailbox, and what the crypto promises

This is the contract with the user about their privacy, so it states what is guaranteed, what is not,
and who could learn what.

## The shape

A CloudKit **private database**, in a container both apps name explicitly (their bundle identifiers
differ, so neither may rely on the default), in a **custom zone**. Records are messages. One record
per message per target device.

```text
   Mac                                            iPhone
   ───                                            ──────
   agentsd ──unix socket──▶ bridge ──seal──▶ [ CloudKit ] ──alert push──▶ extension
                                   ◀──open──                              (decrypts headline)
                                                                                │
                                                                          app ──┘ opens, reads, answers
                                            ◀──────── sealed answer ───────────
   bridge ──poll every 1s while blocked──▶ [ CloudKit ]
```

## Record type `Message`

| Field | Type | Encrypted by us | Purpose |
|---|---|---|---|
| `to` | String | no | Target device `id`. The subscription predicate matches this. |
| `from` | String | no | Sender device `id`. |
| `kind` | String | no | `event`, `request`, `response`. |
| `seq` | Int64 | no | Monotonic per sender. |
| `sealed` | Bytes | **yes** | The JSON-RPC line. Up to the 1 MB record ceiling. |
| `h1` `h2` `h3` | String | **yes** | The headline, ≤100 characters each after sealing and base64. |
| `createdAt` | Date | no | Ordering and sweeping. |

Plaintext fields must stay meaningless. `to`, `from`, `kind`, `seq` and `createdAt` are routing. No
project name, agent name, folder, tool name or command ever appears outside `sealed` or the headline
fields.

Encrypted fields cannot be indexed, queried or sorted on, and cannot ride a push payload — which is
exactly why our ciphertext lives in ordinary fields rather than in `encryptedValues`.

## The seal

HPKE, P256, sealing to the target device's public key. `to`, `from` and `seq` are bound in as
associated data, so a record whose routing was edited will not open.

| Promise | Holds? | |
|---|---|---|
| Apple cannot read message content | **yes** | Sealed before it reaches CloudKit, with a key Apple never has. Independent of Advanced Data Protection. |
| Apple's push service cannot read the notification text | **yes** | The payload carries sealed headline fields. The words are written on the phone. |
| Another device on the same Apple Account cannot read | **yes** | It can read the *records* — CloudKit authenticates the account — but they are sealed to an approved device's key. This is the reason per-device keys exist. |
| A revoked device cannot read anything new | **yes** | Nothing is sealed to it again, and its records are deleted. |
| A revoked device cannot read what it already received | **no** | It had them in the clear on its own screen. Revocation is not a time machine. |
| Apple cannot see **that** two devices are talking, or how often | **no** | Traffic analysis is visible: record counts, sizes and timing. Stated, not hidden. |
| Content is safe against a future quantum computer | **partly** | P256 is classical, chosen so the Secure Enclave can hold the key. The mailbox is drained within seconds and swept within 7 days, which limits harvest-now-decrypt-later to a small window. Revisit when the Enclave holds a PQ or hybrid suite. |

## Notification delivery

A `CKQuerySubscription` per device, `firesOnRecordCreation`, predicate `to == <this device>`, with:

- `alertBody` set to a generic placeholder. **Not optional** — a notification with no alert, sound or
  badge is sent at lower priority, and SC-001's five seconds cannot rest on a low-priority push.
- `shouldSendMutableContent = true`, so the service extension gets it.
- `desiredKeys = ["h1", "h2", "h3"]`. At most three keys; strings over ~100 characters may be
  truncated.

The extension decrypts `h1`/`h2`/`h3` with the device's key, writes "**api · rename-refactor** wants
to run `git push`", and delivers. On any failure — key unavailable, truncation, an envelope that will
not open — it delivers the placeholder. It performs **no network I/O**, which is what keeps it inside
a memory ceiling of roughly 20 MB.

CloudKit does not notify the device that made a change, so there is no echo to suppress.

## Budgets to respect

| Limit | Value | Consequence |
|---|---|---|
| Record size | 1 MB | A transcript chunk is split before it reaches this. |
| Records per operation | 400 | Batch, and never exceed it. |
| Requests per second | ~40 per user | A one-second poll is 1/40th of the budget. Streaming per token is not possible and is not attempted. |
| `desiredKeys` | 3 keys, ~100 chars | The headline format is designed to the measured budget. |
| Throttling | both sides | `CKErrorRetryAfterKey` is honoured everywhere, without exception. |

Transcript is written in **coalesced chunks** — roughly one record per second of output, or on a
semantic boundary — never one per token, and only for the agent a device says it is watching.

## Sweeping

Nothing expires by itself. A reader deletes what it has opened. A writer deletes anything older than
seven days. Revoking a device deletes everything addressed to it at once. An undrained mailbox is
both a privacy leak and a charge against the user's own iCloud quota.

## Failure, and what the user sees

| Condition | What happens |
|---|---|
| Not signed into iCloud, or iCloud Drive off | `CKAccountStatus` is not `.available`. The Mac says which, in a sentence, on first run. Nothing is attempted. |
| Zone missing, `CKErrorUserDidResetEncryptedDataKey` | Recreate the zone and re-announce. Devices ask again. No agent data is at risk — none of it lives here. |
| Throttled | Back off by `CKErrorRetryAfterKey`. The remote shows itself as out of touch rather than pretending. |
| An envelope will not open | Dropped and logged. Never guessed at, never partly applied. |
| A `seq` gap | The reader refetches state rather than assuming it is current. |
| The Mac has not been heard from | The remote says when it last was, marks its state stale, and refuses actions against it (FR-035). |
