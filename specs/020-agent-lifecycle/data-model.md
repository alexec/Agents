# Phase 1 Data Model: An Agent Being Born Is Not a Finished One

**Feature**: 020-agent-lifecycle | **Date**: 2026-09-19

Everything here lives in `Packages/AgentsKit/Sources/AgentsKitCore/Model/`, which both the
daemon and both apps link. Nothing in this feature is new storage: it is one new state, one
new shape for the answer the transition gives, and two gates on the record.

---

## AgentState

`AgentState.swift`. Gains one case. The five that exist keep their meanings and their
spellings on the wire.

| Case | Wire | Meaning | `holdsRuntime` | `hasTurnInFlight` |
| --- | --- | --- | --- | --- |
| `starting` *(new)* | `starting` | It exists, a runtime is being made or is made, its conversation has not begun | **true** | **true** |
| `running` | `running` | A turn is in flight | true | true |
| `waitingOnUser` | `waitingOnUser` | Blocked mid-turn on a permission or a form | true | true |
| `finished` | `finished` | A turn ended in `endTurn` | false | false |
| `stopped` | `stopped` | Ended any other way | false | false |
| `archived` | `archived` | Put away by the person | false | false |

`starting` answers **true** to both computed properties, and both answers are load-bearing:

- `holdsRuntime` — the session really is made before the record exists
  (`DaemonCore+Commands.swift:149` runs after `freshSession`), so there is a process to
  account for and `runUntilIdle` must not exit under it. `AppModel.swift:859` also reads it
  to count what a runtime is holding.
- `hasTurnInFlight` — the turn it was created for is about to begin. `enqueue`
  (`DaemonCore+Commands.swift:302`) and `sendNextQueued` (line 324) both gate on this, so a
  prompt arriving while an agent starts queues rather than racing (FR-004), with no new
  code.

### Validation

- A `starting` agent has no `endedReason` and no `archivedReason`.
- `starting` is producible only by `Agent.init` — no transition returns it.

---

## AgentEvent

`AgentState.swift`. One new case; the reason each carries is now the event's own.

| Case | New | Reason it implies |
| --- | --- | --- |
| `promptSent` | | — |
| `turnBegun` | **yes** | — (`starting` → `running` only) |
| `permissionAsked` | | — |
| `permissionAnswered` | | — |
| `turnEnded(EndedReason)` | | its own payload |
| `stoppedByUser` | | `cancelled` |
| `processDied` | | `processDied` |
| `foundDead` | | `daemonGone` |
| `archivedByUser` | | archive reason `byUser` |
| `unarchivedByUser` | | leaves the existing ending alone |

`turnBegun` exists because `beginTurn` is reached two ways: as the first turn of a new
agent, where the state is `starting`, and as an ordinary prompt to a settled agent, where
it is `promptSent`. Keeping them separate is what lets `(.starting, .promptSent)` be
refused — a prompt arriving during a start must queue, not begin a turn (FR-004).

**A second event, `startFailed(EndedReason)`, was designed and then dropped.** It would
have been legal only from `starting`, but `start(_:)` makes the session before it
constructs the `Agent`, so a runtime that will not start leaves no record to transition —
the error throws to the caller and no agent is ever made. The event would have shipped
with no call site, which is exactly what `foundDead` was. See the note at the head of
[contracts/transitions.md](contracts/transitions.md).

---

## Transition *(new)*

`AgentState.swift`. What `applying` returns instead of a bare `AgentState?`. `nil` still
means the event must not happen in this state.

```
struct Transition: Hashable, Sendable {
    var next: AgentState
    var endedReason: ReasonChange
    var archivedReason: ArchiveChange
    var clearsPickUpCount: Bool
}

enum ReasonChange  { case set(EndedReason), leave }
enum ArchiveChange { case set(Agent.ArchivedReason), clear, leave }
```

Three small enums rather than `EndedReason??`, because the third case is real:
`unarchivedByUser` leaves the ending alone, and `promptSent` clears the archive reason.

### Rules the value carries

- **`clearsPickUpCount`** = `next` is settled **and** the resulting `endedReason` is not
  `daemonGone`. This is FR-015, and it is the first of the two reasons the bypass existed.
  It moves out of `DaemonCore.swift:242` into the pure function so a test can exhaust it.
- **Totality.** `applying` is total over every `(AgentState, AgentEvent)` pair — 6 × 10 =
  60 — and each pair has exactly one answer: a `Transition` or `nil` (SC-003).
- **No other producer.** `Agent.state` is settable only from `Agent.init`, from applying
  a `Transition`, and — **as built** — from `AgentStore.mended`, which repairs a record
  the invariants forbid before it is an agent anything holds. That third one cannot go
  through the table: the table is total over events that happen to an agent, and "this
  record was already wrong when we read it" is not one of them. It is named in the
  source scan's allow-list rather than hidden. This is the FR-008 claim, and SC-009 is
  how it is checked.

### Signature

```
func applying(_ event: AgentEvent, endedReason: EndedReason?) -> Transition?
```

The parameter keeps its current meaning — the agent's *existing* ending, which only
`unarchivedByUser` reads, to decide whether an unarchived agent returns to `finished` or
`stopped`. It is no longer how a caller supplies a *new* reason (FR-011).

---

## Agent

`Agent.swift`. No new field **on the wire**; one new field in memory.

| Change | Why |
| --- | --- |
| `init` default `state` becomes `.starting`, `endedReason` defaults to `nil` | FR-002. The call site at `DaemonCore+Commands.swift:149` stops passing `state:` and `endedReason:` entirely |
| `isConsistent` gains: `starting` ⇒ no `endedReason` and no `archivedReason` | The new state's own invariant |
| `init(from:)` decodes `state` leniently | D7 / FR-021 |
| `var rawState: String?`, **not** in `CodingKeys` | Holds the state string a newer build wrote, so `encode` can put it back. Kept out of `CodingKeys` because the `known` set that `unknownFields` is filtered against is built from it. Being an optional `var`, Swift defaults it to `nil`, so no `Agent(...)` call site changed. Cleared by `move` the moment a transition writes a state of our own |

### `isConsistent`, complete

1. `archived` ⇒ has an `archivedReason`
2. `stopped` ⇒ has an `endedReason`
3. `finished` ⇒ `endedReason == .endTurn`
4. `starting` ⇒ no `endedReason` and no `archivedReason` *(new)*

Today these are asserted in `AgentStoreTests.swift` and enforced nowhere. After this
feature they are checked on every write and every read (FR-018, FR-020).

**As built**, the order in the decoder matters: `state` is read near the top of
`init(from:)` and `endedReason` some thirty lines below it, so the lenient decode
re-asserts `endedReason = .unrecognised` *after* that line. A state this build cannot
reason about makes whatever reason the record gave meaningless.

### Lenient state decoding

`state` is a `String` raw-value enum, so an unknown value throws from `decode`, fails the
whole `Agent`, and `loadAll` (`AgentStore.swift:40`) files it under `unreadable` — the
agent disappears from the app with no trace a person can see.

Instead: an unrecognised string decodes to `.stopped` with `endedReason = .unrecognised`,
and the original string is kept so `encode` writes it back out rather than deleting what a
newer build knew (FR-021). `EndedReason.unrecognised` already means precisely this, and
`WorkOutcome.init(wire:)` already takes the same position for the same reason.

### Backward compatibility

No migration. Every record written before this feature is in one of the five states that
still exist, decodes unchanged, and satisfies all four invariants — `starting` is a state
nothing written earlier can be in. The only new thing on the wire is the string `starting`,
and it appears only for the seconds an agent is being made.

---

## AgentGroup

`AgentGroup.swift`. One line, and the mapping stays total over `AgentState`.

```
case .starting: self = .running
```

A starting agent is grouped under **Working**. No heading is added, renamed or removed
(FR-023, FR-006). `AgentGroupTests` exhausts the mapping and will require the new case,
which is the point.

---

## TranscriptEntry

`TranscriptEntry.swift`. No change. `case stateChanged(AgentState, reason: EndedReason?)`
already carries what is needed, and recovery already writes one by hand — it will now be
written by `move` instead, which is the same entry from one place (FR-013).

Two new `runtimeNote` texts are needed, for a mended record (FR-020) and for a state from a
newer build (FR-021). Wording is settled in tasks.

---

## AgentStore

`AgentStore.swift`. Two gates.

| Method | Change |
| --- | --- |
| `save(_:)` | Refuses a record failing `isConsistent`; throws, and logs which agent and which rule (FR-018, FR-019) |
| `load(_:)` | Mends a record failing `isConsistent` to the nearest state the rules allow, and reports that it did, so the caller can write the transcript line (FR-020) |

`loadAll` keeps skipping records that will not decode at all — a truncated or corrupt file
is a different thing from a well-formed record in a forbidden state, and one bad file still
must not stop the daemon starting.

Callers to check: `save` is called from `DaemonCore.saveQuietly` (which swallows with
`try?`, so the log line in `save` is the only evidence) and directly from the create path
and `recover`.

---

## Entity relationships

```
Agent ──has──> AgentState ──(AgentEvent)──> Transition ──writes──> Agent
  │                  │
  │                  └──derives──> AgentGroup   (never stored)
  │
  ├──has──> EndedReason?      set only by a Transition
  ├──has──> ArchivedReason?   set only by a Transition
  └──has──> restartPickUps    cleared only by a Transition
```

The arrow that does not exist after this feature is the one from any other code directly
into `Agent.state`.
