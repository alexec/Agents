# Feature Specification: Complete ACP coverage

**Feature Branch**: `003-acp-coverage`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "Complete ACP coverage. Close every gap found in the audit of our client against the official ACP schema (@agentclientprotocol/sdk 1.4.0, protocol version 1): richer prompt content (images, resource links, embedded context), client file system and terminal capabilities, usage and cost reporting, tool call content (diffs, terminal output, locations), plans, boolean config options and grouped select options, authentication (authenticate, logout, providers), session housekeeping (list, delete, fork, additionalDirectories), MCP servers, elicitation, compaction, and the robustness fixes (grouped option decode, -32000 auth errors, protocol version check, raw input lost on tool call merge, non-text content chunks)."

## Why this feature exists

Feature 001 built the smallest honest client: start an agent, talk to it, pick it up again. An audit
against the published protocol on 2026-09-18 found we use 8 of the 29 methods an agent offers,
answer 1 of the 14 an agent may ask of us, and read 10 of the 15 kinds of update an agent streams.
Some of those gaps were decisions. Others are silence: the app throws away numbers the runtime has
already sent, and one shape the protocol allows would stop an agent starting at all.

This feature closes the gaps. Where a gap was a deliberate decision, it is reopened here with the
reason it was made, so that keeping it is also a decision.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An agent starts whatever its runtime advertises (Priority: P1)

The user picks a runtime and a folder and starts an agent. It starts. That holds when the runtime
groups its models under headings, when it offers a setting that is on or off rather than one of a
list, when it answers with a protocol version we did not ask for, and when it is installed but not
signed in.

**Why this priority**: Everything else in the app is behind this. One option shape the protocol
allows, which no runtime sends today, currently fails the whole start rather than one control. A
runtime shipping that shape on a Tuesday would look like the app breaking.

**Independent Test**: Hand the client each option shape the protocol defines (flat list, grouped
list, boolean, a type it has never seen) and each start-time failure (not signed in, version
mismatch) and confirm an agent starts or fails with a sentence the user can act on.

**Acceptance Scenarios**:

1. **Given** a runtime whose choices arrive grouped under headings, **When** the user starts an
   agent, **Then** the agent starts and the control shows the choices under their headings.
2. **Given** a runtime offering a setting that is on or off, **When** the start form is shown,
   **Then** that setting appears as a switch and changing it takes effect.
3. **Given** a runtime offering a setting of a kind the app does not know, **When** the start form
   is shown, **Then** that one setting is left out and every other setting still works.
4. **Given** a runtime that is installed but not signed in, **When** the user tries to start an
   agent, **Then** the app says it needs signing in and offers the way to do it, rather than
   reporting an unspecified failure.
5. **Given** a runtime that answers with a protocol version the app does not speak, **When** the
   handshake finishes, **Then** the app says so plainly and does not pretend the session is healthy.
6. **Given** a tool call that reports what it was asked to do and later reports what it produced,
   **When** the user expands it, **Then** both are there.

---

### User Story 2 - Say it with a picture or a file (Priority: P2)

The user drags a screenshot onto the prompt, or types `@` and picks a file from the folder, and
sends it with the sentence. The agent receives the picture and the file reference rather than a
description of them.

**Why this priority**: This is the largest thing a person can want to do and cannot. Two of the
three runtimes accept images and all three accept file references, so the capability is sitting
there unused. A screenshot of a broken layout is the fastest way to describe a broken layout.

**Independent Test**: Start an agent, attach an image and a file reference to one prompt, and
confirm the agent's reply shows it received both.

**Acceptance Scenarios**:

1. **Given** a runtime that accepts images, **When** the user attaches one and sends, **Then** the
   prompt carries the image and the transcript shows it as part of what the user said.
2. **Given** a runtime that does not accept images, **When** the user tries to attach one, **Then**
   the app says that runtime cannot take pictures before the prompt is sent, not after.
3. **Given** the user types `@` in the prompt, **When** they choose a file from the folder, **Then**
   the prompt carries a reference to that file and shows its name.
4. **Given** an attachment larger than the runtime will accept, **When** the user sends, **Then**
   the app says so and the prompt is not lost.
5. **Given** an agent replies with a picture, **When** the transcript draws it, **Then** the picture
   appears rather than an empty line.

---

### User Story 3 - See the work, not the summary (Priority: P3)

An agent edits a file. The user expands the tool call and sees what changed: the old text and the
new, the path, the line. An agent runs a command and the output appears as output.

**Why this priority**: The transcript currently shows a title and, behind a click, the raw message
the runtime sent. Reading an agent's work is the main reason to watch an agent work.

**Independent Test**: Run a turn that edits a file and runs a command, then confirm the change is
shown as a change and the output as output.

**Acceptance Scenarios**:

1. **Given** a tool call carrying a change to a file, **When** the user expands it, **Then** the
   change is shown as before and after with the path, not as raw data.
2. **Given** a tool call carrying command output, **When** the user expands it, **Then** the output
   is shown as text, and it keeps arriving while the command is still running.
3. **Given** a tool call naming files and lines it touched, **When** the user chooses one, **Then**
   the app opens that file at that line in the user's editor.
4. **Given** a tool call carrying content in a form the app does not know, **When** the user expands
   it, **Then** the raw content is shown rather than nothing.

---

### User Story 4 - Know what it cost (Priority: P4)

While an agent works, the user can see how full its context window is and what the turn has cost so
far. When the turn ends, the total is on the record.

**Why this priority**: The runtimes send this unprompted, several times a turn, and the app drops
every one. A full context window is the most common reason an agent starts behaving oddly, and
there is no other way to see it coming.

**Independent Test**: Run one turn and confirm the context meter moves and a cost is recorded
against the turn.

**Acceptance Scenarios**:

1. **Given** an agent is working, **When** usage arrives, **Then** the window shows how full the
   context is as a proportion, and it updates while the turn runs.
2. **Given** a runtime that reports cost, **When** a turn ends, **Then** the cost of that turn and
   the running total for the agent are shown in the agent's own currency.
3. **Given** a runtime that reports no cost, **When** a turn ends, **Then** nothing about cost is
   shown and nothing is invented.
4. **Given** the context passes a point where the agent is close to full, **When** the user looks at
   the agent, **Then** it says so.

---

### User Story 5 - Sign in, sign out, and choose who answers (Priority: P5)

A runtime is installed but not signed in. The user signs in from the app. Later they sign out, or
point the runtime at a different provider, without a terminal.

**Why this priority**: "Installed but not usable" is a state the app already detects and cannot fix.
The protocol has a method for it and one of our runtimes hands over the exact command to run.

**Independent Test**: With a signed-out runtime, sign in from the app, start an agent, then sign out
again.

**Acceptance Scenarios**:

1. **Given** a runtime that offers a way to sign in, **When** the user chooses it, **Then** the app
   carries it out and the runtime becomes ready without the app restarting.
2. **Given** a runtime whose only way in is a command in a terminal, **When** the user chooses it,
   **Then** the app shows that exact command and opens a terminal at it.
3. **Given** a signed-in runtime that can sign out, **When** the user signs out, **Then** the app
   says which agents that stops and asks before doing it.
4. **Given** a runtime that offers a choice of providers, **When** the user picks one, **Then** new
   agents use it and the choice survives the app restarting.
5. **Given** a turn fails because the runtime is no longer authenticated, **When** the failure
   arrives, **Then** the agent shows "needs signing in" and the way to fix it, not a generic error.

---

### User Story 6 - Follow the plan (Priority: P6)

An agent writes itself a plan. The user sees the steps, which one it is on and which are done, and
watches them tick over. When the agent compacts its history to make room, the user sees that happen.

**Why this priority**: The transcript says "Made a plan" and drops the plan. A plan is the clearest
statement an agent makes of what it is about to do, which is the moment to stop it if it is wrong.

**Independent Test**: Run a turn that produces a plan, confirm each step and its state is shown, and
confirm the display follows later changes to the plan.

**Acceptance Scenarios**:

1. **Given** an agent sends a plan, **When** the transcript draws it, **Then** each step is shown
   with whether it is waiting, running or done.
2. **Given** an agent changes a plan it already sent, **When** the change arrives, **Then** the plan
   already on screen changes rather than a second plan appearing.
3. **Given** an agent withdraws a plan, **When** that arrives, **Then** the plan is marked as
   dropped rather than left looking current.
4. **Given** an agent compacts its history, **When** it starts and finishes, **Then** the transcript
   says so and shows the summary it kept.

---

### User Story 7 - Pick up sessions the app did not start (Priority: P7)

The user started an agent from a terminal yesterday, in a folder this app knows. The app offers it,
and picking it up puts the conversation in the list as an ordinary agent. Agents finished long ago
can be cleared from the runtime as well as from the app. A conversation can be branched at its
current point without losing the original.

**Why this priority**: The app keeps its own record, so this is not needed to work. It matters
because an agent is a thing the user owns, not a thing this app owns, and because our archive
currently leaves the runtime's copy behind forever.

**Independent Test**: Start a session outside the app in a known folder, adopt it from the app, and
continue the conversation.

**Acceptance Scenarios**:

1. **Given** a runtime that can list its sessions, **When** the user asks what else is in this
   folder, **Then** sessions the app did not start are offered with their title and when they were
   last touched.
2. **Given** one of those, **When** the user adopts it, **Then** it becomes an agent in the list and
   the history is there to read.
3. **Given** an archived agent whose runtime can delete sessions, **When** the user deletes it,
   **Then** the app asks first, says that it is permanent, and removes both copies.
4. **Given** an agent in mid-conversation whose runtime can fork, **When** the user branches it,
   **Then** a second agent appears carrying the history so far and the first is untouched.
5. **Given** a runtime that cannot do one of these, **When** the user looks for it, **Then** it is
   not offered, rather than offered and failing.

---

### User Story 8 - Let the agent reach further (Priority: P8)

The agent asks the app to read or write a file, or to run a command and watch its output. The app
does it, under the same permission rules as any other tool. The user can also give an agent extra
folders to work in, and attach MCP servers to it.

**Why this priority**: 001 declined these on purpose: every runtime has its own file and command
tools, so declining cost nothing and avoided owning someone else's writes. That decision was
reversed on 2026-09-18, because a client that serves these requests can show the user every file an
agent touches at the moment it touches it, and because extra folders and MCP servers are asked for
whenever work spans two repos. Serving them is now a requirement of this feature, not an option
inside it.

**Independent Test**: Run a turn that makes the agent ask the app for a file read, a file write and
a command, and confirm each one is carried out, shown, and refusable.

**Acceptance Scenarios**:

1. **Given** the app serves file requests, **When** an agent asks to read a file, **Then** the app
   reads it and the transcript shows which file was read.
2. **Given** an agent asks to write a file, **When** the request arrives, **Then** it goes through
   the same permission question as any other change, and refusing it leaves the file alone.
3. **Given** an agent asks to run a command, **When** it runs, **Then** its output appears while it
   runs and the user can stop it.
4. **Given** the user adds a second folder to an agent whose runtime supports it, **When** the agent
   works, **Then** it can reach both folders and the app shows both.
5. **Given** the user attaches an MCP server to an agent, **When** the agent starts, **Then** the
   server's tools are available to it, and a server that fails to start is reported without
   stopping the agent.

---

### User Story 9 - Answer the agent's question in a form (Priority: P9)

The agent needs something structured: a choice from a list, a value, a confirmation, or for the user
to visit a page and come back. The app shows it as a form, and the answer goes back.

**Why this priority**: No runtime we support asks for this yet. It is in scope because "complete"
means an agent that starts using it tomorrow gets an answer instead of a refusal.

**Independent Test**: Drive the client with an agent that asks each kind of question the protocol
allows and confirm each one is answerable.

**Acceptance Scenarios**:

1. **Given** an agent asks for a value with a described shape, **When** the request arrives, **Then**
   the app shows a form matching that shape and will not send an answer that does not fit it.
2. **Given** an agent asks the user to visit a page, **When** the request arrives, **Then** the app
   shows the link and reports back when the user has finished or given up.
3. **Given** a form the user cancels, **When** they cancel, **Then** the agent is told it was
   declined and carries on.
4. **Given** a form arrives while no window is open, **When** the user opens the window, **Then** the
   form is waiting, the way a permission question already is.

---

### Edge Cases

- A runtime advertises a capability and then fails the method that goes with it. The app reports the
  failure against that action and leaves the agent alive.
- An attachment names a file that has since been deleted or moved.
- An agent asks to write a file outside every folder the agent was given.
- A command the agent started is still running when the user stops the agent, or when the daemon
  stops.
- Usage arrives with a context size of zero, or a cost in a currency the Mac has no symbol for.
- A plan step's text changes while the user is reading it.
- Two agents in the same folder are adopted from the runtime's list at the same time.
- A session the user adopts is already in the app under a different name.
- The runtime's session list is longer than one page.
- An elicitation form asks for something the app cannot represent.
- A picture arrives in a reply that is larger than the window.

## Requirements *(mandatory)*

### Functional Requirements

**Handshake and capabilities**

- **FR-001**: The client MUST advertise every capability it actually serves, and MUST NOT advertise
  one it does not.
- **FR-002**: The client MUST check the protocol version an agent answers with, and MUST report a
  version it cannot speak rather than continuing.
- **FR-003**: The client MUST record what each runtime advertised, so that every control the app
  offers is decided by that record rather than by which runtime it is.
- **FR-004**: The client MUST hide any action whose capability the runtime did not advertise.

**Options**

- **FR-005**: The app MUST render a choice offered as a flat list, and MUST render one offered as
  groups with its headings intact.
- **FR-006**: The app MUST render a setting that is on or off as a switch, and MUST tell the runtime
  the value in the form the protocol defines for it.
- **FR-007**: A setting of a kind the app does not know MUST be left out without affecting any other
  setting or the start itself.
- **FR-008**: No shape a runtime sends inside its options MUST be able to stop an agent starting.

**Prompt content**

- **FR-009**: Users MUST be able to attach an image to a prompt where the runtime accepts images,
  by dragging it, pasting it, or choosing it.
- **FR-010**: Users MUST be able to reference a file in a prompt, chosen by name from the agent's
  folders.
- **FR-011**: Users MUST be able to attach the contents of a file to a prompt where the runtime
  accepts embedded content.
- **FR-012**: The app MUST refuse an attachment the runtime cannot take, before sending, saying why.
- **FR-013**: The transcript MUST show every attachment as part of what the user said.
- **FR-014**: The transcript MUST show content an agent sends that is not text, including pictures,
  rather than showing an empty line.

**Tool calls**

- **FR-015**: A tool call carrying a change to a file MUST be shown as the old text against the new
  text, with the path.
- **FR-016**: A tool call carrying command output MUST show that output, updating while the command
  runs.
- **FR-017**: A tool call naming files and lines MUST offer each one, and choosing one MUST open it
  at that line in the user's chosen editor.
- **FR-018**: A tool call's stated inputs MUST remain readable after later updates to that call
  arrive.
- **FR-019**: Tool call content the app does not recognise MUST be shown in raw form rather than
  dropped.

**Usage and cost**

- **FR-020**: The app MUST show how full an agent's context window is, updating while a turn runs.
- **FR-021**: The app MUST record the usage reported at the end of each turn against that turn.
- **FR-022**: The app MUST show the cost of a turn and the running total for an agent where the
  runtime reports cost, in the currency the runtime named.
- **FR-023**: The app MUST show nothing about cost for a runtime that reports none.
- **FR-024**: The app MUST warn when an agent's context is close to full.

**Plans**

- **FR-025**: The app MUST show each step of a plan with its state.
- **FR-026**: The app MUST apply changes to a plan already shown, rather than showing a second plan.
- **FR-027**: The app MUST mark a withdrawn plan as withdrawn.
- **FR-028**: The app MUST show that an agent is compacting its history, and the summary it kept.

**Authentication and providers**

- **FR-029**: Users MUST be able to carry out any sign-in method a runtime offers, from the app.
- **FR-030**: Where a sign-in method needs a terminal, the app MUST show the exact command the
  runtime named and offer to open a terminal at it.
- **FR-031**: Users MUST be able to sign out of a runtime that supports it, after being told which
  agents that affects.
- **FR-032**: Users MUST be able to see and change which provider a runtime uses, where the runtime
  offers that choice, and the choice MUST survive a restart.
- **FR-033**: A failure caused by not being authenticated MUST be shown as needing sign-in, with the
  way to fix it, distinct from every other kind of failure.

**Sessions**

- **FR-034**: Users MUST be able to see the sessions a runtime holds for a folder, including ones
  this app did not start, with each one's title and when it was last touched.
- **FR-035**: Users MUST be able to adopt one of those as an agent and continue it.
- **FR-036**: The app MUST not offer to adopt a session it already holds.
- **FR-037**: Users MUST be able to delete a session from the runtime, after being asked, and told
  that it is permanent.
- **FR-038**: Archiving an agent MUST NOT delete the runtime's copy.
- **FR-039**: Users MUST be able to branch an agent where the runtime supports it, leaving the
  original untouched.
- **FR-040**: Users MUST be able to give an agent more than one folder where the runtime supports
  it, and the app MUST show every folder an agent may reach.

**Serving the agent**

- **FR-041**: The app MUST serve an agent's request to read a file, and MUST record which file.
- **FR-042**: The app MUST serve an agent's request to write a file only after the same permission
  question any other change goes through.
- **FR-043**: The app MUST refuse a file request that reaches outside every folder the agent was
  given, and say so.
- **FR-044**: The app MUST serve an agent's request to run a command, show its output while it runs,
  and let the user stop it.
- **FR-045**: A command the app started for an agent MUST be stopped when that agent is stopped, and
  MUST NOT outlive the daemon.
- **FR-046**: Users MUST be able to attach MCP servers to an agent, and a server that fails MUST be
  reported without stopping the agent.

**Elicitation**

- **FR-047**: The app MUST show a structured request from an agent as a form matching the shape the
  agent described, and MUST NOT send an answer that does not fit that shape.
- **FR-048**: The app MUST support a request that asks the user to visit a page and report back.
- **FR-049**: A form the user cancels MUST be reported to the agent as declined.
- **FR-050**: A form that arrives while no window is open MUST be waiting when a window opens.

**Everything else**

- **FR-051**: An update, request or field the app does not recognise MUST be noted against the agent
  and MUST NOT stop it working.
- **FR-052**: Every method the app calls MUST be one the runtime advertised, or one the protocol
  requires of every agent.

### Key Entities

- **Attachment**: something sent with a prompt. A picture, a reference to a file, or the contents of
  one. Belongs to the message it was sent with.
- **Tool call content**: what a tool call produced. A change to a file (path, before, after),
  command output, or a block of content. Belongs to a tool call and arrives in pieces.
- **Usage**: how full a context window is and what has been spent, at a point in a turn. Belongs to
  an agent; the last one in a turn is the turn's total.
- **Plan**: an ordered list of steps, each with its own state, belonging to an agent. Replaced or
  withdrawn as a whole by later updates.
- **Runtime account**: whether a runtime is signed in, how it can be signed into, and which provider
  it is pointed at. Belongs to a runtime, not to an agent.
- **Runtime session**: a conversation the runtime holds, which may or may not be an agent in this
  app. Has a title the runtime wrote, a folder, and when it was last touched.
- **Served request**: something an agent asked the app to do (read, write, run). Has the agent that
  asked, what was asked, and how it was answered.
- **Elicitation**: a structured question from an agent, its shape, and the answer given.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every method and message the protocol defines is either handled or listed in this
  spec's Out of Scope section with the reason. No third category.
- **SC-002**: For each of the three runtimes, every capability it advertises has a matching action
  in the app, verified by a handshake recorded on the day of the check.
- **SC-003**: A user can attach a screenshot and send it in under 10 seconds from the screenshot
  existing.
- **SC-004**: A user watching an agent edit a file can see what changed without opening another
  application.
- **SC-005**: A user can tell how full an agent's context is at a glance, at any point in a turn.
- **SC-006**: A user with a signed-out runtime can reach a working agent without leaving the app,
  except where the runtime itself demands a terminal.
- **SC-007**: No shape, value or update a runtime sends causes the app to lose an agent, drop a
  transcript or fail a start. Proved by driving the client with every shape the protocol allows.
- **SC-008**: A user can find and continue a conversation started outside this app in under 30
  seconds.
- **SC-009**: Nothing an agent asks the app to do happens to a file outside the folders that agent
  was given.

## Out of Scope

- **Next edit suggestions** (`nes/*`) and **document synchronisation** (`document/did*`). These
  describe an editor watching a file as it is typed. This app is not an editor and no runtime we
  support advertises them.
- **Serving MCP over the client connection** (`mcp/connect`, `mcp/message`, `mcp/disconnect`). This
  is for a client that hosts MCP servers itself. We attach servers to the agent instead, which is
  what all three runtimes expect. Revisit if a runtime asks for it.
- **Vendor extensions** carried in `_meta`: hooks, steering, goals, subagent reporting. Each one is
  a single runtime's idea. Reading them is how one code path becomes three.
- **Cancelling a request by id** (`$/cancel_request`). We cancel turns, which is what the user asks
  for. No runtime requires the finer form.

## Assumptions

- Archiving stays local. Deleting the runtime's copy is a separate, explicit action with a
  confirmation, because it cannot be undone and the conversation may be the only record of a piece
  of work.
- Serving file and terminal requests goes through the permission question the app already has,
  rather than a second set of rules. An agent asking the app to write a file is the same event as an
  agent writing it.
- File writes are confined to the folders the agent was given. There is no setting to widen this in
  this feature.
- Where a runtime offers both an old dedicated field and the newer options list for the same
  setting, the options list wins, as in 001.
- Cost is shown as the runtime reported it, in the runtime's currency. The app does no conversion
  and no estimation.
- The user's editor for opening a file at a line is the one macOS opens that file with.
- Attachments are sent by value or by reference exactly as the runtime's advertised capabilities
  allow, with no conversion between the two.

## Dependencies

- Feature 001, which owns the session, the daemon, the transcript and the permission question that
  this feature extends. Its decision to advertise no client file or terminal capabilities is
  superseded by User Story 8 and FR-041 to FR-045.
- The three runtimes on this Mac. Every capability claim in this spec is to be proved by handshake
  against them, not by reading their documentation.
