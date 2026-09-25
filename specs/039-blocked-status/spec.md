# Feature Specification: An Agent Can Say It Is Blocked, and Carries On When the Block Clears

**Feature Branch**: `039-blocked-status`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Blocked status. Allow an agent to report they're blocked. This might be due to another agent, or some other status. This is similar to "needs attenion" or waiting for questions."

## Why this feature exists

When an agent ends its turn it says how the work went. It picks one of five outcomes: done,
nothing to do, needs an answer, partly done, or stuck. None of the five fits an agent that is
waiting for something other than the person. Examples: an agent that started three helpers and
can't go on until they finish, a helper that needs a sibling's change merged first, or an agent
waiting on a CI run or a review.

Today such an agent reports *stuck* or *needs an answer*. Both put it under Needs attention. The
person opens it, finds there is nothing for them to do, and has to remember to prompt it again
once the other agent is done. Or it reports *done*, which is untrue, and the waiting is lost.
Either way the person becomes the scheduler: they watch one agent finish so that they can poke
another.

This feature adds a sixth outcome, **blocked**. The agent says what it is waiting on. If that is
another agent, or several, the app watches those agents. When they have all finished, it sends
the blocked agent a prompt saying how each one ended, and the agent carries on without the person.
If it is waiting on something the app can't see, the agent says what it is in words. It can also
name a time to check again. Blocked agents get a group of their own, so Needs attention goes back
to meaning *you are the one who can move this*.

## Clarifications

### Session 2026-09-24

- Q: Where does a blocked agent show up? → A: In a Blocked group of its own, between Needs attention and Working. Not under Needs attention.
- Q: When the agent it is blocked on finishes, what happens? → A: The blocked agent is resumed automatically with a prompt saying what cleared. The person does nothing.
- Q: Can an agent be blocked while its turn is still going? → A: No. Blocked is how a turn ends, like stuck or needs an answer. The agent gives the turn back and costs nothing while it waits.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An agent waits for the helpers it started, and carries on when they finish (Priority: P1)

An agent splits a job and starts two helpers. It has nothing to do until they finish, so it ends
its turn *blocked* and names the two helpers. It moves to the Blocked group. Its row says it is
waiting on those two helpers, by name. The person does nothing. When the second helper finishes,
the agent is sent a prompt listing each helper, how it ended, and its message. It picks the work
up again and moves to Working.

**Why this priority**: This is the case that exists today (028 lets agents start agents) and that
the person currently has to babysit. On its own it removes that job.

**Independent Test**: Ask an agent to start two helpers that each do a short task, then wait for
both. Confirm that the agent sits in Blocked naming both, is resumed once both have finished,
and that its resume prompt carries each helper's outcome and message. The person does not touch
anything.

**Acceptance Scenarios**:

1. **Given** an agent with two working helpers, **When** it ends its turn blocked on both, **Then** it appears in the Blocked group, not in Needs attention or Complete, and its row names both helpers.
2. **Given** an agent blocked on two agents, **When** the first of them finishes, **Then** nothing is sent yet, and the row shows one of two cleared.
3. **Given** an agent blocked on two agents, **When** the second of them finishes, **Then** the blocked agent is sent exactly one prompt within 5 seconds, and it moves to Working.
4. **Given** that prompt, **When** the person reads it in the transcript, **Then** it names each agent it waited on, the outcome each one reported, and each one's message, and it is marked as sent by the app, not by the person.
5. **Given** an agent blocked on a helper, **When** the helper ends *needs an answer* or *stuck*, **Then** that counts as finished for the blocked agent. It is resumed and told what the helper said, and the helper also shows under Needs attention as it does today.

---

### User Story 2 - Blocked is not the person's to-do list (Priority: P1)

The person looks at the panel to find what needs them. Blocked agents are in their own group,
drawn between Needs attention and Working. They don't count toward the Needs attention badge on
the project, the Dock or the phone. They don't raise a notification. Each blocked row says what
it is waiting on in the agent's own words, plus the names of any agents it is waiting on.

**Why this priority**: Without this, adding the outcome only moves the noise. The point is that
Needs attention stops holding agents the person can't unblock.

**Independent Test**: With one agent blocked and one agent asking a question, confirm that the
badge counts one, that only the question notifies, and that the blocked agent is under Blocked
with its reason on the row.

**Acceptance Scenarios**:

1. **Given** an agent that ends its turn blocked, **When** the panel draws, **Then** it is under a Blocked heading between Needs attention and Working, and the Blocked heading is not drawn when no agent is blocked.
2. **Given** blocked agents in a project, **When** the person looks at the project's Needs attention count on the Mac or the phone, **Then** blocked agents are not counted.
3. **Given** an agent that ends its turn blocked, **When** the report arrives, **Then** no notification is raised for it.
4. **Given** a blocked agent, **When** the person looks at its row or card, **Then** it shows the agent's message and, for each agent it waits on, that agent's name and whether it has finished.
5. **Given** the same blocked agent, **When** it is seen on the phone or the iPad, **Then** it is in the same group with the same words as on the Mac.

---

### User Story 3 - The person can unblock it by hand (Priority: P2)

The person knows the block is gone before the app does. For example, they merged the branch the
agent was waiting on. Or they want the agent to stop waiting and do something else. They prompt
it as usual. A prompt from the person ends the block: the agent stops waiting on anything, and
nothing is sent later when the agents it was waiting on finish. A blocked agent's card also has
a **Carry on** action. It sends a short prompt saying the person has cleared the block, so they
don't have to write one.

**Why this priority**: Automatic resume covers agents. It can't cover what the app can't see, and
the person always has to be able to say "stop waiting".

**Independent Test**: Block an agent on a working helper. Prompt it before the helper finishes.
Confirm that it runs the person's prompt, leaves Blocked, and is not sent a second prompt when
the helper finishes later.

**Acceptance Scenarios**:

1. **Given** a blocked agent, **When** the person sends it any prompt, **Then** the block is cleared, the agent runs that prompt, and it leaves the Blocked group.
2. **Given** an agent the person unblocked by hand, **When** an agent it had been waiting on finishes later, **Then** nothing is sent to it.
3. **Given** a blocked agent, **When** the person uses Carry on from its card on the Mac, phone or iPad, **Then** the agent is sent a prompt saying the person cleared the block, and it resumes.

---

### User Story 4 - Blocked on something the app can't see, with a time to check again (Priority: P3)

An agent pushes a branch and has to wait for CI, which takes about twenty minutes. It ends its
turn blocked. Its message says it is waiting on CI for that branch, and it names a time to check
again, 25 minutes from now. It sits in Blocked, and the row shows when it will check again. At
that time the app resumes it with a prompt saying the time it asked for has come. The agent
checks CI. If CI is still running, it can end its turn blocked again with a new time.

**Why this priority**: Useful and cheap once blocked exists. The waiting-on-agents case matters
more, and an agent blocked on something outside with no time given still works: the person
unblocks it by hand (Story 3).

**Independent Test**: Have an agent end its turn blocked on "something outside" with a check-back
time two minutes away. Confirm it shows the time, is resumed once at about that time, and that its
resume prompt says why it was resumed.

**Acceptance Scenarios**:

1. **Given** an agent that ends its turn blocked on something outside with no check-back time, **When** time passes, **Then** it stays in Blocked until the person prompts it or uses Carry on.
2. **Given** an agent blocked with a check-back time, **When** that time comes, **Then** it is resumed once, within a minute of the time, with a prompt that repeats what it said it was waiting on.
3. **Given** an agent blocked with a check-back time, **When** the Mac was asleep or the app was not running at that time, **Then** it is resumed as soon as the app is running again. It is resumed once, not once per missed check.
4. **Given** an agent that asks for a check-back time sooner than the shortest allowed or later than the longest, **When** it reports, **Then** the report is refused with the allowed range, so the agent can try again.

---

### Edge Cases

- **The agent it names is already finished, stopped or archived.** The report is refused. The refusal says that agent has already ended and how, so the agent can use what it learns instead of waiting on something that will never happen. Without this rule, a block and a resume could repeat forever.
- **Waiting in a circle.** A is blocked on B, and B tries to end blocked on A (directly or through others). B's report is refused and told which agents make the circle. Nobody ends up waiting on a circle.
- **The agent it waits on is stopped or archived by the person, or removed.** This counts as finished for the blocked agent. The resume prompt says that agent was stopped or archived without finishing.
- **The agent it waits on is itself blocked.** It has not finished. The blocked agent waits until the agent it waits on actually finishes, however many hops that takes.
- **The agent it waits on is in another project.** Refused in this version. An agent can only wait on agents in its own project.
- **An agent the blocked agent can't see.** It can name any agent in its project, but only by an identity the app gave it (see Assumptions). An unknown or ambiguous name is refused, and the refusal lists the agents it could have meant.
- **The blocked agent is stopped or archived.** Its block is dropped. Nothing is sent to it later, and an archived agent is never un-archived by a resume.
- **The resume can't start.** For example, its runtime is signed out or its folder is gone. The agent leaves Blocked and goes to Needs attention, with the reason the resume failed. This is now the person's to fix.
- **The app or the Mac restarts while agents are blocked.** Blocks survive the restart. Agents it was waiting on that finished while the app was down are counted, and any agent whose block cleared in that time is resumed once the app is back.
- **Two finishing agents clear the same block at the same moment.** One prompt is sent, not two.
- **A blocked agent is blocked again by its own resume.** Allowed: it can end the resumed turn blocked on something new. Each block is judged on its own.
- **Blocked is reported by an app this build doesn't know.** No change from how unknown outcomes are treated today: an outcome the build doesn't recognise is a report that never arrived.
- **Leases (036).** An agent waiting in line for a lease is waiting mid-turn, and that is handled by leases. Blocked is for a turn that has ended. The two don't depend on each other.

## Requirements *(mandatory)*

### Functional Requirements

**Reporting**

- **FR-001**: An agent MUST be able to end its turn with the outcome *blocked*, alongside the existing five, using the same tool it already uses to say how a turn went.
- **FR-002**: A *blocked* report MUST carry the agent's message (what it is waiting on, in its own words) and MAY name one or more agents in its own project that it is waiting on. It MAY also give a time to check again.
- **FR-003**: A *blocked* report that names no agents and gives no time to check again MUST still be accepted. That agent waits until the person unblocks it.
- **FR-004**: A *blocked* report MUST be refused, with a reason the agent can act on, if: it names an agent that is unknown, ambiguous, in another project, or already finished, stopped or archived; it names itself; it would close a circle of waiting; or its time to check again is outside the allowed range.
- **FR-005**: *Blocked* MUST only be reportable as the end of a turn. There is no blocked state while a turn is in flight.
- **FR-006**: The tool's description of *blocked* MUST tell the agent what it is for (waiting on something other than the person), how it differs from *needs an answer* and *stuck*, and that it will be resumed when the agents it names have finished.

**Grouping and display**

- **FR-007**: An agent whose turn ended *blocked*, and whose block has not cleared, MUST be in a Blocked group of its own. Each agent MUST still be in exactly one group.
- **FR-008**: The Blocked group MUST be drawn between Needs attention and Working, and only when it has at least one agent in it.
- **FR-009**: Blocked agents MUST NOT count toward any Needs attention count or badge, and a *blocked* report MUST NOT raise a notification.
- **FR-010**: A blocked agent's row and card MUST show its message, and for each agent it waits on, that agent's current name and whether it has finished. They MUST also show the time it will check again, if it gave one.
- **FR-011**: The Mac, the phone and the iPad MUST show the same group and the same words for the same blocked agent.
- **FR-012**: Stopped and archived MUST outrank blocked, as they outrank every other report today. A stopped or archived agent is never shown as blocked.

**Clearing and resuming**

- **FR-013**: When every agent a blocked agent waits on has finished its turn (with any outcome), been stopped, been archived or been removed, the app MUST resume the blocked agent once, with a prompt from the app that lists each of those agents, how it ended, and its message if it left one.
- **FR-014**: When a blocked agent's time to check again comes, the app MUST resume it once, with a prompt from the app that repeats what it said it was waiting on. If it named agents and gave a time, whichever comes first resumes it, and the prompt says which one it was.
- **FR-015**: Any prompt the person sends a blocked agent MUST clear its block. After that, nothing may be sent to it on account of that block.
- **FR-016**: A blocked agent MUST offer a Carry on action on the Mac, phone and iPad. It sends a short prompt saying the person has cleared the block.
- **FR-017**: Stopping or archiving a blocked agent MUST drop its block. A resume MUST NOT start, un-stop or un-archive it.
- **FR-018**: If a resume can't start, the agent MUST move to Needs attention with the reason, instead of staying Blocked.
- **FR-019**: Prompts sent by the app to resume an agent MUST be marked in the transcript as coming from the app, not the person, in the same way as the app's existing question after a silent ending.
- **FR-020**: Blocks MUST survive a restart of the app or the Mac. Anything that cleared while the app wasn't running MUST be acted on once when it comes back, and only once.

### Key Entities

- **Blocked report**: The sixth outcome of a turn. It holds the agent's message, the agents it waits on (possibly none), an optional time to check again, and when it was made. Like every report, a later one replaces it, and the person's next prompt clears it.
- **Wait**: One blocked agent's dependency on one other agent in the same project. It is open until that agent finishes, stops, is archived or is removed, and it then records how that agent ended. A block clears when all its waits have closed.
- **Resume prompt**: A prompt the app sends on the agent's behalf when a block clears. It says why the block cleared (the agents it waited on and how each ended, or that the time came), and the transcript marks it as the app's.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An agent that waits on helpers it started is resumed within 5 seconds of the last one finishing, with no action from the person, in 100% of runs.
- **SC-002**: Every block that clears produces exactly one resume. There are no double resumes when agents finish at the same moment or across a restart, and no resumes after the person has prompted the agent or stopped or archived it.
- **SC-003**: Zero blocked agents appear under Needs attention, in its counts, or in notifications, unless their resume has failed.
- **SC-004**: Every attempt to wait in a circle, or to wait on an agent that has already ended, is refused at report time. No agent is ever left waiting on something that can't finish.
- **SC-005**: A person reading a blocked agent's row can tell what it is waiting on without opening its conversation.
- **SC-006**: A block made before a restart of the app is kept afterwards, and cleared by what happened while the app was down, in 100% of runs.

## Assumptions

- **An agent needs a way to name another agent.** A known gap from 028 is that agents lack their own id. This feature assumes an agent can learn a stable identity for itself and for the other agents in its project. It gets identities for the agents it started from 028's list, and needs a similar way for the agent that started it and its siblings. If that isn't built first, v1 is limited to agents it started (the P1 case) and the agent that started it.
- **"Finished" means the turn ended.** Any outcome counts, including *needs an answer* and *stuck*: the blocked agent is told what the other agent said and decides what to do. Waiting for a *particular* outcome is out of scope.
- **The allowed range for a time to check again is 1 minute to 24 hours.** Short enough to stop an agent resuming every few seconds, and long enough for an overnight CI run.
- **Resumes cost money like any turn**, and happen without the person. They are bounded because each block produces at most one resume, and a block on an agent that has already ended is refused.
- **Blocked is not a new agent state.** Like every other report, it describes a turn that is over. The agent holds no turn and queues nothing while blocked.
- **Mid-turn waiting is out of scope.** This includes an agent that polls in place and waiting in line for a lease (036).
- **Blocking on agents in another project, on another host (037), or on people outside the app is out of scope** beyond the message the agent writes.
