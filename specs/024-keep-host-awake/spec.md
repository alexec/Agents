# Feature Specification: The Mac Stays Awake While Its Agents Work

**Feature Branch**: `024-keep-host-awake`

**Created**: 2026-09-23

**Status**: Draft

**Input**: User description: "keep host aware while any chats are running"

## Why this feature exists

Everything this app is for happens while nobody is watching. You send an agent off on
twenty minutes of work and you go and do something else, which is the entire point: the
daemon outlives the window precisely so that walking away costs nothing.

Except that it does. Fifteen minutes later the Mac reaches its idle timer and goes to
sleep, and the agent goes with it — not stopped, not finished, just suspended somewhere in
the middle of a turn. What you come back to depends on how long you were gone and what the
runtime made of waking up with its connections dead. In the good case the turn resumes
late. In the ordinary case it is a stopped agent, its process recorded as having died, and
a half-finished edit on disk.

Nothing in the app is wrong. The agent is running, the daemon is holding it, the record is
accurate. The machine underneath simply does not know that any of this is work, because
nothing has ever told it. macOS has one question it asks before idling — is anybody doing
anything? — and the answer it gets is about keyboards and mice.

So the fix is one sentence long: while a turn is in flight, say so. Hold the Mac awake for
exactly that window and not a moment past it, and let it sleep the rest of the time like
any other Mac.

The discipline is all in "not a moment past it". A power assertion is a promise that real
work is pending, and an app that holds one permanently is an app that has quietly decided
your laptop's battery is its business. This one is held by turns in flight and by nothing
else: not by an agent waiting for you to answer it, not by the window being open, not by
the daemon merely being alive.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A turn does not die because you walked away (Priority: P1)

You give an agent a job that will take half an hour, and you leave the Mac. You come back
to a finished turn and an agent under **Done**, with the work in the folder. The Mac was
untouched for the whole thirty minutes and it never slept.

**Why this priority**: This is the feature, and it is the whole of the value. Everything
below is about giving the wakefulness back afterwards. On its own it is the difference
between an app you can leave and an app you have to sit in front of.

**Independent Test**: Set the Mac's idle sleep to two minutes. Start an agent on a task
that runs for five. Do not touch the machine. Confirm it is still awake at five minutes,
and that the turn reached its own end rather than being picked up afterwards.

**Acceptance Scenarios**:

1. **Given** an agent with a turn in flight, **When** the Mac has gone past its idle sleep
   timer with no input, **Then** the Mac stays awake and the turn keeps running.
2. **Given** an agent that is being started, **When** the idle timer would fire before its
   first turn begins, **Then** the Mac stays awake — a session being made is work in
   flight.
3. **Given** several agents with turns in flight at once, **When** the last of them ends,
   **Then** the Mac was held awake for the whole overlapping span and is released once.
4. **Given** the app's window has been closed while agents keep working, **When** the idle
   timer fires, **Then** the Mac still stays awake — the agents are what hold it, not the
   window.
5. **Given** an agent whose turn ends and is picked up again by a queued prompt, **When**
   the gap between the two turns falls inside the idle timer, **Then** the Mac is not
   allowed to sleep in the gap.

---

### User Story 2 - It gives the Mac back the moment the work is done (Priority: P2)

The last agent finishes at 11:40. By 11:41 the Mac is an ordinary Mac again, idling toward
sleep on its own schedule as though this app had never been installed.

**Why this priority**: Equal in importance to holding it, and separated only because it is
testable on its own. A hold that is not released is not a feature, it is a bug that
happens to be useful once; the person's evidence that this app is trustworthy with their
machine is that their machine sleeps when it should.

**Independent Test**: With the idle sleep timer at two minutes, run an agent to
completion, then leave the Mac alone and confirm it sleeps on schedule from the moment the
turn ended — not from the moment you last touched it.

**Acceptance Scenarios**:

1. **Given** the only turn in flight ends normally, **When** it ends, **Then** the hold is
   released and the Mac's idle countdown runs from that moment.
2. **Given** an agent that ends its turn by asking you something and waiting, **When** it
   begins waiting, **Then** the hold is released — an agent blocked on a person is not
   work in flight, and a Mac held awake all night for a question is the exact abuse this
   feature must not commit.
3. **Given** an agent you stop by hand mid-turn, **When** it stops, **Then** the hold is
   released immediately rather than at the end of the turn it never reached.
4. **Given** an agent whose runtime process dies mid-turn, **When** the death is noticed,
   **Then** the hold is released.
5. **Given** the daemon exits because it holds no agents and no window is connected,
   **When** it exits, **Then** nothing anywhere is still holding the Mac awake.
6. **Given** the daemon is killed outright while holding the Mac awake, **When** it dies,
   **Then** the hold dies with it and the Mac is free to sleep with no cleanup required.

---

### User Story 3 - A laptop on battery is not drained flat (Priority: P2)

You start a long turn, unplug, and put the laptop on the sofa. It keeps working. Two hours
later the battery is down to the reserve and the Mac stops fighting its own idle timer and
sleeps, with charge left in it.

**Why this priority**: Without this the feature is a promise to hold a laptop awake until
it is dead, which is worse than sleeping mid-turn: a stalled turn is recoverable and a
flat battery in a bag is a Mac that is gone until it finds a charger. Second rather than
first because it only matters after Story 1 works.

**Independent Test**: With the machine on battery below the floor, start an agent and
confirm the Mac is allowed to sleep on its idle timer. Plug it in and confirm a turn in
flight holds it awake again.

**Acceptance Scenarios**:

1. **Given** the Mac is on mains power, **When** a turn is in flight, **Then** it is held
   awake regardless of the battery's charge.
2. **Given** the Mac is on battery above the reserve floor, **When** a turn is in flight,
   **Then** it is held awake.
3. **Given** the Mac is on battery and the charge falls below the floor while a turn is in
   flight, **When** it crosses, **Then** the hold is released and the Mac may sleep, even
   though the turn is unfinished.
4. **Given** the Mac is on battery below the floor and is then plugged in, **When** a turn
   is still in flight, **Then** the hold is taken up again without waiting for the next
   turn.
5. **Given** a desktop Mac with no battery at all, **When** a turn is in flight, **Then**
   it is held awake and no battery rule applies.

---

### User Story 4 - You can tell why your Mac did not sleep (Priority: P3)

You notice the Mac is still awake at midnight, wonder for a second whether something is
wrong, look, and find that it is holding itself awake for an agent that is still working —
and which agent it is.

**Why this priority**: A machine behaving unusually with no visible cause is how an app
loses the benefit of the doubt. Third because the person can already see that an agent is
running, and this only connects the two facts; the feature is honest without it and merely
mute.

**Independent Test**: With a turn in flight, confirm the app says the Mac is being kept
awake. Let the turn end and confirm it stops saying so.

**Acceptance Scenarios**:

1. **Given** the Mac is being held awake, **When** you look at the app, **Then** it says
   so, and the statement is reachable without hunting.
2. **Given** nothing is being held, **When** you look, **Then** the app says nothing about
   sleep at all.
3. **Given** the hold has been released because the battery fell below the floor while a
   turn is still running, **When** you look, **Then** the app says that is why, rather
   than showing the same thing it shows when no agent is working.

---

### Edge Cases

- **You close the lid.** The hold has no power to stop this and must not pretend
  otherwise. The Mac sleeps, the turn goes with it, and the agent is picked up the usual
  way afterwards.
- **You choose Sleep from the Apple menu, or press the power button.** An explicit
  instruction from the person beats a pending turn. The Mac sleeps.
- **The display sleeps or the Mac locks.** Neither affects the hold. The screen going dark
  is not the machine stopping, and a Mac that keeps working behind a lock screen is the
  intended behaviour.
- **Low Power Mode is on.** The hold still applies; the system's own throttling is left
  alone. Low Power Mode is a request to use less energy, not a request to abandon work in
  progress.
- **The Mac is already asleep when a workflow tries to start an agent.** Nothing here
  wakes it. A hold keeps an awake Mac awake and cannot rouse a sleeping one; that is a
  different feature and it is out of scope.
- **An agent runs for eleven hours.** The hold runs with it. The brake on a runaway agent
  is the cost ceiling that already exists, not a separate clock on wakefulness — two
  ceilings that can disagree is worse than one.
- **A turn ends and another begins microseconds later.** The Mac must not be handed back
  and taken again in a way that lets a sleep slip through the gap.
- **Two copies of the app, each with its own daemon.** Each holds for its own agents; the
  Mac is awake while either has work, and sleeps when neither does.
- **The clock changes, or the machine wakes from a sleep it did manage to enter.** The
  hold is re-derived from what the agents are doing now, not from what was true before.

## Requirements *(mandatory)*

### Functional Requirements

#### What holds the Mac awake

- **FR-001**: The system MUST prevent the Mac from entering idle system sleep while at
  least one agent has a turn in flight.
- **FR-002**: "A turn in flight" MUST mean an agent that is *starting* or *working*. This
  is the app's existing notion of a busy conversation, less the one case below; there MUST
  NOT be a second definition of what counts as working.
- **FR-003**: An agent waiting on the person MUST NOT hold the Mac awake, and neither MUST
  one that has finished, been stopped, or been archived.
- **FR-004**: The system MUST release the hold within 5 seconds of the last turn in flight
  ending, by any route: the turn completing, the agent blocking on a question, the person
  stopping it, its process dying, or a later daemon finding it dead.
- **FR-005**: The hold MUST be taken by whichever part of the system owns the agents, so
  that it survives the window being closed and applies to agents started with no window
  present.
- **FR-006**: The system MUST hold at most one claim at a time however many agents are
  working, and MUST NOT let go while any turn is still in flight — including across the
  gap between one turn ending and a queued prompt beginning the next.

#### What it does not touch

- **FR-007**: The hold MUST NOT prevent the display sleeping, the screen locking, or any
  sleep the person asks for explicitly — the lid, the Apple menu, the power button.
- **FR-008**: The hold MUST NOT attempt to wake a sleeping Mac, and the system MUST NOT
  present it as though it could.

#### Power

- **FR-009**: The system MUST take the hold when the Mac is on mains power, whatever the
  battery's charge.
- **FR-010**: On battery, the system MUST take the hold while the charge is above the
  reserve floor, and MUST release it once the charge reaches or falls below the floor,
  even with a turn still in flight.
- **FR-011**: The system MUST reconsider the hold when the power source changes or the
  charge crosses the floor, without waiting for any agent's state to change.
- **FR-012**: On a Mac with no battery, the system MUST behave as though on mains power.

#### Not outliving its reason

- **FR-013**: The hold MUST NOT outlive the process that took it. If that process is
  killed or crashes, the Mac MUST be free to sleep with no cleanup by hand and no stale
  claim left behind.
- **FR-014**: The system MUST work out whether to hold from what the agents are doing now
  — at start-up, after waking from a sleep it did not prevent, and after reconnecting —
  rather than restoring a remembered decision.

#### Saying so

- **FR-015**: The system MUST make it visible that the Mac is being kept awake while it is
  being kept awake, naming the work it is being kept awake for, and MUST stop saying so
  once released.
- **FR-016**: When the hold has been let go because the battery reached the floor while
  work is still in flight, the system MUST say that, distinguishably from saying nothing
  is running.
- **FR-017**: The system MUST record when the hold is taken and let go, so that a Mac which
  slept mid-turn can afterwards be told apart from one that was never held.

### Key Entities

- **The hold**: The single, at-most-one claim on the Mac's idle sleep. It exists only while
  it is justified; it knows what it is for and when it was taken, and it is persisted
  nowhere.
- **Work in flight**: Whether at least one agent is starting or working. The only
  agent-side input to the hold.
- **Power condition**: Whether the Mac is on mains, and if not, whether its charge is above
  the reserve floor. The only machine-side input to the hold.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A turn left running with nobody touching the Mac completes at the same rate
  as one watched from start to finish — zero interruptions attributable to idle sleep over
  20 unattended turns each exceeding the machine's idle timer.
- **SC-002**: Once the last turn in flight ends, the Mac begins idling toward sleep within
  5 seconds, and sleeps no later than a Mac with this app closed entirely.
- **SC-003**: With no turn in flight, the Mac's measured sleep behaviour is indistinguishable
  from the same Mac with the app not running, over a one-hour idle window.
- **SC-004**: An agent left waiting on a person overnight costs zero minutes of extra
  wakefulness.
- **SC-005**: A laptop on battery running an unattended turn never discharges below the
  reserve floor as a result of being held awake.
- **SC-006**: Killing the process that is holding the Mac awake leaves the machine sleeping
  on its normal timer immediately afterwards, with nothing for the person to clear up and
  no claim on its sleep outstanding.
- **SC-007**: A person who notices the Mac is awake can find out why from the app in under
  10 seconds, without opening any other application.

## Assumptions

- **"Host" means this Mac, and "aware" means awake.** The feature is about the machine's
  idle sleep and nothing else.
- **Turns in flight only**, per the answer given: a starting or working agent holds the
  Mac, and one waiting on the person does not. The consequence is accepted and stated
  plainly — a question answered from the phone reaches a Mac that may by then be asleep,
  and the agent resumes when the Mac next wakes. Reaching a sleeping Mac is 005/021's
  problem, not this one's.
- **System sleep only**, per the answer given. The display is left entirely alone, so a Mac
  working through the night is a dark, locked Mac.
- **The battery floor is 20%** unless stated otherwise, matching the point at which macOS
  itself starts warning. It is a single figure, not a user setting, in this version.
- A power assertion keeps an awake Mac awake and cannot wake a sleeping one; it has no
  effect in dark wake and does not survive the lid closing. This is a documented limit
  (see `specs/005-mobile-remotes/research.md` §10) and the feature does not attempt to
  work around it.
- The existing cost ceilings (feature 010) are the brake on an agent that runs away, so no
  separate maximum duration is placed on the hold.
- No user-facing setting to disable this is provided in this version. The hold is narrow
  enough to need no escape hatch; if that proves wrong it is a follow-up, not a
  prerequisite.
- The daemon already knows every agent's state and every transition between states, so the
  hold can be derived rather than reported.
