# Contract: what crosses the socket

One new notification, one new method, one new payload. Nothing existing changes shape.

The whole of this is modelled on `cost/state`, which is the same kind of thing: a fact the
daemon derives, that no window can work out for itself, broadcast when it moves and
fetchable by a window that arrives late.

## `DaemonAPI.WakeState`

```swift
public struct WakeState: Codable, Hashable, Sendable {
    public var isHolding: Bool
    public var agentsInFlight: Int
    public var heldBackByBattery: Bool
    public var batteryPercent: Int?
    public var since: Date?
}
```

| Field | Meaning |
|---|---|
| `isHolding` | The assertion is held right now (FR-015). |
| `agentsInFlight` | How many agents are `starting` or `running`. |
| `heldBackByBattery` | Work is in flight but the battery floor released the hold (FR-016). |
| `batteryPercent` | The reading behind those, for the words. Nil on a Mac with no battery. |
| `since` | When this hold was taken. Nil when not holding. |

`isHolding` and `heldBackByBattery` are never both true. Both false with
`agentsInFlight == 0` is the ordinary, silent case.

### Example bodies

Nothing running, on mains:

```json
{ "isHolding": false, "agentsInFlight": 0, "heldBackByBattery": false, "batteryPercent": 77 }
```

Two agents mid-turn:

```json
{ "isHolding": true, "agentsInFlight": 2, "heldBackByBattery": false,
  "batteryPercent": 64, "since": "2026-09-23T22:04:11Z" }
```

One agent mid-turn, battery at the floor:

```json
{ "isHolding": false, "agentsInFlight": 1, "heldBackByBattery": true, "batteryPercent": 18 }
```

## Notification: `wake/changed`

```
DaemonAPI.Notification.wakeChanged = "wake/changed"
```

The two names differ on purpose, and this follows the house convention rather than
inventing one: `cost` is `Method.costState = "cost/state"` alongside
`Notification.costChanged = "cost/changed"` (`DaemonAPI.swift:120` and `:176`). A method is
a question about state; a notification is news that it changed.

Broadcast to **every** connection whenever the derived state changes, and only then.
`reviseWakefulness()` compares against the last broadcast and sends nothing when nothing
moved — it is called from `changed(_:)`, which runs on every token of streamed output, so a
broadcast per call would be a flood.

Params are a `WakeState`.

On the client this needs all three of the pieces `cost/changed` has: a case on
`AgentsModel.Update` (`AgentsModel.swift:107`), a line in the notification decoder
(`:131`), and a line in the applier (`:198`). Missing the decoder line is the silent
failure — the notification simply never arrives and nothing says so.

A window that hears this replaces `AgentsModel.wakeState` wholesale. There is no partial
update and no ordering requirement beyond last-writer-wins: the state is small, complete,
and about right now.

## Method: `wake/state`

```
DaemonAPI.Method.wakeState = "wake/state"
```

No params. Answers the current `WakeState`.

Called once by a window on connecting, because a window opened *after* the hold was taken
has heard no broadcast and would otherwise show nothing until the next change — which, for
a long turn, could be half an hour.

**A window MUST tolerate `method not found`.** A newer window against an older daemon gets
that, leaves `wakeState` nil, and simply says nothing about sleep. This is the same
tolerance `AppModel` already has for `cost/state` (`AppModel.swift:329`), and it is what
keeps the two apps independently shippable.

## What does not change

- **No change to `Agent`.** Wakefulness is not a fact about any one agent, and putting it on
  the record would persist something that must not outlive the process (FR-013).
- **No change to `agent/changed`.** A window could in principle count `starting` and
  `running` agents itself, but it must not: the power half of the verdict is knowable only
  to the daemon, and a second decider is the disease 019 was written to cure.
- **No new MCP tool, and no change to any existing one.** Nothing here is agent-facing. An
  agent has no business knowing whether the Mac is being held awake for it, and no business
  asking for it.
- **No change to the remotes.** The phone and iPad never hold the Mac awake and are not told
  about it. The Mac's wakefulness is a fact about the Mac.
