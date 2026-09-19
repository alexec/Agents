# Feature Specification: Agent daemon and basic UI

**Feature Branch**: `001-agent-daemon-ui`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "The basic UI and core daemon. We use ACP as the protocol to interact with agents runtimes, which is a fancy name for "CLI". E.g. "claude", "grok", "copilot" etc. The daemon is responsible for managing the agents, so if the UI crashes, the agents continue their work. It also manages agent lifecycle, running, stopped, archived. Agents can auto-archive when their work has landed. The UI provides a basic way to start agent (with whatever config options the agents runtime supports), send follow up messages."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start an agent and watch it work (Priority: P1)

The user opens the app, chooses a folder to work in, chooses which agent runtime to use, gives it
a first instruction, and starts it. The agent's work appears in the window as it happens: what it
said, what it is doing, what it wants to run. The user does not open a terminal at any point.

**Why this priority**: Without this there is no product. Everything else in the feature is about
keeping this alive or doing it a second time.

**Independent Test**: Start an agent in a scratch folder with an instruction that makes a visible
change to a file, and watch the work appear in the window and the change appear on disk. Delivers
the whole of the app's value on its own.

**Acceptance Scenarios**:

1. **Given** at least one supported agent runtime is installed, **When** the user opens the app for
   the first time, **Then** the window lists the runtimes it found and offers to start an agent with
   one of them.
2. **Given** the user has chosen a folder, a runtime and typed an instruction, **When** they start
   the agent, **Then** the agent appears in the list as running within 2 seconds and its output
   begins appearing without the user refreshing anything.
3. **Given** an agent is running, **When** it produces output, **Then** the new output appears in
   the window within 1 second of the runtime emitting it.
4. **Given** no supported runtime is installed, **When** the user opens the app, **Then** the window
   says which runtimes it looked for and where, and does not offer a start button that cannot work.

---

### User Story 2 - The work survives the window (Priority: P1)

The user quits the app, or the app crashes, while agents are mid-task. The agents keep working. When
the user opens the app again, every agent is still there, in the state it reached, with everything
it said while the window was shut.

**Why this priority**: This is the reason the daemon exists. An agent that dies with the window is a
terminal session with extra steps, and long tasks become unrunnable.

**Independent Test**: Start an agent on a task that takes several minutes, force quit the app, check
the agent process is still alive and still writing to the folder, reopen the app, and see the agent
still listed as running with the output produced while the app was gone.

**Acceptance Scenarios**:

1. **Given** an agent is running, **When** the user quits the app normally, **Then** the agent keeps
   running and its output keeps being recorded.
2. **Given** an agent is running, **When** the app is force quit or crashes, **Then** the agent keeps
   running and its output keeps being recorded.
3. **Given** agents were running while the app was shut, **When** the user opens the app again,
   **Then** every agent is listed in its current state and its full history is readable, including
   what happened while the app was shut.
4. **Given** the app is opened when nothing has ever run, **When** the window appears, **Then** it
   shows an empty list that says how to start the first agent, and not an error.

---

### User Story 3 - Follow up, and stop (Priority: P2)

The user reads what an agent is doing, types a follow-up message to it, and sees the agent take the
message into account. If the agent is going the wrong way, the user stops it.

**Why this priority**: An agent you cannot talk to is a batch job. Follow-up is what makes the window
worth keeping open, but story 1 has value without it.

**Independent Test**: Start an agent, send it a follow-up that changes what it is doing, and see the
change in its next output. Stop it and see it stop.

**Acceptance Scenarios**:

1. **Given** an agent is running, **When** the user sends a follow-up message, **Then** the message
   appears in the agent's history and the agent's subsequent work reflects it.
2. **Given** an agent is waiting for input, **When** the user sends a message, **Then** the agent
   resumes work.
3. **Given** an agent is running, **When** the user stops it, **Then** the agent stops within 5
   seconds, is listed as stopped, and its history stays readable.
4. **Given** an agent is stopped, **When** the user sends it a message, **Then** the app makes clear
   that the agent is stopped rather than silently discarding the message.

---

### User Story 4 - Getting finished work out of the way (Priority: P3)

Agents accumulate. The ones that have finished and whose work has landed get out of the way on their
own, and the user can put any agent away by hand and get it back.

**Why this priority**: It matters at ten agents, not at one. The app is usable without it.

**Independent Test**: Run an agent to completion under the conditions that count as landed, and see
it leave the active list on its own and be findable in the archive with its history intact.

**Acceptance Scenarios**:

1. **Given** a stopped agent whose work has landed, **When** the condition for landed is met,
   **Then** the agent moves to archived without the user doing anything, and the user can see that
   it was archived and why.
2. **Given** an agent in any state, **When** the user archives it by hand, **Then** it leaves the
   active list and its history stays readable in the archive.
3. **Given** a running agent, **When** the user archives it, **Then** the app stops it first rather
   than leaving an unlisted process running.
4. **Given** an archived agent, **When** the user looks for it, **Then** it is findable with its
   full history and the state it ended in.

---

### Edge Cases

- The chosen runtime is installed but fails to start, or exits immediately. The agent is listed as
  stopped with the reason and whatever the runtime printed, not silently absent.
- The runtime crashes mid-task. The agent becomes stopped, the history up to the crash is kept, and
  the user is told.
- The daemon is not running when the app opens. The app starts it and says nothing if that works.
- The daemon stops while agents are running, including on a Mac restart. Covered by a clarification
  below.
- Two windows, or two launches of the app, look at the same agent. Both show the same state, and
  neither starts a second daemon.
- The agent's folder is deleted, renamed or moved while the agent is running.
- The user starts two agents in the same folder at the same time. Allowed, and both are listed with
  their folder shown, because nothing here can tell whether that is a mistake.
- An agent produces a very large amount of output. The window stays responsive and the history stays
  complete.
- The agent asks for a permission or a decision the app has no way to answer in this feature. The
  agent is shown as waiting on the user, and the user can answer with a follow-up message or stop it.
- The user's instruction is empty. The start button does nothing until there is something to send.

## Requirements *(mandatory)*

### Functional Requirements

**Running agents**

- **FR-001**: The system MUST run agents as processes it owns, outside the app's window process, so
  that closing, quitting or crashing the window does not stop any agent.
- **FR-002**: The system MUST speak to every agent runtime over one protocol (ACP), so that adding a
  runtime does not mean writing a second way to talk to agents.
- **FR-003**: The system MUST discover which supported agent runtimes are available on this Mac and
  offer only those, naming the ones it looked for and did not find.
- **FR-004**: Users MUST be able to start an agent by choosing a folder, a runtime, and a first
  instruction.
- **FR-005**: The system MUST let the user set the options a chosen runtime supports when starting an
  agent [NEEDS CLARIFICATION: is this a typed form per runtime, or one free-text field of arguments
  passed through to the runtime?].
- **FR-006**: The system MUST record every agent's full history, and MUST keep recording while no
  window is open.
- **FR-007**: The system MUST show an agent's history and new output in the window, with new output
  appearing without the user asking for it.
- **FR-008**: Users MUST be able to send a follow-up message to a running or waiting agent.
- **FR-009**: Users MUST be able to stop a running agent.

**Lifecycle**

- **FR-010**: The system MUST give every agent exactly one of these states at a time: running,
  stopped, archived.
- **FR-011**: The system MUST move an agent to stopped when its runtime exits, whether it finished,
  failed or crashed, and MUST record which of those it was.
- **FR-012**: The system MUST archive a stopped agent automatically when its work has landed
  [NEEDS CLARIFICATION: what counts as landed? The agent's own report that it is done, a commit on
  the branch, the branch merged into the default branch, or something else?].
- **FR-013**: Users MUST be able to archive any agent by hand, and the system MUST stop a running
  agent before archiving it.
- **FR-014**: The system MUST keep an archived agent's full history readable.
- **FR-015**: The system MUST show why an agent was archived, distinguishing archived by the user
  from archived because the work landed.

**The daemon**

- **FR-016**: The system MUST have exactly one daemon running at a time, however many windows or
  launches of the app there are.
- **FR-017**: The system MUST start the daemon if it is not running when the app opens, without the
  user being asked to do anything.
- **FR-018**: The daemon MUST survive the app's death, and the app MUST reconnect to the running
  daemon and show current state when it opens again.
- **FR-019**: The system MUST define what happens to running agents when the daemon itself stops
  [NEEDS CLARIFICATION: on daemon exit or Mac restart, do running agents get killed and marked
  stopped, or does the daemon start at login and resume ownership of agents that survived?].
- **FR-020**: The system MUST keep agent state and history where it survives both the app and the
  daemon being restarted.
- **FR-021**: The daemon MUST NOT require the user to install, configure or maintain anything by
  hand.

### Key Entities

- **Agent**: One run of one runtime, in one folder, with one conversation. Has a state (running,
  stopped, archived), the folder it works in, which runtime it is, the options it was started with,
  when it started, how it ended, and why it was archived.
- **Agent runtime**: A CLI that speaks ACP, such as claude, grok or copilot. Has a name, where it was
  found on this Mac, and the options it accepts.
- **Message**: One entry in an agent's history. Either something the user sent or something the agent
  produced, with when it happened, kept in order.
- **Daemon**: The single owner of all agents. Not something the user sees, except that agents keep
  running when the window is gone.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user with a supported runtime installed can go from opening the app for the first
  time to an agent working in a folder of their choosing in under 60 seconds, without opening a
  terminal or reading documentation.
- **SC-002**: 100% of agents running when the app is force quit are still running 60 seconds later,
  and all output produced while the app was shut is present when it reopens.
- **SC-003**: New agent output appears in the window within 1 second of the runtime producing it, for
  agents producing output continuously for 30 minutes.
- **SC-004**: A follow-up message reaches a running agent within 2 seconds of being sent.
- **SC-005**: A stopped agent is never lost: after the app and the Mac have both been restarted, every
  agent ever started is still listed, in the right state, with its full history.
- **SC-006**: Ten agents running at once leave the window responsive: the list and any agent's history
  scroll without stutter.
- **SC-007**: The user never sees two daemons, an agent listed twice, or an agent listed as running
  that is not.

## Assumptions

- One person, one Mac, no accounts and nothing to log into. There is no sharing, no remote access and
  no multi-user behaviour in this feature.
- The agent runtimes are installed and authenticated by the user outside this app. The app finds them
  and runs them; it does not install them or handle their credentials.
- The user chooses the folder an agent works in when starting it. Projects, backlogs and any notion
  of what a folder is beyond a path are out of scope for this feature.
- An agent runs one conversation. Branching, forking or resuming an archived agent as a new one is
  out of scope.
- Agents run with whatever permissions the runtime is configured with. This feature does not add a
  permission or approval system of its own; an agent that stops to ask is shown as waiting and is
  answered with a follow-up message.
- The window shows the agent's conversation and its state. Cost, resource limits, capacity, browsing
  the folder and diffing the repository are all later features.
- Archiving is a lifecycle state, not deletion. Nothing in this feature deletes an agent or its
  history.
- The app and the daemon are both this project's code, built and shipped together. The daemon is not
  a separate thing the user installs.
