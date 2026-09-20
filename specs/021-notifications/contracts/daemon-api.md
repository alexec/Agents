# Contract: Daemon API

Additions only. Nothing existing changes shape, and every new field is optional on read so a
client built before this change still works against a daemon built after it, and the reverse.

## Methods

### `presence/report`

Told by every surface — the Mac window and each remote — when it comes to the front, goes
behind, changes conversation, or sees input after a quiet spell (FR-011).

```json
{ "watching": "UUID or null", "active": true, "mayNotify": true }
```

| Field | Meaning |
|---|---|
| `watching` | the conversation on screen, or null |
| `active` | in front of the person: frontmost on the Mac, foreground and unlocked on a device |
| `mayNotify` | whether this surface is permitted to show notifications; omitted means unchanged |

Returns `{}`. **No timestamp is accepted.** The daemon stamps arrival with its own clock, so a
device with a wrong clock cannot win every race.

The surface is taken from the connection, never from the parameters. A window is `.mac`; a
connection the bridge opened on behalf of a device is that device. A client that has not said
which device it is gets `noSuchDevice`.

Cheap by design: a report is three small fields and is sent on a change, not on a timer.
Typing does not send one per keystroke — a surface that is already `active` with the same
`watching` sends nothing.

### `attention/pending`

What is outstanding, asked once on connect. Beside `permissions/pending` and
`elicitations/pending`, and for the same reason: a surface that was not listening is put right
rather than left guessing.

Returns `{ "needs": [Need], "deliveries": { "<needID>": Surface } }`.

### `devices/list` · `devices/announce` · `devices/approve` · `devices/revoke`

005's four, built here (Slice C). `announce` returns the existing record when the same id
announces again with the same key, and fails `notSupported` when the id exists with a
**different** public key — a key never changes under an identity. `revoke` deletes the record
and empties that device's mailbox, because deletion is what makes a device unable to read
anything rather than a flag somebody must remember to check.

## Notifications

### `attention/changed`

The whole resolved fact for one need, carried the way `project/changed`, `cost/changed` and
`workflow/changed` carry theirs.

```json
{
  "needID":  { "permission": "abc123" },
  "need":    { "...": "the whole Need, or null when it is over" },
  "to":      { "device": "UUID" },
  "alert":   true
}
```

| Field | Meaning |
|---|---|
| `need` | the need, or `null` — `null` means met, and every surface withdraws |
| `to` | the surface that should be showing it, or `null` for nowhere reachable |
| `alert` | whether the person may be buzzed afresh, or whether it should appear quietly |

Broadcast to **every** connection, not only to `to`. That is what lets the losers withdraw, and
it is why FR-016 needs no second message. Each surface applies the same idempotent rule:

```text
to == me and not showing it   → show it, with sound iff alert
to != me and showing it       → withdraw it
need == null and showing it   → withdraw it
otherwise                     → nothing
```

Nothing legible goes to a device that is not `to`: the ciphertext is sealed to `to` alone, and
a withdrawal names only the need's id, which identifies nothing about the work.

### `device/changed`

`{ device }` on announce, approve and last-seen; `{ id, gone: true }` on revoke (Slice C).

## Failures

Continuing the block, which 013 left at `-32020`. Both `alreadyAnswered` (`-32019`) and
`noSuchDevice` (`-32020`) are already declared in `DaemonAPI.Failure` even though the device
work they were added for was never built.

| Code | Name | Means |
|---|---|---|
| `-32021` | `noSuchNeed` | A need id that is not outstanding — met, or never existed. |
| `-32022` | `notASurface` | `presence/report` from a connection with no identity. |

Both are reused unchanged; neither is redefined here.

## What does not change

- No existing method gains a required parameter.
- `agent/permission`, `agent/elicitation` and `agent/changed` are untouched. The need is
  derived from what they already carry; they do not learn about notifications.
- `DaemonServer.broadcast` is unchanged. A connection gains an identity so presence has an
  owner, which is a field on the connection, not a change to the fan-out.
