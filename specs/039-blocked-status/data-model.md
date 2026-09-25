# Data Model: Blocked Status

All in `AgentsKitCore`. Every new field is optional, so records written before this build load
unchanged.

## WorkOutcome (changed)

| Case | Wire | `needsAPerson` | `heading` |
|------|------|----------------|-----------|
| done … stuck | unchanged | unchanged | unchanged |
| **blocked** | `"blocked"` | **false** | "Blocked" |

## WorkReport (changed)

| Field | Type | Notes |
|-------|------|-------|
| outcome, message, at | unchanged | |
| **block** | `Block?` | Present exactly when `outcome == .blocked`. Missing on a blocked report means "waits on nothing, no time", which is FR-003. |

Decoding: an unrecognised `outcome` makes the whole report `nil` instead of failing the agent
record (research R8).

## Block (new, `Model/Block.swift`)

| Field | Type | Notes |
|-------|------|-------|
| waits | `[Wait]` | In the order the agent named them. Empty is allowed. |
| checkAgainAt | `Date?` | Absolute time, worked out from `check_again_in_minutes` when the report lands. |
| clearedAt | `Date?` | Set once, in the same write that queues the resume, or when the block is dropped. |
| clearedBy | `Clearing?` | `.waits`, `.time`, `.dropped` (stop or archive). A person's prompt doesn't set this: it removes the whole report. |

Derived:
- `isOpen`: `clearedAt == nil`.
- `allWaitsClosed`: every `wait.ending != nil`. Vacuously true for no waits, but a block with no
  waits and no time never resumes by itself (see the rule below).
- `isDue(now)`: `checkAgainAt.map { $0 <= now } ?? false`.
- **Resume rule**: `isOpen && ((!waits.isEmpty && allWaitsClosed) || isDue(now))`.

Constants: `checkAgainMinutes = 1...1440`.

## Wait (new)

| Field | Type | Notes |
|-------|------|-------|
| agentID | `UUID` | Always an id, even if the agent named it by title. |
| nameAtReport | `String` | Its title when the block was made. Used in the resume prompt if the agent has gone. |
| ending | `WaitEnding?` | `nil` while open. Set once, when it closes. |

## WaitEnding (new)

| Field | Type | Notes |
|-------|------|-------|
| at | `Date` | |
| how | enum | `.finished(outcome: WorkOutcome?, message: String?)`, `.stopped(EndedReason?)`, `.archived`, `.gone` |

This is copied at the moment the wait closes, because the waited-on agent's report can change
afterwards.

## AgentGroup (changed)

`.blocked`, title "Blocked". `live = [.needsAttention, .blocked, .running, .finished, .stopped]`.

Grouping for `.finished`, and for `.running where outcomeAsked`:

```
wantsEyes || report.needsAPerson        → needsAttention
report.outcome == .blocked && block open → blocked
otherwise                                → finished
```

`.stopped` and `.archived` are unchanged, so stopped and archived outrank blocked (FR-012). A
`.running` agent with a blocked report is being resumed: it is `.running`, because the resume
cleared the block first.

Counts decoding drops unknown keys (R8).

## AgentEvent / state table (changed)

| Event | From | To | endedReason |
|-------|------|----|-------------|
| **stoppedWaiting(byAgent: Bool)** | finished | stopped | `.stoppedByUser`, or `.stoppedByAgent` |

It is rejected from every other state. Only `stop(_:by:)` sends it, and only for a finished
agent with an open block.

## StatusShape (changed)

`.blocked` for `state == .finished && report is blocked && block open`. It has its own icon and
accessibility words ("Blocked"), and is neither `.needsYou` nor `.done`.

## Lifecycle of one block

```
finish_turn(blocked, waiting_on, check_again) ── checks (contract §2) ──▶ refused, nothing written
        │ accepted
        ▼
report.block (open) ── person prompts ──────────────────▶ report = nil (block gone, FR-015)
        │            ── stop / archive ─────────────────▶ clearedBy .dropped (FR-017)
        │            ── later finish_turn ──────────────▶ replaced (new report)
        │ each waited-on agent ends ─▶ wait.ending set
        ▼
all waits closed, or due ── agent is finished, queue empty ──▶ one write: clearedAt + queued .app prompt
        │
        ▼
sendNextQueued ── ok ──▶ running (resumed turn, which may end blocked again)
                └ fails or held ──▶ resume prompt removed, report := stuck(reason) (FR-018)
```
