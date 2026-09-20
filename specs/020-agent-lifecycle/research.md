# Phase 0 Research: An Agent Being Born Is Not a Finished One

**Feature**: 020-agent-lifecycle | **Date**: 2026-09-19

Everything here was read out of the codebase rather than assumed. Where a decision had
alternatives, the ones rejected are named.

---

## 1. What the scar tissue actually is

Three claims in the spec, each verified against source.

### 1.1 A new agent is written down as a finished one

`Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:149`

```swift
var agent = Agent(runtimeID: request.runtimeID,
                  cwd: request.cwd,
                  title: Agent.fallbackTitle(from: request.prompt),
                  state: .stopped,
                  …
                  endedReason: .endTurn,
```

The session is made first, then the record. `changed(agent)` is called at line ~172,
before `beginTurn` at line ~175, so the windows are told about an agent that is `stopped`
with reason `endTurn` before its first turn begins. `AgentGroup(for: .stopped)` is
`.stopped`, so for that interval a brand-new agent is listed under **Stopped**.

The `endTurn` is not carelessness — `Agent.isConsistent` requires `state == .stopped` to
have an `endedReason`, and `endTurn` is the only one that carries no user-visible summary
(`EndedReason.summary` returns `nil` for it). It was the cheapest reason that would not
print something false on the row. The falsehood moved into the record instead.

**Finding**: there is no state for *starting*. Everything else in 1.1 follows from that.

### 1.2 `AgentEvent.foundDead` exists and nothing calls it

`AgentState.swift:50` declares it. `AgentState.swift:98` gives it two legal transitions.
The only reference anywhere else is `AgentStateTests.swift:29`, which asserts it cannot
reach `.archived`.

`grep -rn foundDead` over the whole repo, excluding `.build`, returns four hits. None is a
call site.

The caller it was written for is `DaemonCore+Recovery.swift:27`, which does this instead:

```swift
var updated = agent
updated.state = .stopped
updated.endedReason = .daemonGone
agents[id] = updated
try? await store.save(updated)
await record(.runtimeNote(…), for: id)
await record(.stateChanged(.stopped, reason: .daemonGone), for: id)
```

It reproduces, by hand, three of the four things `move` does — and skips the fourth.

**Finding**: the table already anticipated this event. The bypass is not a missing
transition, it is a caller that went round one that exists.

### 1.3 The consequence: stopped triggers never fire on a restart

`workflowsRespond(to: .stopped, …)` has exactly one call site for endings:
`DaemonCore.swift:276`, inside `move`. Recovery does not reach it.

So a workflow with a `stopped` trigger fires when the runtime crashes, when the person
stops an agent, when a turn ends short — and does not fire when the Mac reboots under four
working agents. That is the one case where the person is least likely to be watching.

### 1.4 The invariants are tests, not rules

`Agent.isConsistent` (`Agent.swift:340`) has six references. All six are in
`AgentStoreTests.swift`. `AgentStore.save` does not call it. Nothing does.

---

## 2. Decisions

### D1 — A sixth state, `starting`, rather than a flag or a nil ending

**Decision**: add `AgentState.starting`. `holdsRuntime = true`, `hasTurnInFlight = true`.

**Rationale**: the two computed properties on `AgentState` are what the rest of the daemon
asks, and a starting agent answers yes to both honestly. It holds a runtime — the session
is made before the record exists, so there really is a process to account for, and
`runUntilIdle` must not exit under it. It has a turn in flight — the turn it was created
for is about to begin, and `enqueue` (`DaemonCore+Commands.swift:302`) and `sendNextQueued`
(line 324) both gate on `hasTurnInFlight`, so answering yes is exactly what makes a second
prompt queue instead of racing the first.

**Alternatives rejected**:

- *Leave the state alone and add `isStarting: Bool`.* This is what `wantsEyes` is, and
  `AgentGroup`'s own comment explains why that one is a flag and must never become a state:
  showing a file blocks nothing. Starting blocks everything — it holds a process and owns
  the turn — so it is the opposite case. A flag would also have to be consulted by
  `holdsRuntime` and `hasTurnInFlight`, which are properties of the state and have no
  agent to ask.
- *Allow `stopped` with no `endedReason` for a new agent.* Weakens the one invariant that
  makes an ending trustworthy, to describe an agent that has not ended.
- *A separate `birth` marker outside the state machine.* A seventh place to look for what
  an agent is doing, which is the disease.

**Cost**: `AgentState` is exhaustively switched in 10 places outside `AgentState.swift` —
5 in `App/Sources`, 4 in `Remote/Sources`, and `AgentGroup.swift:66`. Every one becomes a
compile error, which is the feature working: the compiler enumerates the callers, which is
what nobody did when the state was implicit.

One more reads the state and will *not* break: `AgentRow.swift:178` switches with
`default: return .secondary`, so a new state silently takes the secondary tint. It has to
be found by hand. (`NetworkLink.swift:94` switches `NWConnection.State` and is unrelated;
`RuntimeAccountView.swift:117` switches `RuntimeAccount.State`.)

### D2 — The event carries the reason; the transition returns what to write

**Decision**: `applying` returns a `Transition` value — the next state plus what happens to
`endedReason`, `archivedReason`, and the restart pick-up count — instead of a bare
`AgentState?`. `move` loses its `endedReason:` parameter.

**Rationale**: today `move(agentID, on: .turnEnded(reason), endedReason: reason)` passes the
same value twice, and `move(agentID, on: .stoppedByUser, endedReason: .cancelled)` passes
two things that must agree and that nothing checks. Both are places a caller can write an
ending that contradicts its own event. The event already knows: `.stoppedByUser` is
`cancelled`, `.processDied` is `processDied`, `.foundDead` is `daemonGone`,
`.archivedByUser` is `byUser`. Only `.turnEnded` has a reason worth carrying, and it
already carries it.

**Shape**: three small enums rather than double optionals, because `EndedReason??` is
unreadable and the third case is real — `unarchivedByUser` leaves the ending alone, and
`promptSent` clears the archive reason.

```
enum ReasonChange  { case set(EndedReason), leave }
enum ArchiveChange { case set(Agent.ArchivedReason), clear, leave }
```

**Alternatives rejected**:

- *Keep the parameter and assert it matches the event.* An assertion is the same convention
  the two comments already are. Making it unrepresentable costs the same and cannot drift.
- *Derive the reason inside `move`.* Puts the mapping in the daemon, where it cannot be
  exhaustively tested without an actor and a fake runtime. It belongs in Core beside the
  table.

### D3 — The pick-up rule moves into the transition

**Decision**: `Transition.clearsPickUpCount` is computed by the pure function, as
`next is settled && endedReason != .daemonGone`.

**Rationale**: this is one of the two reasons `recover` goes round the funnel, and
`DaemonCore.swift:242` currently states it as an inline `if` with a four-line comment
explaining that `recover` sets the reason directly "so it can never clear the count on its
way past". Once `recover` goes through the funnel, that defence disappears and the rule has
to hold on its own. In the pure function it is exhaustible by test.

### D4 — Trigger firing is deferred, not skipped, during recovery

**Decision**: `move` always emits its lifecycle event. When workflows are not yet started,
the event is held in an ordered queue and drained by `startWorkflows()`.

**Rationale**: this is the hard ordering problem, and it is the reason the bypass looked
reasonable. `Daemon.start()` (`Daemon.swift:31`) runs `recover()` *first*, and
`startWorkflows()` only at line ~54, with a comment saying why: "After recovery, so a
workflow is never fired at an agent the daemon has not yet worked out is dead." Routing
recovery through `move` naively would call `workflowsRespond` before any workflow is
loaded, and it would silently do nothing — trading a visible bypass for an invisible one,
which is worse.

Deferring keeps the funnel total: `move` has one behaviour, always. The workflow layer
decides when it is able to act, which is the workflow layer's business.

**Alternatives rejected**:

- *Start workflows before recovery.* Breaks the stated ordering guarantee, and fires
  triggers at agents whose state is still a lie from the last daemon.
- *Have `recover` return the endings and replay them in `Daemon.start()`.* Works, but puts
  a second, parallel description of "what an ending causes" in the startup code — a third
  place to keep in step.

### D5 — An agent about to be picked back up does not fire a stopped trigger

**Decision**: `move` fires ending triggers unless the agent is one recovery will bring back.
Computed from `Agent.mayBePickedUpAfterRestart`, which already exists (`Agent.swift:~330`).

**Rationale**: 011 settled that a chat cut off by the daemon is work nobody abandoned, and
picks it up. An agent about to carry on has not finished; firing "an agent stopped" at it
would be false, and would race the pick-up. An agent that will *not* be picked back up —
already brought back once without reaching the end of a turn — genuinely has stopped, and
that is the case this feature fixes.

This is checkable at `move` time: `mayBePickedUpAfterRestart` reads only the agent's own
post-transition fields.

### D6 — Invariants enforced at the write, mended at the read

**Decision**: `AgentStore.save` refuses a record that breaks `isConsistent` and logs what
was wrong. `AgentStore.load` mends one that is already on disk, and the daemon records a
transcript line saying so.

**Rationale**: refusing on write catches the bug in the build that introduced it, which is
the only cheap time. Refusing on *read* would be the wrong answer, though — a person who
cannot see an agent cannot do anything about it, and `loadAll` already skips records that
will not decode, which is how an agent silently disappears today. Mending and saying so
uses the transcript, which is where this app already explains itself to the person
(`runtimeNote` is used for exactly this in recovery and cost limits).

**Alternatives rejected**:

- *Enforce only in `DaemonCore.move`.* Leaves the direct-mutation paths that are not
  transitions — `report`, `outcomeAsked`, `restartPickUps` — able to write a broken record.
  The store is the last gate everything passes.
- *Throw on load.* Loses the agent, which is the failure mode being fixed.

### D7 — An unrecognised state opens as an ending nothing vouched for

**Decision**: `Agent.init(from:)` decodes `state` leniently. An unknown string becomes
`.stopped` with `endedReason = .unrecognised`, and the original string is kept so it is
written back out rather than deleted.

**Rationale**: `AgentState` is a `String` raw-value enum, so an unknown value throws from
`decode`, which fails the whole `Agent`, which makes `loadAll` (`AgentStore.swift:40`) put
the record in `unreadable` and carry on without it. The agent vanishes from the app. Every
other newer-build field is already protected by `unknownFields` — `state` is not, because
it is a known key.

`EndedReason.unrecognised` already exists and already means exactly this: "not in the
protocol's list and not one of ours… it belongs in the record rather than being rounded to
the nearest reason we do recognise." `WorkOutcome.init(wire:)` takes the same position for
the same reason.

**Honest limitation**: this protects builds that *have* the fix from states added *after*
it. It does nothing for a build that predates it meeting a `starting` record — that build
will still drop the agent. The exposure is small: `starting` lasts seconds, and reverting
to an older build while an agent is mid-start is a narrow window. It is recorded here
rather than hidden, and it is the argument for doing the lenient decode now rather than the
next time a state is added.

**Alternatives rejected**:

- *Add an `unrecognised` case to `AgentState`.* Opens the closed set the transition table
  depends on, and every switch would have to answer for a state no transition can produce.
- *Mend to `stopped`/`daemonGone`.* Claims something specific that did not happen.

### D8 — A failed start is an ending, not a state

**Decision**: `starting` → `stopped` with the reason the start failed. No `failed` state.

**Rationale**: `freshSession` (`DaemonCore+Commands.swift:196`) already throws typed errors
that the app turns into messages — runtime not installed, needs signing in, wrong protocol
version, folder gone. Those are told to the person as an error on the start, and the agent
is stopped. A state of its own would need its own group, its own heading and its own
transitions out, for a condition indistinguishable from any other stop as far as what the
person does next.

This mirrors `WorkOutcome`'s stated principle: the set is total over *what does the person
do next*, not over *what happened*.

---

## 3. Ordering and concurrency constraints found

| Constraint | Where | Consequence for this plan |
| --- | --- | --- |
| `recover()` runs before the socket opens and before `startWorkflows()` | `Daemon.swift:31–58` | D4: triggers deferred, not skipped |
| `broadcast` no-ops until the broadcaster is set | `DaemonCore.swift:206` | Recovery's `changed()` calls are saves-only today and stay so |
| `pickUpAfterRestart` runs last, after the socket | `Daemon.swift:58` | Whether an agent will be picked back up is known at `recover` time, so D5 can decide inside `move` |
| `DaemonCore` is an actor; `move` awaits | `DaemonCore.swift:7` | A transition that is refused must not have written anything before its first `await` — today `stop` writes `endedReason` before awaiting (FR-010) |
| `sendNextQueued` guards on `hasTurnInFlight` and `sending` | `DaemonCore+Commands.swift:324` | `starting` answering yes to `hasTurnInFlight` is what makes FR-004 free |

---

## 4. What must not move

- `AgentGroup.live` keeps its four headings. `starting` maps to `.running`, which is
  titled "Working". No heading is added, renamed or removed (FR-023).
- `WorkOutcome`, `WorkReport` and `outcomeAsked` are untouched. 014's question about how
  the work went is about the turn after it ended; this feature is about the states.
- `releaseRuntime` keeps its ordering and its grace period (FR-024).
- The five in-memory sets carrying lifecycle facts beside the state — `resuming`,
  `interrupted`, `held`, `sending`, `needsBriefing` — stay exactly where they are. A closed
  funnel is what would make folding them in possible later; doing it here would make this
  change unreviewable.

---

## 5. Open questions

None. Every NEEDS CLARIFICATION from the Technical Context is resolved above.
