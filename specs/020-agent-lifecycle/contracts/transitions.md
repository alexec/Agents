# Contract: The Transition Table

**Feature**: 020-agent-lifecycle

The whole of what may happen to an agent. Total over 6 states × 10 events = **60 pairs**,
each with exactly one answer (SC-003). `—` means the event must not happen in that state,
and the agent is left entirely unchanged (FR-010).

A row's answer is a `Transition`: the next state, what happens to `endedReason`, what
happens to `archivedReason`, and whether the restart pick-up count is cleared.

Columns: **next** · **ended** · **archived** · **clears pick-up count**

---

## A note on the event that is not here

An earlier draft of this contract had an eleventh event, `startFailed(EndedReason)`,
legal only from `starting`. It was **dropped before implementation**, and the table is
60 pairs rather than 66.

`start(_:)` makes the session — `freshSession` — *before* it constructs the `Agent`. So
a runtime that will not start leaves no record to transition: the error throws to the
caller exactly as it always did, and no agent is ever made. Between the record being
written and `beginTurn`, only `prepareServing` and `session.apply` run, and neither
reports a start failure. The event would have had no call site, which is precisely the
`foundDead` disease this feature exists to cure.

If the create path is ever reordered so the record is written first — which would make a
slow start watchable in the list — `startFailed` becomes reachable and should come back.
That is a feature of its own.

## From `starting`

| Event | Next | Ended | Archived | Clears |
| --- | --- | --- | --- | --- |
| `promptSent` | — | | | |
| `turnBegun` | `running` | leave | leave | no |
| `permissionAsked` | — | | | |
| `permissionAnswered` | — | | | |
| `turnEnded(r)` | — | | | |
| `stoppedByUser` | `stopped` | set `cancelled` | leave | yes |
| `processDied` | `stopped` | set `processDied` | leave | yes |
| `foundDead` | `stopped` | set `daemonGone` | leave | **no** |
| `archivedByUser` | — | | | |
| `unarchivedByUser` | — | | | |

`promptSent` is refused: a prompt arriving while an agent starts joins the queue (FR-004).
It is refused by the table, not only by the daemon's `hasTurnInFlight` guard, so the rule is
where it can be read.

`archivedByUser` is refused for the same reason it is from `running` — stop it first.

## From `running`

| Event | Next | Ended | Archived | Clears |
| --- | --- | --- | --- | --- |
| `promptSent` | — | | | |
| `turnBegun` | — | | | |
| `permissionAsked` | `waitingOnUser` | leave | leave | no |
| `permissionAnswered` | — | | | |
| `turnEnded(r)` | `finished` if `r == endTurn`, else `stopped` | set `r` | leave | yes unless `r == daemonGone` |
| `stoppedByUser` | `stopped` | set `cancelled` | leave | yes |
| `processDied` | `stopped` | set `processDied` | leave | yes |
| `foundDead` | `stopped` | set `daemonGone` | leave | **no** |
| `archivedByUser` | — | | | |
| `unarchivedByUser` | — | | | |

## From `waitingOnUser`

| Event | Next | Ended | Archived | Clears |
| --- | --- | --- | --- | --- |
| `promptSent` | — | | | |
| `turnBegun` | — | | | |
| `permissionAsked` | — | | | |
| `permissionAnswered` | `running` | leave | leave | no |
| `turnEnded(r)` | `finished` if `r == endTurn`, else `stopped` | set `r` | leave | yes unless `r == daemonGone` |
| `stoppedByUser` | `stopped` | set `cancelled` | leave | yes |
| `processDied` | `stopped` | set `processDied` | leave | yes |
| `foundDead` | `stopped` | set `daemonGone` | leave | **no** |
| `archivedByUser` | — | | | |
| `unarchivedByUser` | — | | | |

## From `finished`

| Event | Next | Ended | Archived | Clears |
| --- | --- | --- | --- | --- |
| `promptSent` | `running` | leave | clear | no |
| `turnBegun` | — | | | |
| `permissionAsked` | — | | | |
| `permissionAnswered` | — | | | |
| `turnEnded(r)` | — | | | |
| `stoppedByUser` | — | | | |
| `processDied` | — | | | |
| `foundDead` | — | | | |
| `archivedByUser` | `archived` | leave | set `byUser` | no |
| `unarchivedByUser` | — | | | |

## From `stopped`

Identical to `finished`.

| Event | Next | Ended | Archived | Clears |
| --- | --- | --- | --- | --- |
| `promptSent` | `running` | leave | clear | no |
| `turnBegun` | — | | | |
| `permissionAsked` | — | | | |
| `permissionAnswered` | — | | | |
| `turnEnded(r)` | — | | | |
| `stoppedByUser` | — | | | |
| `processDied` | — | | | |
| `foundDead` | — | | | |
| `archivedByUser` | `archived` | leave | set `byUser` | no |
| `unarchivedByUser` | — | | | |

## From `archived`

| Event | Next | Ended | Archived | Clears |
| --- | --- | --- | --- | --- |
| `promptSent` | `running` | leave | clear | no |
| `turnBegun` | — | | | |
| `permissionAsked` | — | | | |
| `permissionAnswered` | — | | | |
| `turnEnded(r)` | — | | | |
| `stoppedByUser` | — | | | |
| `processDied` | — | | | |
| `foundDead` | — | | | |
| `archivedByUser` | — | | | |
| `unarchivedByUser` | `finished` if ended `== endTurn`, else `stopped` | see below | clear | yes, unless the ending is `daemonGone` |

### Unarchiving an agent with no recorded ending

The current table returns `stopped` for any ending that is not `endTurn`, including none at
all — and a `stopped` agent with no reason breaks invariant 2. It cannot be reached today,
because the only ways into `archived` are from `finished` and `stopped`, which both carry a
reason. It becomes reachable the moment a record is hand-edited or written by another build.

**The contract**: unarchiving to `stopped` with no recorded ending sets `unrecognised`.
Nothing vouched for that ending, which is what `unrecognised` already means everywhere else
in this app. The record always carries a reason.

---

## Rules that hold across the whole table

1. **Totality.** Every one of the 60 pairs has exactly one answer. A test exhausts them;
   none may be left undecided (SC-003).
2. **A refusal changes nothing.** `nil` means the agent is untouched — state, ending,
   archive reason, pick-up count, and when it was last active (FR-010). Today
   `DaemonCore.stop` writes `endedReason = .cancelled` before the table is consulted; that
   write moves inside the transition.
3. **The reason comes from the event.** No caller supplies one alongside (FR-011, FR-012).
   The only reason a caller may pass is the agent's *existing* ending, which only
   `unarchivedByUser` reads.
4. **`daemonGone` never clears the pick-up count** (FR-015). This is the rule that let
   `recover` justify going round the funnel; it now lives in the table.

   The **Clears** column is not written by hand per row — it is derived, once, as *the
   next state is settled (`finished` or `stopped`) **and** the resulting ended reason is
   not `daemonGone`*. Every cell above follows from that, including the one that looks
   surprising: unarchiving lands on a settled state, so it clears the count unless the
   ending it returns to is `daemonGone`. That is what the app has always done, and the
   derivation is exhausted by test rather than transcribed.
5. **Only a `Transition` writes `state`.** Outside `Agent.init`, there is no other producer
   (FR-008, SC-009).

---

## What the daemon does with an accepted transition

In this order, every time, whatever the event (FR-013):

1. Apply the `Transition` to the agent, and set `lastActivityAt`.
2. Write the record — **before** the windows are told, so a daemon killed between the two
   leaves something true behind.
3. Broadcast `agents/changed`, then the project it belongs to.
4. Append `stateChanged(next, reason:)` to the transcript.
5. Emit the lifecycle event for workflows.

### Step 5, in detail

| Next state | Event emitted |
| --- | --- |
| `running` | — (a start is fired elsewhere and is not a state change) |
| `waitingOnUser` | — (`askedPermission` / `askedForm` fire from their own seams, unchanged) |
| `finished` | `finished`, unless held back for the outcome question |
| `stopped` | `stopped`, unless the agent will be picked back up |
| `archived` | — |

Two suppressions, both existing rules made explicit:

- **The outcome question** (014): a `finished` agent the app is about to ask "how did it
  go" fires once, on the second ending, when its answer is on the record. Unchanged —
  `willAskForOutcome` already decides this.
- **The pick-up** (011, FR-016): an agent recovery is about to bring back has not finished
  stopping. Decided by `Agent.mayBePickedUpAfterRestart` on the post-transition agent. An
  agent that will *not* be picked back up fires, which is the behaviour this feature adds.

### Deferral

`recover()` runs before `startWorkflows()`, deliberately. `move` still emits its event; the
workflow layer holds events that arrive before it is started and drains them, in order,
when it is. The funnel has one behaviour regardless of when it runs (FR-014).
