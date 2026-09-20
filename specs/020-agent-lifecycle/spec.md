# Feature Specification: An Agent Being Born Is Not a Finished One

**Feature Branch**: `020-agent-lifecycle`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "A key feature that has emerged in this app is the management of the agent lifecycle. When something emerged, the code becomes scar tissue. The agent must have a clear lifecycle."

## Why this feature exists

The lifecycle is the spine of this app. Every list, every badge, every workflow trigger and every
decision about whether a process may be let go reads one question: what is this agent doing. That
question has an answer, and the answer has a table — five states, nine events, one transition
function that returns nothing for a move that must not happen. On paper it is the cleanest thing
here.

It was not designed. It accreted, one feature at a time, and three kinds of scar tissue show.

**An agent is born claiming an ending it never had.** There is no state for *starting*, so a new
agent is written down as `stopped`, with `endTurn` as its reason — the ending that means the agent
said what it had to say. It has not said anything. The lie is there because the invariant says a
stopped agent must have a reason, and this was the cheapest reason to hand. It is broadcast to the
windows before the first turn begins, so a new agent appears for an instant under **Stopped**,
beside the ones the person gave up on, and then jumps to **Working**. Nobody chose that. It is what
happens when the shape of the record has no room for the thing that is actually true.

**The one funnel has a hole in it, and the hole is load-bearing.** Everything hangs off the claim
that state changes in one place: the transcript entry, the order the record is written in before
the windows hear, the project counts, and the whole of the workflow trigger surface — its own
comment says "the one funnel every state change already passes through". But the daemon coming back
from a restart does not pass through it. It writes the state and the reason directly, because going
through would clear the pick-up count and fire every agent-stopped workflow at once. Both of those
are good reasons; neither is a rule the funnel knows. They are a bypass. So a workflow set to run
when an agent stops does not run when six agents stop because the Mac restarted — which is exactly
the moment somebody would want it to. The guarantee is a convention held up by two comments, and
019 has already shown what happens to a rule written twice in two comments.

**The invariants are asserted in the tests and enforced nowhere.** There is a list of the things
that must be true of a record — archived has a reason, stopped has a reason, finished can only mean
`endTurn` — and it is a property nothing in the running app ever asks. A record that breaks it can
be written, saved, read back and carried forever, and the first anyone knows is a group that looks
wrong.

None of this is the lifecycle being wrong. The states are right, the table is right, the refusals in
it are right. This is making the table the only way through, giving it the one state it was always
missing, and making its rules true of the record rather than true of the tests.

**This feature does not change what an agent does.** No new group, no new thing an agent can tell
you, no change to how a turn runs or when a runtime is let go. It changes what is true of the
record, and what it is possible for code to write into it.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A new agent is never a finished one (Priority: P1)

Someone starts an agent. From the moment it exists, it is shown as starting — and then working.
It is never, not even for the instant before its first turn begins, listed under Stopped or
Complete or given an ending it did not have. If the runtime will not start, it becomes stopped for
the reason it actually failed, and the person is told that reason.

**Why this priority**: It is the plainest thing wrong and the only one a person sees with their own
eyes. It is also what forces the state to exist, which everything else in this spec is written
against.

**Independent Test**: Start an agent against a runtime that takes a few seconds to come up, watch
the agent list the whole time, and confirm it never appears under any group but the working one.
Then read the record it wrote at that moment and confirm it carries no ending.

**Acceptance Scenarios**:

1. **Given** a person starts a new agent, **When** the agent first appears in the list, **Then** it is shown as starting and is grouped with the working agents.
2. **Given** a new agent that has not begun its first turn, **When** its record is read, **Then** it carries no ending and no reason for one.
3. **Given** a new agent, **When** its first turn begins, **Then** it becomes working, and nothing about it flickers through another group on the way.
4. **Given** a runtime that will not start, **When** someone tries to start an agent with it, **Then** no agent is made at all and the failure reaches the person as an error on the start, unchanged from how it reaches them today. *(Amended after implementation: the session is made before the record exists, so there is no agent to put into a stopped state. An agent whose runtime dies **after** the record is written is covered by scenario 6 and by `processDied`.)*
5. **Given** an agent that is starting, **When** a second prompt arrives for it, **Then** the prompt joins the queue rather than beginning a turn of its own.
6. **Given** an agent that was starting when the daemon went, **When** the daemon comes back, **Then** it is treated as an agent that was cut off, the same as one that was working.

---

### User Story 2 - Every ending reaches the things that watch for endings (Priority: P2)

Someone has a workflow that runs when an agent stops. Their Mac restarts overnight with four agents
working. Today, those four stop and the workflow does not run — not because anyone decided it
should not, but because the code that stopped them is not the code the trigger hangs off. After this
feature, an ending is an ending however it was caused, and the same things happen every time: the
line in the transcript, the counts on the project, the triggers that were waiting.

**Why this priority**: It is a real behaviour the person set up and does not get, and it is the
reason the funnel has to be closed rather than merely tidied. It depends on nothing in Story 1.

**Independent Test**: Set a workflow to fire when an agent stops. Leave two agents working, kill the
daemon outright, and start it again. Confirm the workflow fires for the agent that will not be
picked back up, and does not fire for the one that will — and that both endings are in their
transcripts.

**Acceptance Scenarios**:

1. **Given** an agent that was working when the daemon stopped, **When** the daemon comes back and stops it, **Then** that ending is recorded and broadcast in the same way as any other ending.
2. **Given** such an agent that will not be picked back up, **When** it is stopped, **Then** the triggers that watch for an agent stopping fire for it.
3. **Given** such an agent that will be picked back up, **When** it is stopped, **Then** those triggers do not fire, because its work is not over — it is about to carry on.
4. **Given** an agent stopped because the daemon went, **When** its ending is recorded, **Then** the count of how many times it has been picked back up is not cleared by it.
5. **Given** any ending at all — finished, stopped by hand, out of tokens, crashed, found dead — **When** it happens, **Then** the project's counts are updated for it.

---

### User Story 3 - A record that cannot be true is never written (Priority: P3)

Nobody sees this one directly. What they see is the absence of the morning where an agent is in a
group that makes no sense and nothing in the app can explain how it got there. The rules about what
a record may say are checked where records are written, and a write that would break one is refused
and logged rather than saved.

**Why this priority**: It is the guard that keeps the first two from rotting. It delivers nothing on
its own, which is why it is last and why it is still here.

**Independent Test**: Attempt, from a test, to save every record the rules forbid, and confirm each
is refused and each refusal is logged. Then put such a record on disk by hand, start the daemon,
and confirm the agent opens in a state the rules allow with a line in its transcript saying it was
mended.

**Acceptance Scenarios**:

1. **Given** a record that breaks one of the rules, **When** something tries to save it, **Then** the save is refused and the refusal is logged with what was wrong.
2. **Given** a record on disk that breaks one of the rules, **When** the daemon reads it, **Then** the agent opens in a state the rules allow, and its transcript says what was mended and why.
3. **Given** a record on disk whose state this build has never heard of, **When** the daemon reads it, **Then** the agent opens rather than being lost, and is treated as an ending nothing vouched for.
4. **Given** a transition the table refuses, **When** it is attempted, **Then** nothing about the agent changes — not its state, not its ending, not its reason, not the time it was last active.

---

### Edge Cases

- **A turn ends while the person is stopping the agent.** Two endings race for the same agent. The
  table already refuses the second, but the reason must not be written by the loser: an agent that
  finished must not end up carrying "stopped by you".
- **A start that never finishes.** A runtime that comes up and then never answers leaves an agent
  starting forever. It holds a process, so the daemon will not exit, and nothing else will move it.
- **A prompt arrives for an agent that is starting.** It queues. It must not begin a second turn,
  and it must not be lost when the first turn begins.
- **Stopping an agent that is starting.** The person may stop it before its first turn begins. It
  becomes stopped by their hand, and the runtime that was being made is let go rather than left
  running unowned.
- **A state a newer build wrote.** A record from a build with a sixth state must still open. An
  unreadable agent is worse than an agent in the wrong group.
- **An ending discovered on restart for an agent that was starting.** It was cut off before it said
  anything at all. It is an ending nothing vouched for, not a completion.
- **Archiving something that is starting.** Refused until it is stopped, in the same way and for the
  same reason as archiving something that is working.

## Requirements *(mandatory)*

### Functional Requirements

**The state that was missing**

- **FR-001**: An agent MUST have a state meaning *starting*: it exists, its conversation has not begun, and nothing has ended.
- **FR-002**: A newly made agent MUST be in that state, and MUST carry no ending and no reason for one.
- **FR-003**: A starting agent MUST be understood to hold a live runtime, so the daemon does not exit out from under it and does not consider the work finished.
- **FR-004**: A starting agent MUST be understood to have a turn in flight, so a prompt arriving for it joins the queue rather than beginning a second turn.
- **FR-005**: The only ways out of starting MUST be: its first turn begins, and it becomes working; the person stops it, and it becomes stopped by their hand; its process dies, and it becomes stopped for that reason; a later daemon finds it on disk, and it is stopped as an agent found dead. *(Amended after implementation: an earlier draft included "the start fails", which cannot happen — the record does not exist until the session has been made.)*
- **FR-006**: A starting agent MUST be grouped with the working ones, so the grouping stays total and a new agent never appears among the settled.
- **FR-007**: A starting agent found on disk when the daemon starts MUST be treated exactly as a working one: its process died with the last daemon, and it is stopped for that reason.

**One way through**

- **FR-008**: Every change to an agent's state MUST go through a single transition, including the endings a restarting daemon discovers. No path may write a state directly.
- **FR-009**: The transition MUST be total over every pairing of state and event, and MUST refuse any pairing the rules do not allow.
- **FR-010**: A refused transition MUST leave the agent entirely unchanged — its state, its ending, its reason, and when it was last active.
- **FR-011**: The reason an agent ended MUST be carried by the event that ended it, not supplied alongside it. It MUST NOT be possible to record an ending whose reason contradicts the event that caused it.
- **FR-012**: The same MUST hold for why an agent was archived: it comes from the event, and nothing sets it beside the transition.
- **FR-013**: Every accepted transition MUST produce the same consequences, whatever caused it: the record is written before the windows are told, the change is entered in the transcript, and the project's counts are updated.
- **FR-014**: The events that fire when an agent starts, ends, asks a question or asks for a form MUST fire from the transition and nowhere else, so an ending fires the same things however it came about.

**The two rules the bypass existed for**

- **FR-015**: An ending whose reason is that the daemon went MUST NOT clear the count of how many times the agent has been picked back up.
- **FR-016**: An ending discovered on restart MUST fire the triggers that watch for an agent stopping only for agents that will not be picked back up. An agent about to carry on has not finished stopping.
- **FR-017**: Both of the above MUST be rules the transition itself knows, expressed once, rather than reasons for a caller to go round it.

**Rules that are true of the record, not of the tests**

- **FR-018**: The rules about what a record may say MUST be checked wherever an agent is written, not only asserted in tests.
- **FR-019**: A write that would break one of those rules MUST be refused, and the refusal logged with what was wrong and which agent.
- **FR-020**: An agent read from disk in a state the rules forbid MUST be brought to a state they allow, and its transcript MUST say what was mended and why. It MUST NOT be opened as it stands.
- **FR-021**: An agent whose state this build does not recognise MUST still open. It is treated as an ending nothing vouched for — never as a completion — and the unrecognised value MUST survive being written back out, in the same way as any other field a newer build wrote.
- **FR-022**: The states, the events, and every legal move between them MUST be one description, in one place, with no way to express a transition outside it.

**What must not change**

- **FR-023**: No group a person reads MUST gain, lose, or rename a heading.
- **FR-024**: What an agent can tell the app about its work, and when a runtime is let go, MUST be unchanged.
- **FR-025**: Records written by every earlier version MUST open unchanged, and an agent saved by this version MUST still open in an earlier one.

### Key Entities

- **Agent state**: What an agent is doing, exactly one at a time. Gains *starting* and keeps the five it has. Never stored anywhere but on the agent, and never written except by a transition.
- **Lifecycle event**: A thing that happens to an agent — a prompt sent, a turn begun, a question asked or answered, a turn ended, a stop, a death, a restart discovery, an archive. Carries with it everything the resulting record needs, including why.
- **Ending reason**: How an agent's last turn or last process came to an end. Gains whatever a failed start needs to say for itself, and is no longer settable apart from the event that caused it.
- **Transition**: One state and one event in, one state out or a refusal. The only way an agent's state changes, and the one place every consequence of a change hangs off.
- **Record rules**: The things that must be true of a written agent. Checked where agents are written and where they are read, not only in tests.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Starting an agent one hundred times shows it in the working group every time and in any other group zero times, from the moment it first appears.
- **SC-002**: No agent record, at any moment in its life, carries an ending that did not happen. Verified by reading every record written during a run that starts, stops, archives and restarts agents.
- **SC-003**: All **60** pairings of state and event — 6 states × 10 events — have exactly one answer, proven by a test that exhausts them against a table transcribed from the contract, with no pairing left undecided and none missing from the table.
- **SC-004**: 100% of state changes, whatever caused them, appear in the agent's transcript and update its project's counts.
- **SC-005**: A workflow that runs when an agent stops fires for every agent whose stopping is final, including the ones a daemon restart stopped — and for none that is about to be picked back up.
- **SC-006**: Every attempt to save a record that breaks the rules is refused, with zero such records reaching disk across the whole test suite.
- **SC-007**: A record deliberately corrupted on disk opens, is mended, and says so, for every rule there is.
- **SC-008**: Opening records written by a newer build loses no agent, in 100% of cases.
- **SC-009**: An agent's state is written by **one transition writer** — the apply inside the funnel — down from two, and stays one. Checkable by anybody reading the code, and held by a source scan. *(Amended after implementation: there is one further writer, and it is deliberate. Repairing a record that the invariants forbid, on read, cannot go through the transition table — the table is total over events that happen to an agent, and "this record was already wrong when we read it" is not one of them. It runs on a freshly decoded record before it is an agent anything holds, and it is named in the scan's allow-list with its reason rather than hidden behind a looser check.)*

## Assumptions

- The five states that exist today are right and keep their meanings and their headings. This adds the one that was missing and changes nothing a person reads.
- *Starting* is a state, not a flag: an agent in it holds a runtime and has a turn in flight, which is what stops the daemon exiting under it and what makes a prompt queue rather than race.
- A failed start is an ending like any other, so it ends in stopped with a reason, rather than in a state of its own.
- Recovery on restart keeps both of the behaviours it has today — the pick-up count is not cleared, and agents about to be picked back up do not fire stopped triggers. This feature changes where those rules live, not what they do. The visible change is the agents that will *not* be picked back up, which now fire as they always should have.
- Mending a forbidden record is better than refusing to open it: a person who cannot see an agent cannot do anything about it, and the transcript is where the app already explains itself.
- A state from a newer build is read as an ending nothing vouched for, matching how the app already treats a turn that ended and never said how it went.
- No migration is needed. Every existing record is in a state this feature still has, and the new state is one nothing written before this feature can be in.
- The duplicated wording of states across the window and the phone is not in scope here; it belongs with 018.
- The in-memory sets that carry lifecycle facts the state cannot — who is being picked back up, who has been told about a limit, who is mid-send, who still needs a briefing — are not in scope here. They are named because a closed funnel is what would let them be folded in later.
