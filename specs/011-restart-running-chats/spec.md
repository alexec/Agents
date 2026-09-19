# Feature Specification: A Restarted Background Service Picks Up the Chats That Were Working

**Feature Branch**: `011-restart-running-chats`

**Created**: 2026-09-19

**Status**: Draft

**Input**: User description: "A restarted daemon should restart running chats."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The work you left running is still running when you come back (Priority: P1)

Someone sets an agent going on a long piece of work — a refactor, a test run, a search across a
repository — and walks away. While they are gone the machine reboots for an update, or the app
crashes, or they log out and back in. Nobody decided to abandon that work. Today they come back
to a chat sitting stopped half way down the page, and the only way to get it moving again is to
notice it, open it, work out what it had got to, and type something. Often they do not notice at
all, and the work simply never happened.

What they should come back to is a chat that picked itself back up: the same conversation, the
same folder, the same agent, carrying on from where it was cut off.

**Why this priority**: It is the whole feature. Everything else in this spec exists to make this
one behaviour honest and safe. Without it, an ending nobody chose silently throws away however
long the agent had been working.

**Independent Test**: Start an agent on a piece of work that takes more than a moment, kill the
background service outright while the agent is mid-turn, start it again, and confirm the chat is
working again on its own without anybody typing into it.

**Acceptance Scenarios**:

1. **Given** a chat whose agent was mid-turn when the background service stopped, **When** the service starts again, **Then** that chat is working again without the person doing anything.
2. **Given** such a chat, **When** it is picked back up, **Then** it continues the same conversation rather than starting a new one — everything said before is still above it in the same chat.
3. **Given** such a chat, **When** it is picked back up, **Then** it runs in the same folder, with the same agent, and with the same settings it had before.
4. **Given** several chats were working when the service stopped, **When** it starts again, **Then** every one of them is picked back up.
5. **Given** a chat that was waiting on a question it had asked the person, **When** the service starts again, **Then** it is picked back up too, because a question with nobody left to answer it is work cut off just the same.
6. **Given** nobody has the app open when the service starts, **When** chats are picked back up, **Then** they still run, and the service stays alive for as long as they need rather than deciding it has nothing to do.

---

### User Story 2 - Nobody is told anything untrue about what happened (Priority: P2)

Two people need the truth about the interruption: the person, who opens the chat and sees a reply
that stops in the middle of a sentence; and the agent, which is handed back a conversation whose
last turn it cannot remember the end of. An agent that is simply spoken to again with no
explanation will assume the last thing it tried worked, and carry on from a state that never
existed.

**Why this priority**: Picking a chat back up without this is worse than not picking it up at all,
because it turns a visible stop into an invisible wrong answer. It cannot be done separately from
Story 1, but it can be judged separately.

**Independent Test**: Interrupt a chat mid-turn, restart the service, and read the chat from the
top. It should be possible to tell, from the transcript alone, exactly where the interruption was
and that the agent was told about it.

**Acceptance Scenarios**:

1. **Given** a chat cut off by the service stopping, **When** the person opens it, **Then** the transcript says plainly, at the point of the break, that the chat stopped because the app did.
2. **Given** that same chat, **When** it is picked back up, **Then** the agent is told that the app restarted, that its turn was cut off, and that it should check what it had actually finished rather than assume its last step succeeded.
3. **Given** a chat that was holding a question open, **When** it is picked back up, **Then** the agent is additionally told that the question went with the restart, so it can ask again if it still needs the answer.
4. **Given** the words the app says to the agent on its behalf, **When** they appear in the transcript, **Then** they are visibly the app speaking and not the person, so that a person reading back can tell who said what.
5. **Given** a chat that is on its way back up but has not started working yet, **When** the person looks at it, **Then** it is clear that it is coming back rather than appearing to be stopped for good or silently flickering into life.
6. **Given** the interruption happened while the person was away, **When** they return, **Then** what they see in the chat list and what they see inside the chat agree with each other about its state.

---

### User Story 3 - A chat that cannot be picked back up says so and stays where it is (Priority: P3)

Some chats cannot be resumed: the agent they were using has been uninstalled or moved, the folder
they were working in is gone, or starting it simply fails. The failure must be visible in the
chat, and it must not leave anything primed to happen later — an agent told next week that the app
has just restarted is being told something untrue.

**Why this priority**: It is the failure path of Story 1, and the case where quietly doing nothing
leaves the person with no way to find out why. It sits below Story 2 because it affects the
minority of chats rather than all of them.

**Independent Test**: Interrupt a chat whose agent is then made unavailable, restart the service,
and confirm the chat stays stopped, says why in plain words, and offers the person a way to pick
it up themselves.

**Acceptance Scenarios**:

1. **Given** a chat whose agent can no longer be started, **When** the service tries to pick it back up, **Then** the chat stays stopped and says in the transcript why it could not be picked back up.
2. **Given** that same chat, **When** the person reads the explanation, **Then** it tells them they can pick it up themselves by sending it a message.
3. **Given** a chat that failed to be picked back up, **When** the person later sends it a message, **Then** nothing left over from the failed attempt is sent along with it.
4. **Given** one chat fails to be picked back up, **When** the service works through the rest, **Then** the others are still picked back up.
5. **Given** a chat that was deleted, archived, or already spoken to by the person between the interruption and the attempt, **When** the service reaches it, **Then** it is left alone.

---

### User Story 4 - Coming back does not overwhelm the machine, and does not loop (Priority: P4)

Half a dozen chats coming back at once is half a dozen agent processes starting at once, on a
machine that has very likely just booted. And a chat whose work is what brought the service down
in the first place will, if picked back up unconditionally, bring it down again, and again, with
each round spending real money.

**Why this priority**: Both are about the restart being safe to leave switched on. They are felt
rarely, but when they are felt they are severe: an unusable machine, or an unbounded bill.

**Independent Test**: Interrupt several chats at once, restart the service, and watch them come
back one after another rather than all together. Separately, arrange a chat that ends the service
each time it runs, and confirm the app stops picking it back up rather than cycling forever.

**Acceptance Scenarios**:

1. **Given** several chats to pick back up, **When** the service starts them, **Then** they start one at a time rather than all at once.
2. **Given** several chats to pick back up, **When** the person opens the app during this, **Then** they can watch them come back rather than connecting to find it already over or still frozen.
3. **Given** a chat that has already been picked back up once and was cut off again by the service stopping, **When** the service starts again, **Then** that chat is not picked back up a second time in a row; it stays stopped and says why, so that a chat that is itself the cause of the crash cannot loop.
4. **Given** a chat that was picked back up and then ran to a normal finish, **When** it is later interrupted again, **Then** it is eligible to be picked back up again — one successful run clears the count.
5. **Given** chats are being picked back up, **When** the person quits or stops one of them by hand, **Then** it stops immediately and is not started again.

---

### User Story 5 - Only the work that was actually cut off comes back (Priority: P5)

A chat the person stopped themselves, a chat that finished and said its piece, and a chat they
archived are all endings somebody chose. None of them should come back to life because the machine
rebooted.

**Why this priority**: It is the boundary of the feature. Getting it wrong turns a helpful restart
into an app that overrides the person's own decisions — but it is a narrower harm than the others
and is largely a matter of not doing something.

**Independent Test**: Leave one chat of each kind — finished, stopped by hand, archived, and
mid-turn — restart the service, and confirm exactly one of them is working afterwards.

**Acceptance Scenarios**:

1. **Given** a chat that finished normally, **When** the service restarts, **Then** it stays finished and nothing is sent to it.
2. **Given** a chat the person stopped by hand, **When** the service restarts, **Then** it stays stopped and nothing is sent to it.
3. **Given** an archived chat, **When** the service restarts, **Then** it stays archived and nothing is sent to it.
4. **Given** a chat whose agent process crashed on its own while the service was still running, **When** the service later restarts, **Then** it is not picked back up, because that ending had already been reported to the person at the time.
5. **Given** a mix of all of the above plus chats that were mid-turn, **When** the service restarts, **Then** only the mid-turn ones are picked back up.

---

### Edge Cases

- A chat is picked back up and the agent, on being told the app restarted, decides there is nothing left to do and simply finishes. That is a correct outcome, not a failure.
- The person opens the app and sends a message to an interrupted chat in the same moment the service is trying to pick it up. The chat must not end up running two turns or receiving the restart explanation twice.
- The person quits the app, or stops the chat, while it is on its way back up but has no agent running yet.
- The machine reboots again while chats are still being picked back up, so a second interruption lands on top of a first.
- The folder a chat was working in no longer exists, or is on a volume that has not mounted yet at the time the service starts.
- A chat was interrupted a long time ago — the machine was off for a week — and the restart explanation would now be describing something that did not just happen.
- The interrupted chat had messages already queued up and waiting to be sent when the service stopped.
- Picking chats back up would exceed whatever spending limits the person has set.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: On starting, the system MUST identify every chat that its record says was mid-turn — working, or waiting on a question it had asked — and treat those as cut off rather than as still live.
- **FR-002**: The system MUST record those chats as stopped, with the reason given as the service having gone, before it accepts any connection from the app, so that no window ever shows a state already known to be untrue.
- **FR-003**: The system MUST then pick each of those chats back up: continuing the same conversation, in the same folder, with the same agent and the same settings, without any action from the person.
- **FR-004**: The system MUST tell each picked-up chat's agent that the app restarted and that its turn was cut off, and MUST instruct it to verify what it had actually completed rather than assume its last action succeeded.
- **FR-005**: For a chat that was waiting on a question it had asked, the system MUST additionally tell the agent that the question went with the restart and it may ask again.
- **FR-006**: Anything the system says to an agent on its own behalf MUST be distinguishable in the transcript from what the person said.
- **FR-007**: The transcript of an interrupted chat MUST state, at the point of the break, that the chat stopped because the app did.
- **FR-008**: The system MUST pick chats back up only after it is reachable by the app, so that a person opening a window watches the chats return rather than finding it over.
- **FR-009**: The system MUST pick chats back up one at a time rather than concurrently.
- **FR-010**: While chats are on their way back up, the system MUST count them as work in hand and MUST NOT shut itself down for idleness underneath them.
- **FR-011**: The system MUST NOT pick back up a chat that finished, that the person stopped, that the person archived, or whose ending had already been reported to the person while the service was running.
- **FR-012**: The system MUST NOT pick back up a chat that has been deleted, archived, or already spoken to by the person between the interruption being recorded and the attempt being made.
- **FR-013**: When a chat cannot be picked back up, the system MUST leave it stopped, MUST say in that chat's transcript why it could not, and MUST tell the person they can pick it up themselves by sending a message.
- **FR-014**: When a chat cannot be picked back up, the system MUST discard the restart explanation rather than leave it queued, so that it is never delivered at a later time when it would no longer be true.
- **FR-015**: A failure to pick one chat back up MUST NOT prevent the remaining chats from being picked back up.
- **FR-016**: The system MUST NOT pick a chat back up more than once in a row without an intervening successful turn; a chat cut off again immediately after being picked up MUST be left stopped with an explanation, so that a chat which is itself causing the crash cannot loop.
- **FR-017**: A chat that is picked back up and reaches a normal end MUST become eligible to be picked back up again after a future interruption.
- **FR-018**: The app MUST show a chat that is on its way back up as returning, distinct from both stopped and working, and the chat list and the chat itself MUST agree about it.
- **FR-019**: The system MUST honour the person's existing spending limits when picking chats back up, and MUST NOT pick back up a chat that would breach them; where it declines for this reason it MUST say so in that chat.
- **FR-020**: Any messages the person had queued on a chat before the interruption MUST still be delivered in order after it is picked back up.
- **FR-021**: Stopping a chat by hand while it is on its way back up MUST stop it and MUST NOT result in it being started again.

### Key Entities

- **Chat**: One conversation with one agent in one folder. It has a state — working, waiting on a question, finished, stopped, archived — and, when it has ended, a reason. Only a chat left working or waiting when the service went is a candidate for being picked back up.
- **Interruption record**: What the chat was doing at the moment the service stopped, kept only for as long as it takes to say the right thing to that chat. A chat cut off mid-turn and one cut off holding a question open have different things to be told.
- **Restart explanation**: The words the app says to an agent on the person's behalf when picking it back up. It is about this minute, so it is discarded rather than deferred if it cannot be delivered now.
- **Pick-up attempt count**: What stops a chat that keeps taking the service down from being picked up forever. Cleared by a turn that ends normally.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Of chats that were mid-turn when the app stopped for a reason nobody chose, 100% are either working again or carrying a plain explanation of why not, within one minute of the app being opened again.
- **SC-002**: A person who leaves long-running work going and returns after an unexpected restart does not have to take any action to get that work moving again.
- **SC-003**: No chat that finished, was stopped by hand, or was archived is ever observed to start again on its own.
- **SC-004**: An agent picked back up never reports having completed work it did not complete; in trials of interrupted multi-step work, the agent re-checks its own progress before continuing in every case.
- **SC-005**: A restart that brings back ten chats at once leaves the machine usable throughout, and the person can open the app and interact with any chat while the rest are still returning.
- **SC-006**: A chat that reliably crashes the app is picked back up at most once per crash and never enters a repeating cycle, bounding the cost of the failure.
- **SC-007**: Every chat interrupted this way carries, in its own transcript, enough to explain what happened without the person consulting logs or support.

## Assumptions

- The ordinary way the app stops while chats are working is something nobody chose: a crash, a system update, a logout, or the machine rebooting. A person deliberately quitting does not leave chats mid-turn in the same way, because running work keeps the background service alive.
- Picking chats back up automatically is the wanted default and needs no switch. If it later proves unwelcome, an opt-out is a separate change.
- Restarting a chat means sending it a message and letting the ordinary path start the agent and continue the conversation. It is not a special kind of start with its own rules.
- The conversation itself survives the interruption and can be continued by the agent; this feature does not have to reconstruct history.
- Existing spending limits are the mechanism for bounding what an automatic restart can cost; this feature respects them rather than inventing its own.
- Terminals and shells are out of scope. This is about chats. A shell with a build running in it is separate work with its own rules.
- "One at a time" is enough to keep a just-booted machine usable; no separate throttle or delay between chats is assumed necessary.
- The explanation given to an agent is in English and in the app's own voice, matching how the app already speaks on the person's behalf elsewhere.

## Out of Scope

- Restoring anything about the agent's own working state beyond the conversation — open files, partial edits, or tool calls in flight.
- Bringing back shells, terminals, or builds that were running.
- A user-facing setting to disable automatic restart, or to choose which chats restart.
- Restarting chats on a second machine, or any transfer of running work between machines.
- Notifying the person outside the app that chats were picked back up.
