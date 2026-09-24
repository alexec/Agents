# Data Model: The Mac Stays Awake While Its Agents Work

**Feature**: 024-keep-host-awake | **Date**: 2026-09-23

## The shape of it

Nothing in this feature is persisted. That is the design, not an omission, and it follows
from FR-013 and FR-014: the hold dies with the process that took it (verified — see
`research.md` §2), and whether to hold is worked out from what the agents are doing now
rather than restored. A record on disk saying "a hold was taken" could only ever be a lie
waiting to be believed by the next daemon.

So there is no new file, no change to `agent.json`, and no new key anywhere in
`~/Library/Application Support/Agents/`. Everything below lives in memory in `agentsd`, or
on the wire.

```
     agents ─────┐
                 ├──▶  WakeVerdict  ──▶  Wakefulness (held / not held)
  PowerReading ──┘         │
                           └──────────▶  WakeState  ──▶  wake/state  ──▶  window
```

One derivation, two consumers: the assertion itself, and the sentence on screen.

---

## 1. `WorkInFlight` — the agent-side input

Not a type of its own. A computed property on `DaemonCore`, beside `isHoldingAgents` and
deliberately *not* part of it (`research.md` §6).

```swift
/// Whether any agent is mid-turn, which is the only agent-side reason to hold the
/// Mac awake (FR-002).
///
/// Neighbour to `isHoldingAgents` and **not** the same question. That one asks
/// whether the daemon may exit, and answers yes for an agent waiting on a person,
/// for a busy shell and for a pending permission. This one asks whether a turn is
/// computing. An agent blocked on a person is explicitly excluded (FR-003): holding
/// the Mac awake all night for an unanswered question is the one abuse this feature
/// must not commit.
var hasWorkInFlight: Bool {
    agents.values.contains { $0.state == .starting || $0.state == .running }
}
```

| Agent state | Holds? | Why |
|---|---|---|
| `starting` | **Yes** | The session is being made and its first turn is about to begin. FR-002. |
| `running` | **Yes** | A turn is computing. The whole feature. |
| `waitingOnUser` | No | Blocked on a person. FR-003, and US2 scenario 2. |
| `finished` | No | |
| `stopped` | No | |
| `archived` | No | |

**Why not `AgentState.hasTurnInFlight`.** That existing property answers `true` for
`waitingOnUser` too, and its doc comment says why — a permission question is asked *in the
middle* of a turn. It is right about the conversation being busy and wrong for this feature,
which is about the CPU being busy. The two are named apart on purpose; a task will add a
cross-reference comment to each so the next reader does not "fix" one into the other.

---

## 2. `PowerReading` — the machine-side input

```swift
/// What the machine says about its own power, read fresh each time.
public struct PowerReading: Hashable, Sendable {
    /// Nil on a Mac with no battery — a desktop, which FR-012 treats as mains.
    public var batteryPercent: Int?
    public var isOnMains: Bool
}
```

Read through an injected protocol so tests need no hardware (`research.md` §9):

```swift
public protocol PowerSource: Sendable {
    func read() -> PowerReading
}
```

- `IOKitPowerSource` — the real one. `IOPSGetProvidingPowerSourceType` for `isOnMains`;
  `kIOPSCurrentCapacityKey` divided by `kIOPSMaxCapacityKey` for the percentage, because
  max is not reliably 100 on an aged battery. An empty source list means no battery.
- `FakePowerSource` — a test's own answer, settable between calls so a test can cross the
  floor mid-turn (US3 scenario 3) without a laptop discharging.

**Validation**: `batteryPercent` is clamped to `0...100`. A reading that cannot be made at
all — IOKit returning nothing — is treated as mains, i.e. *hold*. That default is chosen
deliberately: the failure mode of holding wrongly is a Mac that stays awake, and the failure
mode of releasing wrongly is a lost turn. The first is visible and recoverable; the second
is silent.

---

## 3. `WakeVerdict` — the derivation

The whole of the feature's logic, as one pure function over the two inputs above. Pure so
it can be exhausted in unit tests with no daemon at all.

```swift
/// Whether the Mac should be held awake, and if not, why not.
public enum WakeVerdict: Hashable, Sendable {
    /// Hold it. A turn is in flight and power allows.
    case hold
    /// Nothing is computing. The ordinary case, and the one the person never sees.
    case idle
    /// A turn is in flight, but the battery is at or below the floor (FR-010).
    /// Kept apart from `idle` solely because FR-016 requires the person be told
    /// these are different situations.
    case batteryTooLow(percent: Int)
}

public enum Wake {
    /// The reserve below which a laptop on battery is left to sleep (FR-010).
    /// One figure, not a setting — see the spec's Assumptions.
    public static let batteryFloorPercent = 20

    public static func verdict(workInFlight: Bool, power: PowerReading) -> WakeVerdict {
        guard workInFlight else { return .idle }
        if power.isOnMains { return .hold }                    // FR-009
        guard let percent = power.batteryPercent else { return .hold }  // FR-012
        return percent > batteryFloorPercent                   // FR-010
            ? .hold
            : .batteryTooLow(percent: percent)
    }
}
```

The truth table this has to satisfy, taken straight from the acceptance scenarios:

| Work in flight | Mains | Battery | Verdict | From |
|---|---|---|---|---|
| no | — | — | `idle` | US2-1 |
| yes | yes | 5% | `hold` | US3-1, FR-009 |
| yes | no | 77% | `hold` | US3-2 |
| yes | no | 20% | `batteryTooLow` | FR-010, "at or below" |
| yes | no | 19% | `batteryTooLow` | US3-3 |
| yes | no | none | `hold` | US3-5, FR-012 |
| yes | no → yes | 9% | `hold` | US3-4, on re-reading |

Note the boundary: the floor is *inclusive*, because FR-010 says "reaches or falls below".

---

## 4. `Wakefulness` — the assertion itself

```swift
/// The one claim on the Mac's idle sleep. At most one is ever held (FR-006).
public protocol Wakefulness: AnyObject, Sendable {
    func hold(reason: String)
    func release()
}
```

- `ProcessInfoWakefulness` — `beginActivity(options: [.idleSystemSleepDisabled], reason:)`,
  keeping the returned token; `endActivity` on release. Holding when already held, or
  releasing when not held, does nothing — the idempotence `reviseWakefulness()` relies on.
- `RecordingWakefulness` — a test's spy: counts holds and releases and keeps the reasons, so
  a test can assert *taken once across three overlapping agents* (US1-3) and *never taken*
  for an agent waiting on a person.

**The reason string** is carried verbatim into `pmset -g assertions` (verified,
`research.md` §1), so it is written for a person reading a terminal at midnight, and it is
specific enough to tell apart from the assertion 005 §10 will one day add in the bridge:

```
Agents: 2 agents are mid-turn
```

**Invariant**: exactly one hold outstanding at a time, in one process. Not a pool, not one
per agent. `reviseWakefulness()` is the only caller of either method.

---

## 5. `WakeState` — what crosses the wire

Modelled on `DaemonAPI.CostState` (`research.md` §8).

```swift
extension DaemonAPI {
    /// Why the Mac is, or is not, being kept awake. Broadcast on change and
    /// fetchable on connect, exactly as `CostState` is.
    public struct WakeState: Codable, Hashable, Sendable {
        /// True while the assertion is held (FR-015).
        public var isHolding: Bool
        /// How many agents are mid-turn. Zero when not holding for lack of work.
        public var agentsInFlight: Int
        /// Set when work is in flight but the battery floor released the hold
        /// (FR-016). This is the field that makes "nothing is running" and
        /// "running, but your battery is low" different sentences.
        public var heldBackByBattery: Bool
        /// The reading behind the two flags above, for the words on screen.
        public var batteryPercent: Int?
        /// When the current hold was taken. Nil when not holding.
        public var since: Date?
    }
}
```

The three states a window can be in, and what each says:

| `isHolding` | `heldBackByBattery` | What the footer shows |
|---|---|---|
| `false` | `false` | nothing at all (FR-015) |
| `true` | `false` | "Keeping this Mac awake · 2 agents working" |
| `false` | `true` | "Letting this Mac sleep · battery at 18%" |

Unknown fields are not a concern here the way they are on `Agent`: this is an event about
right now, not a record that round-trips through an older build.

---

## 6. Held on the client

```swift
// AgentsModel
public private(set) var wakeState: DaemonAPI.WakeState?
```

Nil means *not yet heard from*, which is different from *not holding* and is drawn the same
way — as nothing. A window that connects mid-hold fills this by calling
`DaemonAPI.Method.wakeState` on connect, tolerating method-not-found from an older daemon,
exactly as `AppModel.swift:332` does for cost.

---

## State transitions

The hold has two states and the transitions are all derived, never commanded. There is no
event anyone can send to take or release it.

```
                 reviseWakefulness()
                         │
   ┌─────────────┐  verdict == .hold   ┌──────────────┐
   │ not holding │ ──────────────────▶ │   holding    │
   │             │ ◀────────────────── │              │
   └─────────────┘  verdict != .hold   └──────────────┘
          ▲                                    │
          └──────── process dies ──────────────┘
                (kernel drops it; no code)
```

`reviseWakefulness()` is called from exactly three places (`research.md` §5):

| Call site | Covers | Requirement |
|---|---|---|
| `DaemonCore.changed(_:)` | every agent write worth telling a window about | FR-001, FR-004 |
| `tickWorkflows(now:)`, every 15 s | power source and charge; backstop | FR-010, FR-011 |
| end of `Daemon.start()` | a daemon restarting under resumed agents | FR-014 |

It is idempotent and compares before acting — `changed(_:)` runs on every token of streamed
output, so it must do nothing when nothing moved.

---

## What is deliberately absent

| Not built | Why |
|---|---|
| Any persisted record of the hold | FR-013 — the kernel drops it on death; persistence could only mislead the next daemon |
| A start-up sweep for a stale hold | Same; verified in `research.md` §2 |
| One assertion per agent | FR-006 — at most one, ever |
| A user setting to turn it off | Spec's Assumptions; a follow-up if it proves wrong |
| A maximum duration on the hold | Spec's edge cases — the cost ceilings of 010 are the brake on a runaway agent |
| `PreventUserIdleDisplaySleep` | FR-007 — the display is not ours to hold |
| Holding for a busy shell | `research.md` §6 — a build is not a turn; noted as the obvious follow-up |
| A `notify(3)` C shim target | `research.md` §4 — the 15 s tick is enough and needs no new build surface |
