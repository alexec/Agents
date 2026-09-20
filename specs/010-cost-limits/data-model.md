# Data Model: Cost Limits

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Date**: 2026-09-19

Two new types, one new field, two new enum cases, and four computed rules that are deliberately not
stored. Everything a person writes is in `limits.json`; everything the machine counts is in
`spend.json`; everything else is arithmetic.

---

## `CostLimits`

`Packages/AgentsKit/Sources/AgentsKitCore/Model/CostLimits.swift` — new. In Core because the phone
reads it and the Settings window writes it.

| Field | Type | Meaning |
|---|---|---|
| `perAgent` | `Cost?` | The most any one agent may spend across its whole life. `nil` is no limit, and is the state before the reader has said anything. |
| `daily` | `Cost?` | The most everything may spend in one local day. `nil` is no limit. |

Both reuse the existing `Cost` — an amount and a currency — rather than a bare `Decimal`, because
FR-005 makes the currency part of the limit and not an assumption.

**Rules** (pure, unit-tested, no daemon):

| Rule | Behaviour |
|---|---|
| `isEmpty` | Both `nil`. The app behaves exactly as it does today; nothing is shown and nothing is gated. |
| `headroom(in:against:)` | Limit amount less what has been spent in that currency, floored at zero. `nil` when there is no limit in that currency, which is how a view knows to show nothing rather than an empty gauge. |
| A limit of zero | A real limit that is immediately reached. Distinct from `nil`, and must never be collapsed into it — the whole of the spec's "a limit of zero" edge case is that `Optional` does this correctly and `amount == 0` meaning "off" would not. |
| A currency with no limit | Uncapped. Spend in it is counted and shown, never compared. |

---

## `DaySpend` and the ledger file

`Packages/AgentsKit/Sources/AgentsKit/Store/SpendLedger.swift` — new, in `AgentsKit` because it
touches the file system. The shape it persists:

```json
{
  "days": {
    "2026-09-18": { "USD": 4.1809 },
    "2026-09-19": { "USD": 12.3400, "GBP": 0.8100 }
  }
}
```

| Element | Type | Meaning |
|---|---|---|
| day stamp | `String`, `yyyy-MM-dd` | The machine's local calendar day, taken at the moment a turn's cost was banked. |
| currency | `String` | The runtime's own currency code, exactly as it arrived. |
| amount | `Decimal` | Running total for that day and currency. Never summed across currencies. |

**Rules**:

| Rule | Behaviour |
|---|---|
| Banking | `add(_ cost: Cost, on: Date)` adds into today's bucket and writes. Called once per turn, from `finishTurn`, before the agent is broadcast. |
| The day a spend belongs to | The day its turn ended. Nothing is ever re-attributed later. |
| Pruning | Anything older than seven days is dropped on write. Seven is chosen to make every boundary question unambiguous, not to offer history; see [research.md §3](./research.md). |
| Rollover | Implicit. A new day is a key that is not there yet, whose total is therefore zero. No timer resets anything. |
| A missing or unreadable file | An empty ledger. A daemon that cannot read its own ledger must not refuse to work; it under-counts today and says so by showing what it has. |

---

## `CostState` — what the daemon broadcasts

`Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`. One payload, carrying the whole
truth rather than a delta, for the reason `project/changed` and `workflow/changed` already do: two
windows cannot then disagree, and one that missed a notification is put right by the next rather
than drifting.

| Field | Type | Meaning |
|---|---|---|
| `limits` | `CostLimits` | What the reader has set. |
| `today` | `[String: Decimal]` | What this local day has cost, per currency. Empty until something is spent, so a view shows nothing rather than a zero. |
| `day` | `String` | Which local day `today` is about. A window that has been open across midnight notices the change here rather than by consulting its own clock. |

Derived by the client, never sent: `dayLimitReached`, `dayHeadroom`, `dayIsCloseToFull`.

---

## `Agent` — one new field

`Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`.

| Field | Type | Meaning |
|---|---|---|
| `costCeiling` | `Cost?` | This agent's own ceiling, when the reader has given it one. `nil` means the app-wide `perAgent` limit applies. Set only by the reader, only through `agents/setCeiling`. |

`Agent` already round-trips unknown keys and already encodes `costToDate` only when non-empty; the
new field follows both habits, so an older build reading a newer record neither crashes nor silently
deletes a ceiling the reader set.

This is how FR-016's "let this one go on" is expressed: granting an allowance raises *this agent's*
ceiling and touches nothing else. It also expresses "no limit for this one" and "this one gets a
tighter limit", neither of which the spec asks for and both of which fall out for free.

---

## `Agent` — four computed rules, none stored

In Core, pure, each exhaustible without a daemon. These are what the gates actually read.

| Rule | Returns | Notes |
|---|---|---|
| `ceiling(under: CostLimits)` | `Cost?` | `costCeiling` if set, else `limits.perAgent`. One line, and the only place precedence is decided. |
| `isAtCostLimit(under:)` | `Bool` | `costToDate[currency] >= ceiling.amount`. False when there is no ceiling, and false when the agent is unmeasured. |
| `costHeadroom(under:)` | `Decimal?` | What is left before it stops. `nil` when uncapped, which is how `ContextMeter` knows to show nothing. |
| `costIsUnmeasured` | `Bool` | A turn has ended and reported no cost at all — `lastTurnUsage != nil && lastTurnUsage?.cost == nil && costToDate.isEmpty`. Never capped, never counted, always labelled. |

Deliberately absent: any stored flag, any `AgentState` case, any change to
`AgentState.applying(_:endedReason:)`. Lowering a limit is instantly correct for every agent that
exists, which a stored flag would not be. See [research.md §5](./research.md).

---

## `EndedReason` — one new case

`Packages/AgentsKit/Sources/AgentsKitCore/Model/EndedReason.swift`.

| Case | `summary` | `isFinish` | Reached by |
|---|---|---|---|
| `costLimit` | "Reached its cost limit" | `false` | `finishTurn`, on the turn that crossed the ceiling |

Not one of the protocol's stop reasons, so it takes its place alongside `processDied` and
`daemonGone` as an ending the app itself knows about. `init?(stopReason:)` is untouched — nothing on
the wire ever spells this.

Adding the case to the existing `summary` switch is what makes the phone and the window say the same
words, which is the reason that switch lives in Core and is stated in its own comment.
`AgentState.applying` already sends any `turnEnded` reason that is not `endTurn` to `.stopped`, so
the transition table needs no change at all.

---

## `WorkflowRefusal` — one new case

`Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowOutcome.swift`.

| Case | `message` | `needsAPerson` |
|---|---|---|
| `dayLimitReached` | "the day's spending limit has been reached" | `false` |

Grey, not coloured: midnight resolves it with nobody doing anything, which is the same shape as
`missedWhileClosed`. `isSameReason(as:)` gets the flat case alongside the others, so a workflow
refused twenty times over an exhausted evening collapses to one row with a count rather than twenty
entries.

Fed in through `Workflow.refusalIfBlocked(…)`, which already takes every blocking condition as a
parameter and stays pure.

---

## Where each fact lives

| Fact | Home | Survives a restart |
|---|---|---|
| The reader's two limits | `limits.json` at the daemon root | Yes |
| What each local day cost | `spend.json` at the daemon root | Yes |
| One agent's own ceiling | That agent's `agent.json` | Yes |
| What an agent has spent | `costToDate` on that agent, as today | Yes |
| Whether an agent is at its limit | Computed on demand | Not stored |
| Whether the day's limit is reached | Computed on demand in the daemon, broadcast as part of `CostState` | Not stored |
| Which agents are holding | Not stored anywhere. A held agent is an ordinary settled agent with an undrained queue. | n/a |

One daemon root is one set of limits and one day, so a branch build pointed at its own root has its
own budget — consistent with how `StoreLocations` already treats the root as the daemon's identity.
