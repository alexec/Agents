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

## What Cursor actually says

Feature 003 promised that every capability claim would be proved by handshake rather than read from
documentation. This one was, on 2026-09-18, against `cursor-agent` version 2026.09.10-fd3934a, signed
in, with a handshake and a `session/new` and nothing else. What follows is what came back, and the
requirements below are written against it rather than against Cursor's documentation.

- It speaks protocol version 1, the version this app speaks.
- It can load a session, so a conversation survives a restart.
- It takes pictures. It does not take embedded context, so a file goes by reference or not at all.
- It can list its sessions. It cannot fork or delete one.
- It offers one way to sign in, `cursor_login`, and advertises no way to sign out.
- It answers `session/new` with three modes, agent, plan and ask, and with more than twenty models.
  It offers no providers and no configuration options. The app deliberately reads none of this: modes
  and models from `session/new` are inconsistent between runtimes and are being retired from the
  protocol, and the app reads configuration options instead, which Cursor does not send.
- It sends its list of commands unprompted, about twenty of them, the moment a session exists.

Two of these are traps rather than facts, and the stories below are written around them.

The first is a name. Cursor's own sign-in method describes itself as "Run 'agent login' first if not
logged in". On this Mac `agent` is Grok, and Cursor is `cursor-agent`. A runtime's instructions are
about the runtime's idea of its own name, not about what this app runs.

The second is what did not appear. Cursor's extension requests, the ones that block, only arrive
during a turn, so a handshake cannot prove how they behave. They remain the part of this feature that
has to be proved by running one.

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
6. **Given** Cursor says it can load a session, which it does, **When** the user returns to a Cursor
   agent after the daemon has restarted, **Then** the conversation resumes rather than starting over.
7. **Given** Cursor takes pictures but not embedded context, **When** the user attaches a file, **Then**
   a picture goes by value, a file goes by reference, and neither is sent in a form Cursor refuses.
8. **Given** Cursor sends its list of commands as soon as the session exists, **When** they arrive,
   **Then** they are offered to the user the same way any other runtime's commands are.

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
4. **Given** Cursor's sign-in method describes itself as "Run 'agent login' first", and `agent` on this
   Mac is Grok, **When** the app offers a command to run, **Then** the command names what this app
   actually starts, and the user is never sent to another runtime's binary.
5. **Given** the user signs in outside the app, **When** the app next shakes hands with Cursor, **Then**
   the runtime goes back to ready without the app being restarted.
6. **Given** Cursor advertises no way to sign out, **When** the sign-in panel draws, **Then** signing
   out is not offered for Cursor, the same as for any runtime that does not advertise it.
7. **Given** Cursor is installed under a name or a path the app did not expect, **When** the runtime is
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
  prompt goes, on what Cursor said it accepts, the same as every other runtime. In Cursor's case that
  means a picture goes by value and a file goes by reference.
- What happens when another runtime is installed under a name Cursor's documentation uses for itself?
  It already is: `agent` on this Mac is Grok. The app starts what its own entry names and never what a
  runtime's description suggests.
- What happens when Cursor offers a model the user would rather use? Nothing, in this feature. Cursor
  offers more than twenty and the app sets none of them, for Cursor or for anyone else.
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
- **FR-005a**: When the app offers a command to run, that command MUST be the one this app starts. A
  runtime's own description of how to sign in MUST NOT be passed on as an instruction when it names a
  command the app does not use, because a runtime names itself by its own idea of its name.
- **FR-005b**: The app MUST NOT offer signing out for a runtime that does not advertise it. Cursor does
  not.
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
  what Cursor said it accepts. Cursor takes pictures and does not take embedded context, so a file goes
  to it by reference.
- **FR-014a**: The app MUST offer the commands Cursor sends, which arrive unprompted as soon as a
  session exists, the same way it offers any other runtime's commands.
- **FR-014b**: The app MUST NOT show a model or a mode for Cursor that it cannot also set. Cursor
  reports its models and modes in a place the app deliberately does not read, so the honest answer is
  to show nothing rather than to show a name that cannot be changed.
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
- **SC-008**: Every command the app tells a user to run is a command that works on their Mac. No
  instruction the app shows sends the user to a binary belonging to a different runtime.
- **SC-007**: Nothing about a Cursor agent is lost across a restart of the window or of the daemon.

## Out of Scope

- A runtime the user defines themselves, with their own command and arguments. This feature adds one
  known runtime to a fixed list.
- Holding a Cursor API key, or any way of signing in beyond what Cursor advertises at handshake.
- Reading or writing Cursor's own configuration, including the MCP servers it defines.
- Choosing which model or which of Cursor's three modes an agent runs on. The app reads no runtime's
  models today, and changing that is a decision for all four runtimes rather than for this one.
- Cursor on the iPhone and iPad remotes. Feature 005 decides what a remote does with the runtime list,
  and a fourth entry arrives there for free or does not, on 005's terms rather than this feature's.
- Any change to how Claude, Grok or Copilot behave.

## Assumptions

- Confirmed rather than assumed: the Cursor CLI speaks the protocol natively over standard input and
  output, so no adapter package is needed the way Claude needs one. On this Mac the binary is
  `cursor-agent` and the subcommand is `acp`, which the command's own help does not list.
- Cursor's blocking extension requests are the only ones that can hold a turn open. Its notifications
  can be ignored without harm, which is why showing them is third in priority rather than first. A
  handshake cannot prove this, because none of them arrive until a turn is running, so planning proves
  it by running one.
- The app already refuses a request it does not know rather than leaving it unanswered, so the "never
  stuck" half of User Story 3 is a thing to prove rather than to build. If that turns out not to hold,
  it is the first thing built.
- Signing into Cursor happens in Cursor's own way, and what the app can offer is whatever Cursor
  advertises at handshake, which is one method and no way to sign out.
- Cursor's own ways of running stay Cursor's. It reports its models and its three modes in the one
  place the app has decided not to read, and offers none of the providers or configuration options the
  app does read, so a Cursor agent runs on whatever Cursor picks and the app says nothing about it.
  Reading them would mean reopening a decision feature 003 made for all runtimes, which is a bigger
  feature than this one.
- Running the app's live tests against Cursor needs a signed-in Cursor CLI on the machine, the same
  condition the existing live runtime tests already carry.

## Dependencies

- **Feature 001**, which owns the daemon, the agent record, the transcript and the permission
  question. FR-007 asks for nothing new from it: a Cursor agent is an agent.
- **Feature 003**, which owns almost everything this feature leans on and should be read first:
  - User Story 1 and FR-001 onward decide what an agent can do from what its runtime advertises.
    FR-002 here is that rule applied to a fourth runtime, not a new rule.
  - User Story 5 owns signing in, signing out and who is answering. FR-004 to FR-006 here are its
    behaviour with Cursor's account in it.
  - User Story 6 owns the plan. FR-011 here adds nothing but Cursor's way of sending one.
  - User Story 7 owns picking up a session the app did not start. User Story 1 scenario 6 here is
    that, for Cursor.
  - User Story 9 owns answering a structured question from an agent, and was written for exactly this
    moment: "no runtime we support asks for this yet". Cursor is the runtime that asks. The catch is
    that it asks by a name of its own rather than by the protocol's, so the form User Story 9 builds
    will not recognise it by shape. Planning must decide whether Cursor's questions are translated
    into that form or answered separately, and doing it twice would be the wrong answer.
- **Feature 004**, which owns the group that means an agent is waiting on the user. User Story 3
  scenario 2 here puts a Cursor agent in it and adds nothing to how the group works.
- **Feature 005**, only in that it will inherit a fourth runtime. Nothing here depends on it.
- **Feature 003, task T076**, still open: what a signed-out runtime actually returns has never been
  confirmed against any runtime, and `RuntimeDiscovery` says so in as many words. User Story 2
  scenario 2 here cannot be proved until it is. Cursor could answer it, but only by signing out of a
  real account and back in, so that is the user's call to make and not a thing to do on the way past.
- **The runtimes on this Mac.** Feature 003 promised that every capability claim would be proved by
  handshake against the three runtimes rather than by reading their documentation. A fourth runtime
  reopens that promise, and every claim about Cursor in this spec is to be proved the same way.
