# Data Model: A Restarted Background Service Picks Up the Chats That Were Working

One new persisted field, one new derived rule, and two pieces of daemon-only memory that already
exist. Nothing else about the model changes: no new entity, no new state, no change to the
transition table.

---

## `Agent` (persisted) — `AgentsKitCore/Model/Agent.swift`

### New field

| Field | Type | Default | Meaning |
|---|---|---|---|
| `restartPickUps` | `Int` | `0` | How many times in a row this chat has been picked back up after the daemon went, without a turn since reaching its own end. |

**Why it is on the record and not in memory**: the event it counts is the daemon dying. A count
held anywhere else is reset by the very thing it exists to bound.

**Write ordering**: incremented and saved *before* the restart words are sent, never after. A
daemon killed part-way through starting a runtime has therefore already written down that it tried,
and the next daemon does not try again.

**Clearing**: set to `0` whenever a turn ends for any reason other than `daemonGone`, in
`DaemonCore.move(_:on:)` where `turnEnded` is handled. Any ending other than `daemonGone` is
evidence that the chat can reach the end of a turn without taking the daemon with it, which is the
only question the count is asking.

**Compatibility**: `Agent` has a hand-written `init(from:)` and carries `unknownFields` so that
"opening a record in an older build and saving it does not quietly delete them". The new field
decodes with `decodeIfPresent(...) ?? 0`, so every existing record on disk reads as zero — which
is the correct value for a chat that has never been picked back up. `restartPickUps` must be added
to `CodingKeys` so it is not itself swept into `unknownFields`.

### New derived rule

```
Agent.mayBePickedUpAfterRestart: Bool
    state == .stopped
    && endedReason == .daemonGone
    && restartPickUps == 0
```

Pure, on `Agent`, in Core: a unit test exhausts it without a daemon, and both platforms can ask it.
The threshold is one — FR-016 says "not picked back up a second time in a row".

---

## `DaemonCore` (in memory) — unchanged shapes, new rules

| Field | Type | Already exists | What changes |
|---|---|---|---|
| `interrupted` | `[UUID: AgentState]` | Yes | Gains a removal in `stop()`. Still the once-only claim on a pick-up: `pickUp` opens with `removeValue(forKey:)` and returns when it finds nothing. |
| `resuming` | `Set<UUID>` | Yes | Gains a removal in `stop()`, and is now observable: every insert and remove broadcasts `agent/resuming`, and `agents/resuming` reports it to a window that connects late. |

`resuming` remains the answer to "is this work in hand" for `isHoldingAgents`, which is what keeps
an idle daemon from exiting out from under a chat that has no runtime yet.

---

## Lifecycle of one interrupted chat

```
  daemon starts
        │
        ▼
  recover()                     state → .stopped, endedReason → .daemonGone
        │                       interrupted[id] = what it was doing
        │                       transcript: "This agent was working when the daemon stopped…"
        │                       eligible? mayBePickedUpAfterRestart
        │
        ├── no ──▶ left stopped, transcript says it is at its pick-up limit    [FR-016]
        │
        ▼ yes
  socket opens                  windows may now connect
        │
        ▼
  pickUpAfterRestart(ids)       ids sorted by lastActivityAt, most recent first
        │                       resuming ∪= ids  ─────▶ broadcast agent/resuming (true)
        │
        ▼  one at a time
  pickUp(id)
        │  restartPickUps += 1, saved
        │  restart words enqueued at the FRONT of queuedPrompts
        │  prompt(…)  ──────────────────────────────────────────┐
        │                                                       │
        ├── threw ──▶ words removed from queue        [FR-014]   │
        │            transcript: "Could not pick this agent      │
        │            back up: … Send it a message yourself."     │
        │                                                        ▼
        ▼ returned                                    state → .running
  resuming ∖= {id}  ──────▶ broadcast agent/resuming (false)
        │
        ▼
  turn ends (any reason but daemonGone) ──▶ restartPickUps = 0   [FR-017]
```

At any point before `prompt` is called, `stop()` removes the id from `interrupted` and `resuming`,
and the pick-up does not happen. [FR-021]

---

## Entities from the spec, mapped

| Spec entity | Where it lives |
|---|---|
| **Chat** | `Agent` on the record. Eligible for pick-up only when `mayBePickedUpAfterRestart`. |
| **Interruption record** | `DaemonCore.interrupted`, in memory, held only until the chat has been told. Deliberately not persisted: it exists to choose between two sentences, and the choice is made within seconds of the daemon starting. |
| **Restart explanation** | `Agent.wordsAboutTheRestart(_:)`, already written, keyed on what the chat was doing. Never stored as pending work — removed from the queue rather than deferred if it cannot be sent now. |
| **Pick-up attempt count** | `Agent.restartPickUps`. |

---

## What is deliberately *not* modelled

- **No `EndedReason` case for "at its pick-up limit".** The chat's ending is still `daemonGone` —
  that is what happened to it. Why it was not brought back is a line in the transcript, not a
  different ending, because the ending is a fact about the chat and the limit is a fact about the
  app's decision.
- **No `AgentState.resuming`.** See `research.md` §1.
- **No record of who was picked up in a given daemon run.** It would be a log, and `DaemonLog`
  already writes one.
