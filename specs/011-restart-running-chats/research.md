# Research: A Restarted Background Service Picks Up the Chats That Were Working

No `NEEDS CLARIFICATION` markers were carried into Technical Context: the language, dependencies,
storage, testing and platform are all settled by the existing codebase, and this feature adds
nothing outside it. What follows is the set of decisions the design turns on, each one taken
against a real alternative.

---

## 1. How a chat that is coming back is represented

**Decision**: Not a state. `resuming` stays a transient `Set<UUID>` on `DaemonCore`, is broadcast
as `agent/resuming`, is seeded on connect by `agents/resuming`, and is held client-side on
`AgentsModel` beside `filesToShow`. The row text and icon are derived from it.

**Rationale**: The codebase has already made this call once and written down why.
`AgentGroup.init(for:wantsEyes:)` carries the comment: *"`wantsEyes` is not a state and must never
become one. `waitingOnUser` carries `holdsRuntime` and `hasTurnInFlight` with it, so an agent put
there for showing a file would start queueing prompts, and the transition table has no way back out
of it."* A `.resuming` case has exactly the same problem from the other side: it holds no runtime
and has no turn in flight, so every `holdsRuntime` call site would have to decide about it afresh,
and there is no event in `AgentEvent` that honestly moves a chat out of it if the daemon dies again
mid-pick-up. Worse, `AgentState` is persisted by raw value, so a chat left in `.resuming` on disk by
a daemon that was killed would come back claiming to be returning when nothing is returning it.

**Alternatives considered**:

- *A new `AgentState.resuming` case.* Rejected: touches the transition table, `holdsRuntime`,
  `hasTurnInFlight`, `AgentGroup`'s totality test, both UIs' exhaustive switches, and the persisted
  enum — and can be left behind on disk as a lie.
- *Derive it in the app from `state == .stopped && endedReason == .daemonGone`.* Rejected: it cannot
  distinguish a chat the daemon is about to pick up from one it has already decided not to (at its
  pick-up limit, or refused), which is precisely the distinction FR-013 and FR-016 need the person
  to see.
- *No indicator at all.* Rejected by FR-018: without it the chat reads "Stopped · Stopped with the
  daemon" and then silently becomes "Working", which is the flicker the spec's Story 2 objects to.

---

## 2. What stops a chat that keeps taking the daemon down

**Decision**: One persisted `Int` on `Agent` — `restartPickUps`. Incremented and saved *before* the
restart words are sent. Cleared to zero whenever a turn ends for any reason other than
`daemonGone`. A chat is eligible for pick-up only while it is zero.

**Rationale**: The failure this bounds is unbounded spend, so the count has to survive the very
crash it is counting — which means the record, not memory. Saving before sending rather than after
is the only ordering that is safe: a daemon killed in the middle of starting a runtime has already
written down that it tried, so the next daemon does not try again. Clearing on any turn that
reaches its own end — rather than only on `endTurn` — is deliberate: a chat picked back up that
then hits its token limit, or is stopped by the person, still demonstrated that it can get to the
end of a turn without killing the daemon, which is the whole question being asked. `daemonGone` is
the only ending that is *not* evidence of that, and it is the only ending `recover()` ever writes.

**Threshold**: one. FR-016 says "not picked back up a second time in a row", so a chat is picked up
once per successful turn. A configurable threshold was considered and rejected as a setting nobody
would ever have a reason to change.

**Alternatives considered**:

- *A timestamp — refuse if the last pick-up was under N minutes ago.* Rejected: it makes the rule
  depend on how long the crash takes, so a chat that kills the daemon slowly loops anyway, and a
  machine off overnight forgets a chat that is genuinely fatal.
- *An in-memory count.* Rejected outright: the daemon dying is the event being counted.
- *A global cap on pick-ups per daemon start.* Rejected: it punishes the innocent chats in a batch
  for one bad one, and FR-015 says one failure must not stop the rest.

---

## 3. Where the restart words go when the chat already has a queue

**Decision**: The front of the queue. `pickUp` stops guarding on `queuedPrompts.isEmpty`, and the
restart words are enqueued ahead of anything already waiting.

**Rationale**: This is a real bug in the code as it stands, not only a gap. The guard reads:

```swift
guard let agent = agents[id], agent.state == .stopped,
      agent.endedReason == .daemonGone, agent.queuedPrompts.isEmpty else { return }
```

and its comment explains the intent as "already spoken to by somebody who got here first". But
`prompt` appends every prompt to `queuedPrompts` *including ones that go straight out*, so words
the person typed and queued behind a working agent before the crash sit in that array too. Such a
chat is therefore never picked back up at all, and nothing says so — it simply stays stopped. The
first three conditions already express "nobody has got here first" completely: `interrupted`'s
`removeValue` is the once-only claim, and any turn started since would have moved the state off
`.stopped` or the reason off `daemonGone`.

Front rather than back, because order is meaning here. The queued words were typed by somebody who
believed the turn was still running; the restart words are the news that it was not. Delivered
behind them, the agent acts on instructions premised on a state that never existed and only
afterwards learns it was cut off — which is the exact failure FR-004 exists to prevent.

**Alternatives considered**:

- *Keep the guard and leave queued chats alone.* Rejected: silently abandons work, and abandons it
  for precisely the people who were engaged enough to type while it ran.
- *Merge the restart words into the first queued prompt.* Rejected: it puts the app's voice and the
  person's inside one message, breaking FR-006.
- *Drop the pre-crash queue and send only the restart words.* Rejected: throws away something the
  person typed, which no part of this feature is entitled to do.

---

## 4. Stopping a chat that has not come back yet

**Decision**: `stop()` removes the id from both `resuming` and `interrupted` before doing anything
else, and says so in the chat if a pick-up was withdrawn.

**Rationale**: Today `stop()` on such a chat is a no-op that looks like it worked: there is no live
session, no turn task, and `state.holdsRuntime` is false because the chat is `.stopped`, so nothing
runs and the resume loop starts it seconds later. Removing it from `interrupted` is sufficient on
its own — `pickUp` begins with `guard let was = interrupted.removeValue(forKey: id)` and returns
when it finds nothing — but `resuming` must go too or `isHoldingAgents` keeps a daemon alive for a
chat nobody is bringing back. Doing it synchronously at the top of `stop()`, before any `await`,
is what makes it a genuine race-free withdrawal on an actor.

**Alternatives considered**:

- *A separate "cancel pick-up" call.* Rejected: the person pressed Stop and means it; a second
  concept for the same intent is a worse app.
- *Let the pick-up happen and stop it once it is running.* Rejected: it spends a turn, and starting
  a runtime the person has just asked you to stop is indefensible.

---

## 5. The order chats come back in

**Decision**: Sorted by `lastActivityAt`, most recent first.

**Rationale**: `recover()` currently iterates `for (id, agent) in agents` — a Swift `Dictionary`,
whose order is unspecified and varies between runs — while `pickUpEachInTurn`'s comment claims they
go "in the order they were found". Any order is correct as far as the spec goes, but only one is
worth choosing: the person is most likely watching whichever chat they left running last, and with
one-at-a-time pick-up the last chat in a batch waits for every runtime ahead of it to start.

**Alternatives considered**:

- *Oldest first.* Rejected: the oldest interrupted chat is the one least likely to still matter.
- *Leave it unordered.* Rejected: the comment already promises an order, and a test that asserts on
  a dictionary's iteration order is a flake waiting to happen.

---

## 6. Spending limits

**Decision**: No work in this feature. FR-019 is satisfied by the existing design choice that
picking a chat back up is an ordinary `prompt`.

**Rationale**: `010-cost-limits` is specified (`specs/010-cost-limits/spec.md`) and not yet built —
nothing in the source mentions a limit. Its FR-009 puts the gate on starting agents and taking
prompts, which is exactly the path `pickUp` goes down. When that gate lands, a pick-up that would
breach a limit throws from `prompt`, and `pickUp`'s existing `catch` already writes the reason into
the chat and removes the words from the queue. Building a second, speculative gate here would mean
two places that can refuse a pick-up, and the wrong one of them would be the one nobody updates.

**What this feature owes 010**: a test, added when 010 lands, asserting that a pick-up refused for
cost reads as a refusal in the chat rather than as a crash. Recorded here so it is not lost.

**Alternatives considered**:

- *Check `costToDate` directly in `pickUp`.* Rejected: there is no limit on the record to compare it
  to, so the check would have nothing to say until 010 exists anyway.
- *Block this feature on 010.* Rejected: everything else here is independent of it, and the crash
  loop that FR-016 closes is itself a cost control.

---

## 7. Where the "Coming back" wording lives

**Decision**: In the same per-platform switches that already render state — `AgentRow.description`,
`AgentCard.description`, and the transcript headers — reading the one `resuming` fact from
`AgentsModel`.

**Rationale**: `EndedReason.summary` carries a comment stating the rule: *"Here rather than in a
view because the phone and the window have to say the same words about the same agent, and two
copies of a switch are two chances to drift."* That argues for putting shared wording in Core. But
`resuming` is not an ending and has no `EndedReason` to hang off, and the existing state wording
("Working", "Complete", "Stopped") is already duplicated across `AgentRow` and `AgentCard` rather
than centralised. Following the established shape and matching the strings is the smaller change;
a test asserts the two agree, which is the protection the comment is actually asking for.

**Alternatives considered**:

- *A shared `Agent.statusLine(resuming:)` in Core.* A better end state, but it would mean rewriting
  the wording of every existing state across both platforms inside a feature about restarting
  chats. Noted as worth doing separately.
