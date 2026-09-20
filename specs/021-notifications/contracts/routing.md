# Contract: The Ladder

One pure function, total over its inputs, in `AgentsKitCore/Attention/Routing.swift`. It is
the whole of FR-005 through FR-014 and the only place any of it is decided (FR-012).

```swift
public enum Routing {
    /// Where this need should be showing, and whether the person may be alerted afresh.
    ///
    /// Pure: no clock of its own, no I/O, no platform. `now` is passed in, which is what
    /// lets every rule below be exhausted in a unit test with no phone in the room.
    public static func decide(
        need: Need,
        presences: [Surface: Presence],
        devices: [Device],
        delivery: Delivery?,
        thresholds: AttentionThresholds,
        now: Date
    ) -> Decision
}

public struct Decision: Hashable, Sendable {
    public var to: Surface?     // where it should be showing; nil means nowhere reachable
    public var alert: Bool      // may the person be buzzed about it now
    public var wait: Bool       // hold — the settling pause has not elapsed
}
```

## The rungs, in order

The first that applies wins. Nothing below a matched rung is consulted.

| # | Rung | Condition | `to` | Requirement |
|---|---|---|---|---|
| 0 | **Already met** | the need is not outstanding | — | FR-015 |
| 1 | **Being watched** | any presence has `active && watching == need.agentID` | `nil` | FR-005a, FR-006 |
| 2 | **At the Mac** | `presences[.mac]` exists, `active`, and `now - heardAt < macIdle` | `.mac` | FR-005b, FR-007 |
| 3 | **The device in hand** | the approved, `mayNotify`, most recent `.device` with `now - heardAt < deviceStaleness` | that device | FR-005c, FR-008 |
| 4 | **The default** | the most recently used approved iPhone that may notify | that iPhone | FR-005d, FR-009 |
| 5 | **Nowhere** | none of the above | `nil` | FR-010, amended |

Rung 1 is deliberately **any** surface, not the one that would otherwise win. The spec's US3
scenario 3 asks for exactly this: watching the conversation on the iPad silences it even
though the phone was touched more recently. The rule is about the conversation being watched,
not about which machine watches it.

Rung 3 excludes a device whose `mayNotify` is `false` — it cannot show anything, so choosing
it would be choosing silence. It stays excluded from rung 4 for the same reason. FR-023 is
what tells the person this is happening.

Rung 5 is not a failure. The need stays outstanding in the daemon's record and the next
surface to connect is told about it through `attention/pending`.

## The settling pause

`wait` is true, and nothing is delivered, when **all** of:

- rung 2 matched (the person is demonstrably at the Mac), and
- they are not watching this conversation, and
- `now - need.raisedAt < settlingPause`.

Never when the person is away (FR-013): rungs 3, 4 and 5 deliver immediately, because a person
who is not at the Mac is not about to look at it. Re-decide when the pause elapses.

## Alerting versus showing

`to` says where the notification should *be*. `alert` says whether the person may be *buzzed*.
They differ on a move, and that difference is the whole of FR-018:

```text
alert = delivery == nil                                   // first time
     || delivery.to != to                                 // it has moved
        && now - delivery.alertedAt >= reAlertInterval    // but not too often
```

A move inside the interval still moves the notification — `to` changes, the old surface
withdraws, the new one shows it — but shows it silently. Ten moves in five minutes produce one
alert, which is SC-006 with room to spare.

## Totality

`decide` is total over `(Need, [Surface: Presence], [Device], Delivery?, Date)`. There is no
input for which it returns nothing, and a test exhausts the rungs the way
`AgentGroupTests` exhausts `AgentState` — a case that fell through would be a need the person
never hears about, which is the failure this feature exists to prevent.

## Ties

Two devices heard from within the same instant: the later `heardAt` wins; on an exact tie, the
iPhone, because that is the default the person asked for. Stated here rather than left to
`max(by:)`'s stability, which is not guaranteed and not readable.
