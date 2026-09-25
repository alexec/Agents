# Research: Blocked Status

Each item gives the decision, why it was chosen, and what else was considered. Code references
are to `main` as of `b44bb70`.

## R1. Where the block lives: on the report

**Decision**: `WorkReport` gains an optional `block: Block?`, set only when `outcome == .blocked`.
It is not a new `AgentState`, and it is not a separate field on `Agent`.

**Rationale**: The spec says blocked is how a turn ends, not a state (Clarifications, Assumptions).
Reports already have the lifecycle the spec wants. `enqueue` sets `report = nil` when a person's
prompt goes (`DaemonCore+Commands.swift:482`), which is FR-015 at no cost. A later report
replaces the earlier one in `land`. It is persisted with the agent record, which covers FR-020.
The app's own prompts (`from: .app`) don't clear it, which the resume needs (see R5).

**Alternatives**: A new `AgentState.blocked` was rejected. `waitingOnUser` shows why: a state
brings `holdsRuntime` and `hasTurnInFlight` with it and needs table rows to leave it, and the
agent holds no runtime. A top-level `Agent.block` field was also rejected. It would need its
own clearing on every path that clears a report, which gives two copies that can drift apart.

## R2. How an agent names another agent

**Decision**: `waiting_on` is an array of strings. Each is matched first as a UUID against
agents in the caller's project, then as an exact title (case-insensitive, trimmed) among the
project's agents that are not archived. No match is refused, and the refusal lists the
project's non-archived agents as `id: "title"`. More than one title match is refused, and the
refusal lists just those. Because the not-found refusal lists every agent with its id, an
agent that guessed wrong learns every id it could use from that refusal.

**Rationale**: Ids are already given out. `start_agent` returns `(id …)` and `list_my_agents`
lists ids (`DaemonCore+Helpers.swift:70,142`). That covers the P1 case. A helper can name the agent that
started it by title, or learn its id from the not-found refusal. Titles are how agents and people
refer to each other in prose, and the ambiguity refusal from the edge cases makes them safe.

**Alternatives**: Ids only was rejected. It makes a sibling impossible to name unless the
parent passed the id along, and the title fallback costs very little. A new
`list_project_agents` tool for helpers was left out of v1, as the spec's Assumptions allow.
Telling a helper its starter's id in the briefing was also rejected: the briefing is fixed
text, the same for every agent, and a helper waiting on its own starter usually closes a
circle anyway.

## R3. What counts as "already ended" at report time

**Decision**: A named agent is refused as already ended if it is `stopped` or `archived`, or if
it is `finished` and none of these hold: its report is `blocked` with an uncleared block, or
it is about to be asked for its outcome (`willAskForOutcome`), or it has queued prompts. An
agent that is `starting`, `running` (including answering the app's question) or
`waitingOnUser` is waitable.

**Rationale**: The refusal is there so a block can't wait on something that will never happen
(SC-004). A finished agent carrying its own open block hasn't finished in the sense the spec
means (edge case "itself blocked"). A finished agent with prompts queued is about to run.

**Alternatives**: Refusing any `finished` agent was rejected. It would forbid waiting on a
blocked agent, which the edge cases allow explicitly.

## R4. Circles

**Decision**: Build the graph from every agent in the project whose report has an uncleared
block. Its edges are the open waits. Leave out the caller's own current block, because the new
report replaces it. Add the proposed edges. Then search from each named agent. If the caller
is reachable, refuse, naming the agents on the path in order.

**Rationale**: At most a few dozen agents, all in memory, and all inside one actor call with no
`await`. The graph can't change during the check.

## R5. When a wait closes, and when a block clears

**Decision**: `closeWaits(on: agentID)` is called from `move(_:on:)` after the state is
written, next to the workflow trigger code. The conditions are the same ones that make the
agent-finished workflow fire (`DaemonCore.swift:495–528`):

- `next == .finished`, not held for the outcome question, and the agent's report is not an
  uncleared `blocked`. The wait closes with `.finished(outcome?, message?)`. If there is no
  report, that reads as "ended without saying how it went".
- `next == .stopped`, except `foundDead` on an agent about to be picked up. Closes with `.stopped(reason)`.
- `next == .archived`. Closes with `.archived`.

On the waited-on agent's side, a later `land` of a non-blocked report on an already-`finished`
agent doesn't reach `move`. That happens when the app's silent-ending question is answered.
In that case the outcome question's own turn ends through `move` and closes the wait there.

After closing, `resumeIfCleared(blockedID)` runs for each agent whose wait just closed. It is
also called when the blocked agent itself moves to `finished`, because its report landed
mid-turn and its waits may have closed before its turn ended.

`resumeIfCleared` does nothing unless the agent is `finished`, its report is `blocked`, the
block is uncleared, every wait has closed (or the time to check again has passed) and nothing
is queued. It then does one mutation with no `await` before it: it sets
`block.clearedAt`/`clearedBy`, inserts a `QueuedPrompt(from: .app)` with the resume text, and
calls `changed(agent)`. After that it calls `drainQueue(after:)`.

**Rationale**: On an actor, a check followed by a write with no `await` between them is the
lock. Two agents finishing "at the same moment" arrive as two `move` calls in sequence, and the
second finds `clearedAt` already set. Putting the queued prompt and the cleared mark in the
same record write means a crash either loses both or keeps both. If it keeps both, the queued
prompt is picked up after the restart like any queued prompt, and it is not queued again. That
is SC-002 across restarts.

**Alternatives**: A separate "pending resumes" table was rejected: it is a second copy of the
same facts. Resuming from the app side was rejected: the daemon is the only thing that is
always running.

## R6. Time to check again

**Decision**: `check_again_in_minutes`, an integer from 1 to 1440, stored as an absolute
`checkAgainAt`. `tickWorkflows(now:)` (15 s interval) calls `resumeDueBlocks(now:)`, which runs
`resumeIfCleared` for every uncleared block whose `checkAgainAt <= now`. If the waits are also
all closed by then, the prompt says so. Otherwise it says the time came, repeats the message,
and lists the waits still open.

**Rationale**: The ticker already exists, already takes an injected `now` for tests, and 15 s
is well inside "within a minute" (US4 AS2). A Mac that was asleep, or a daemon that was down,
catches up on the first tick and resumes once, because the block is cleared at that point
(US4 AS3).

**Alternatives**: A per-block `Task.sleep` was rejected. It doesn't survive a restart and
needs cancelling on every clear. Minutes rather than an absolute time were chosen because
agents are bad at clocks and time zones.

## R7. A resume that can't start

**Decision**: `resumeIfCleared` calls `sendNextQueued` directly, in a `do/catch`, instead of
calling `drainQueue`. If it throws, or if afterwards the resume prompt is still at the front of
the queue with no turn in flight (a cost-limit hold), it removes the resume prompt and
replaces the report with `WorkReport(.stuck, "Could not carry on after the block cleared: <reason>")`,
then calls `reconsider()`.

**Rationale**: FR-018. `stuck` already means "yours to fix", already raises a need, and
already notifies. Taking the resume prompt out of the queue means the person's next prompt
isn't preceded by a stale one.

## R8. Older builds and unknown words

**Decision**: `WorkReport.init(from:)` becomes hand-written. An outcome it doesn't recognise
decodes the whole report as `nil`, through `Agent.init(from:)` using `try?` for that one key.
Counts decoding in `ProjectSummary` drops keys that aren't an `AgentGroup` instead of throwing.

**Rationale**: The spec's edge case says an unknown outcome is a report that never arrived.
Today that is only true of the wire word in `WorkOutcome(wire:)`. The synthesized decoder
throws on an unknown value and takes the whole agent record with it. Builds from before this
one keep that problem, so the phone should be updated alongside the Mac (plan Risks).

## R9. Stopping a blocked agent

**Decision**: Add `AgentEvent.stoppedWaiting` (`finished → stopped`, endedReason
`.stoppedByUser`, or `.stoppedByAgent` when the `StopCause` is an agent). `stop(_:by:)` on a
`finished` agent whose report has an uncleared block marks the block `clearedBy: .dropped` and
moves it on this event. If the agent still has a turn in flight (it reported blocked but hasn't
yet given the turn back), the block is marked dropped before the ordinary stop runs. `archive`
marks the block dropped in the same write as its move.

**Rationale**: FR-017, and the spec's rule that stopped outranks blocked. Today the table
rejects `stoppedByUser` from `finished` (`DaemonCore+Commands.swift:1163`), so without a new
event, Stop on a blocked agent would do nothing that anyone could see. The Mac and the phone
show Stop for a blocked agent, as they do for a working one.

**Alternatives**: Allowing `stoppedByUser` from every `finished` agent was rejected. It changes
what Stop means for every Complete agent.

## R10. What the resume prompt says

**Decision**: Wording lives in `Block.swift`, so Mac, phone and tests share one copy.

```text
The block you reported has cleared: every agent you were waiting on has finished.

- "Fix login redirect" (id …): done — Redirect fixed and tested.
- "Update docs" (id …): stuck — Can't find the docs folder.

You said you were waiting on: <message>. Carry on from here.
```

For a time: `The time you asked to check again has come (25 minutes). You said you were
waiting on: <message>. Still open: …` For Carry on (sent as the person): `I've cleared the
block you were waiting on. Carry on.`

**Rationale**: FR-013/014/016. A prompt from the app in `.app` origin is already drawn as the
app's in the transcript (FR-019), so nothing new is needed there.

## R11. Grouping and display

**Decision**: `AgentGroup.blocked`, title "Blocked", and `live = [.needsAttention, .blocked,
.running, .finished, .stopped]`. In `AgentGroup.init`: `.finished` with `wantsEyes || wantsAnswer`
→ needsAttention. Otherwise, a report of `.blocked` with an uncleared block → `.blocked`.
Otherwise → finished. The same applies to the `.running where outcomeAsked` arm. `blocked` is
not `needsAPerson`, so `needs()` and every Needs attention count leave it out without any
change. `StatusShape` gets a `.blocked` case, drawn as an hourglass on Mac and iOS.

**Rationale**: FR-007–FR-012. Each view already iterates over `AgentGroup.live`, so adding it
to the list is what adds the section on both platforms.
