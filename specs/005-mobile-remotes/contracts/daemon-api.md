# Contract: what changes in the daemon

The same JSON-RPC over the same Unix socket. Three new methods, one new notification, one new failure
code, and one new field on two existing requests. **No new listener and no network code in
`agentsd`.** The bridge is an ordinary client of the socket that already exists.

## Methods

### `devices/list`

**Params**: none.

**Returns**: `[Device]`, waiting devices first, then approved by `lastSeenAt` descending.

```json
[
  { "id": "6E1C…", "name": "Alex's iPhone", "kind": "iPhone",
    "publicKey": "BEi…", "announcedAt": "2026-09-18T09:00:00.000Z",
    "approvedAt": null, "lastSeenAt": null,
    "wants": { "needsInput": true, "finished": true, "failed": true } }
]
```

`approvedAt: null` is a device asking to be let in. The Mac shows it as a question.

### `devices/announce`

**Params**: `{ "id": "…", "name": "Alex's iPhone", "kind": "iPhone", "publicKey": "BEi…" }`

**Returns**: the `Device`, waiting.

Called by the bridge when an unknown device writes an announcement into the mailbox. Stores it
unapproved and broadcasts `device/changed` so the Mac can ask. Announcing twice with the same `id`
and the same key is not an error and returns the existing record — a phone that reopens while waiting
must not queue up a second question.

**Fails**: `notSupported` when the `id` exists with a *different* `publicKey`. A key never changes
under an identity; a device that wants a new key is a new device.

### `devices/approve`

**Params**: `{ "id": "…" }`

**Returns**: the `Device`, approved.

Stamps `approvedAt` and broadcasts. From this moment the bridge seals to it.

**Fails**: `noSuchDevice` when there is no such record.

### `devices/revoke`

**Params**: `{ "id": "…" }`

**Returns**: nothing.

Deletes the record and broadcasts. The bridge then empties that device's mailbox. Revoking works the
same on an approved device and on one still waiting — denying and revoking are the same act.

Revocation is complete when the record is gone, because sealing needs the public key that went with
it. There is no flag anyone has to remember to check.

**Fails**: `noSuchDevice`.

## Notification

### `device/changed`

**Params**: `{ "device": Device }` on announce, approve and last-seen; `{ "id": "…", "gone": true }`
on revoke.

Broadcast to every connection, so two Mac windows agree and the bridge learns of an approval without
polling the daemon.

## One new field, on two existing requests

`AnswerRequest` and `AnswerElicitationRequest` each gain:

```
answeredBy: String?     // the device's name, or nil meaning this Mac
```

It is carried into the withdrawal broadcast so every other client can say who won:

```
PermissionNotification { agentID, request: nil, answeredBy: "Alex's iPhone" }
```

Optional on read, so a client built before this change still answers and a daemon built before it
still accepts. Nothing depends on it being there.

## One new failure code

| Code | Name | When |
|---|---|---|
| `-32013` | `alreadyAnswered` | The question was answered by someone else first. |
| `-32014` | `noSuchDevice` | Approve or revoke naming a device that is not there. |

Continuing the block that 004 leaves at `-32012`.

`alreadyAnswered` replaces the `noSuchAgent` (`-32005`) that `answerPermission` and
`answerElicitation` throw today when the pending entry has gone. Reusing `noSuchAgent` was fine while
only one window could answer; a phone cannot tell "somebody beat you to it" from "that agent is gone",
and those deserve different sentences. The message is unchanged: *"That question has already been
answered."*

## What does not change

- **Answering is already first-answer-wins.** `answerPermission` removes the pending request from an
  actor's dictionary and throws if it has gone (`DaemonCore+Commands.swift:390`). That is atomic and
  it is why FR-032 is nearly free. The loser already learns to withdraw the question from the
  existing `request: nil` broadcast.
- **`agents/transcript` already pages.** `before` and `limit` are what FR-037 needs. No paged remote
  call is added.
- **`DaemonServer` still broadcasts everything to every connection.** Narrowing for a metered
  connection is the bridge's job, not the daemon's.
- **`shouldExit` is untouched.** It is `connectionCount == 0 && !isHoldingAgents` today. The bridge
  is a connection, so while a device is paired the daemon stays up for the existing reason. With no
  device paired the bridge does not run and nothing about the daemon's lifetime changes.
- **Nothing is added to `agent.json`.**

## What is deliberately not here

- **No `devices/rename`.** The name comes from the device and is refreshed when it connects.
- **No per-device permissions.** A paired device can do what the user can do. A device that should
  not be trusted with that should not be approved.
- **No transport method.** The daemon does not know a remote exists. It sees a client.
