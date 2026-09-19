# Feature Specification: Cursor makes four

**Feature Branch**: `006-cursor-cli-runtime`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "Add support for the Cursor CLI." (`/speckit-specify` was invoked with no argument, immediately after establishing that Cursor CLI is not one of the runtimes this app can start.)

## Why this feature exists

The app knows three runtimes: Claude, Grok and Copilot. Cursor ships a command line agent that speaks
the same protocol the other three speak, and a lot of the people who would use this app already pay for
Cursor. Today they open the runtime list, do not find it, and that is the end of the conversation.

The app was built so this would be cheap. A runtime is a recipe, not a special case: the picker, the
sign-in panel, the agent rows and the daemon all read from one list and ask the runtime itself what it
can do. Adding Cursor should be adding an entry, and everything downstream should already be true.

The part that is not free is what Cursor says back. It sends requests the protocol does not define, and
two of them block: it asks the app a question and waits for an answer. A runtime that asks a question
nobody answers is an agent that never finishes its turn. That is the work in this feature, and it is
also the test of a claim the app already makes, that nothing a runtime sends can lose an agent.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start an agent on Cursor (Priority: P1)

The user has the Cursor CLI installed and signed in. They start a new agent, and Cursor is in the list
of runtimes beside Claude, Grok and Copilot. They pick it, give it a folder and a prompt, and it works
the way the other three do: the reply streams in, edits arrive as diffs, commands show their output,
and what the turn cost goes on the record.

**Why this priority**: This is the feature. Everything else is what happens when it is not this easy.

**Independent Test**: With the Cursor CLI installed and signed in, start an agent on Cursor, send a
prompt that reads a file and edits it, and confirm the transcript, the diff and the turn's cost are the
same shape as the same prompt run on Claude.

**Acceptance Scenarios**:

1. **Given** the Cursor CLI is installed, **When** the user opens the list of runtimes, **Then** Cursor
   is in it, named "Cursor", beside the other three.
2. **Given** Cursor is picked and a folder chosen, **When** the user sends a prompt, **Then** the agent
   starts, the reply streams into the transcript, and the agent appears under its project like any
   other agent.
3. **Given** a Cursor agent is mid turn, **When** it asks to run a command or write a file, **Then** the
   user gets the same permission question, with the same allow-once and allow-always answers, as on any
   other runtime.
4. **Given** a Cursor agent has finished a turn, **When** the transcript is read, **Then** whatever
   Cursor reported about tokens and cost is shown as it reported it, and nothing is estimated.
5. **Given** a Cursor agent exists, **When** the user quits the window and opens it again, **Then** the
   agent is still there and its conversation is intact, the same as for the other runtimes.
6. **Given** Cursor advertises that it can load a session, **When** the user returns to a Cursor agent
   after the daemon has restarted, **Then** the conversation resumes rather than starting over.

---

### User Story 2 - Say plainly why it cannot be used (Priority: P2)

The user does not have the Cursor CLI, or has it and has never signed in. They pick Cursor and the app
tells them which of those two it is, and what to do about it, without them having to guess.

**Why this priority**: Most people meeting this feature for the first time are in one of those two
states. Getting it wrong here looks like the app is broken rather than that a command is missing.

**Independent Test**: With the Cursor CLI not on the path, confirm the runtime shows as missing and says
where the app looked. Then install it, sign out, and confirm the app offers Cursor's own way of signing
in rather than repeating the missing-command message.

**Acceptance Scenarios**:

1. **Given** the Cursor CLI is not installed, **When** the runtime list draws, **Then** Cursor is shown
   as missing and says which directories were searched, the same as a missing Grok or Copilot.
2. **Given** the Cursor CLI is installed but not signed in, **When** a turn is refused for want of an
   account, **Then** the runtime moves to needing sign-in and offers the sign-in method Cursor itself
   advertises.
3. **Given** the sign-in Cursor advertises can only be done in a terminal, **When** the user chooses it,
   **Then** the app offers the command to run rather than pretending it can do it in the window.
4. **Given** the user signs in outside the app, **When** the app next shakes hands with Cursor, **Then**
   the runtime goes back to ready without the app being restarted.
5. **Given** Cursor is installed under a name or a path the app did not expect, **When** the runtime is
   reported as missing, **Then** the message names what the app tried to run, so the user can see why.

---

### User Story 3 - Answer the questions Cursor asks (Priority: P3)

Cursor does not only send what the protocol defines. Mid turn it asks the app a question and waits, or
it announces a plan, or a list of things it means to do. The user sees those where the app already
shows that sort of thing, and a question Cursor asks reaches them as something they can answer.

**Why this priority**: Without this the feature still works for plain prompts, which is why it is third.
But a blocking question nobody answers is an agent stuck until it is stopped, so at minimum the app has
to refuse cleanly and let the turn end. Answering it is the better half of the same problem, and it
turns Cursor's most distinctive behaviour into the thing the window is already organised around: agents
that need you.

**Independent Test**: Give a Cursor agent a prompt vague enough that it asks a question, and confirm the
agent moves to needing input, that answering it lets the turn carry on, and that the agent is never left
waiting on something the user cannot see.

**Acceptance Scenarios**:

1. **Given** Cursor sends a request the app does not understand, **When** it arrives, **Then** the app
   answers it rather than leaving it open, and the agent finishes its turn instead of hanging.
2. **Given** Cursor asks the user a question mid turn, **When** the request arrives, **Then** the agent
   moves to needing input and the question is shown with the answers Cursor offered.
3. **Given** a question from Cursor is on screen, **When** the user answers it, **Then** the turn carries
   on from that answer, and the question and the answer stay on the record.
4. **Given** Cursor sends a plan or a list of things it means to do, **When** it arrives, **Then** it is
   shown where the app already shows a plan, and it updates in place as Cursor changes it.
5. **Given** Cursor sends something the app has no place for, **When** it arrives, **Then** nothing is
   dropped silently and nothing about the agent is lost.
6. **Given** a Cursor agent is waiting on a question, **When** the user stops the agent instead of
   answering, **Then** the agent stops cleanly and the waiting request is closed.

---

### Edge Cases

- What happens when the Cursor CLI is installed but too old to speak the protocol at all? The handshake
  fails, and the runtime is shown as failed with what it said, not as missing.
- What happens when the user is signed in but out of credit or over a rate limit? The turn fails with
  what Cursor said, and the runtime does not quietly become "not signed in".
- What happens when Cursor asks a blocking question and the user closes the window without answering?
  The agent lives in the daemon, so it is still waiting when the window comes back, and still answerable.
- What happens when Cursor asks a blocking question and the process dies before it is answered? The
  agent ends the way any agent whose runtime died ends, and the unanswered question does not linger as
  something the user can still click.
- What happens when a Cursor agent is sent a picture or a file it cannot take? It is refused before the
  prompt goes, on what Cursor said it accepts, the same as every other runtime.
- What happens when Cursor's own configuration points at MCP servers? Those are Cursor's business. The
  app does not read or write that configuration.
- What happens when two runtimes are signed in as different people? Nothing changes: an account is held
  per runtime, and Cursor's is its own.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST offer Cursor as a runtime everywhere it offers Claude, Grok and Copilot: the
  new-agent picker, the runtime list, the sign-in panel, and the runtime shown on an agent.
- **FR-002**: The app MUST decide what a Cursor agent can do from what Cursor advertises at handshake,
  not from the fact that it is Cursor.
- **FR-003**: The app MUST find the Cursor CLI the way it finds the others, by looking on the user's
  login shell path, and MUST report which directories it looked in when it is not found.
- **FR-004**: The app MUST tell apart "not installed", "installed but not signed in" and "installed and
  failed", and MUST say which one it is.
- **FR-005**: The app MUST offer the sign-in methods Cursor advertises, including offering a command to
  run when the method needs a terminal.
- **FR-006**: The app MUST refresh what it knows about the Cursor account on every handshake, so signing
  in outside the app is picked up without a restart.
- **FR-007**: A Cursor agent MUST be started, stopped, archived, resumed and recorded by the daemon on
  the same terms as any other agent, with the same files on disk.
- **FR-008**: The app MUST answer every request Cursor sends, including ones it does not understand, so
  that a turn can always end.
- **FR-009**: The app MUST surface a blocking question from Cursor as something the user can answer, put
  the agent into the state that means it needs the user, and carry the answer back to Cursor.
- **FR-010**: The app MUST record a question from Cursor and its answer in the transcript, so the record
  is complete.
- **FR-011**: The app MUST show a plan or task list from Cursor where it already shows a plan, updating
  it in place rather than repeating it.
- **FR-012**: The app MUST NOT lose, hide or corrupt an agent because of anything Cursor sends that it
  does not recognise.
- **FR-013**: The app MUST show what Cursor reports about tokens and cost as reported, per currency, and
  MUST NOT estimate.
- **FR-014**: The app MUST refuse an attachment Cursor cannot take before the prompt is sent, based on
  what Cursor said it accepts.
- **FR-015**: The app MUST NOT read or modify the user's Cursor configuration, credentials or MCP server
  definitions.

### Key Entities

- **Runtime**: An entry in the list of things the app knows how to start. Gains a fourth member, Cursor,
  with a name the user sees and a recipe for starting it. No new fields.
- **Runtime account**: What is known about who is signed into a runtime and how to sign in. Gains a
  Cursor row, filled from Cursor's handshake like the others.
- **Agent**: Unchanged, except that its runtime may now be Cursor.
- **Question from the agent**: A blocking request from a runtime that carries a question and the answers
  it will accept, and that holds the turn until the user answers it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user with the Cursor CLI installed and signed in can start an agent on Cursor and get a
  first reply without leaving the app or editing any file.
- **SC-002**: A user without the Cursor CLI can tell from the app alone that it is not installed, and
  where the app looked, in one glance and without opening a log.
- **SC-003**: Every request Cursor sends during a turn is answered, so no agent is left waiting on the
  app. Measured as zero stuck turns across a run of the app's live runtime tests against Cursor.
- **SC-004**: A question Cursor asks reaches the user within a second of arriving, and answering it
  carries the turn on.
- **SC-005**: The same prompt run on Cursor and on Claude produces a transcript with the same parts:
  replies, diffs, command output, permission questions and cost.
- **SC-006**: Adding Cursor changes no behaviour of the three existing runtimes, shown by the existing
  tests passing unchanged.
- **SC-007**: Nothing about a Cursor agent is lost across a restart of the window or of the daemon.

## Assumptions

- The Cursor CLI speaks the protocol natively over standard input and output, started with its own
  subcommand, so no adapter package is needed the way Claude needs one. Which command exactly, and under
  what name the binary is installed, is for planning to confirm on the machine.
- Cursor's blocking extension requests are the only ones that can hold a turn open. Its notifications
  can be ignored without harm, which is why showing them is third in priority rather than first.
- The app already refuses a request it does not know rather than leaving it unanswered, so the "never
  stuck" half of User Story 3 is a thing to prove rather than to build. If that turns out not to hold,
  it is the first thing built.
- Signing into Cursor happens in Cursor's own way. The app does not hold a Cursor API key, and asking
  the user for one is out of scope.
- This feature adds one known runtime. Letting the user define a runtime of their own, with their own
  command and arguments, is a separate feature and is not included.
- Cursor's own ways of running, such as a chosen model or its MCP configuration, stay Cursor's. The app
  shows which provider or model the runtime reports, as it does for the others, and sets nothing.
- Running the app's live tests against Cursor needs a signed-in Cursor CLI on the machine, the same
  condition the existing live runtime tests already carry.
