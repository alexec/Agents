# Feature Specification: Agent daemon and basic UI

**Feature Branch**: `001-agent-daemon-ui`

**Created**: 2026-09-18

**Status**: Draft

**Research**: [research.md](./research.md) — what claude, grok and copilot actually do, verified by
handshake on 2026-09-18

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

Agents accumulate. The ones that said they were done and exited cleanly get out of the way on their
own, and the user can put any agent away by hand and get it back.

**Why this priority**: It matters at ten agents, not at one. The app is usable without it.

**Independent Test**: Run an agent on a task it can finish, and see it leave the active list on its
own when it reports itself done and exits, and be findable in the archive with its history intact.

**Acceptance Scenarios**:

1. **Given** an agent that reported its work finished, **When** its runtime exits cleanly, **Then**
   the agent moves to archived without the user doing anything, and the user can see that it was
   archived because it finished rather than by hand.
2. **Given** an agent that crashed or was stopped by the user, **When** it ends, **Then** it stays in
   stopped and is not archived.
3. **Given** an agent in any state, **When** the user archives it by hand, **Then** it leaves the
   active list and its history stays readable in the archive.
4. **Given** a running agent, **When** the user archives it, **Then** the app stops it first rather
   than leaving an unlisted process running.
5. **Given** an archived agent, **When** the user looks for it, **Then** it is findable with its
   full history and the state it ended in.

---

### Edge Cases

- The chosen runtime is installed but fails to start, or exits immediately. The agent is listed as
  stopped with the reason and whatever the runtime printed, not silently absent.
- The runtime crashes mid-task. The agent becomes stopped, the history up to the crash is kept, and
  the user is told.
- The daemon is not running when the app opens. The app starts it and says nothing if that works.
- The daemon stops while agents are running, including on a Mac restart. Those agents die with it,
  and are listed as stopped with that as the reason the next time the app opens.
- The app is open with no agents running. There is nothing for a daemon to own, and the user still
  sees every stopped and archived agent with its history.
- A turn ends because a limit was hit, or the agent refused. That is not finished, and the agent is
  shown as having stopped short with the reason.
- The agent asks permission while no window is open. It waits, the daemon stays alive, and the
  question is the first thing the user sees when a window opens.
- A runtime is installed but not signed in. The app says so before the user tries to start an agent,
  and says what to run.
- A runtime needs something else installed before it can speak the protocol at all. It is listed as
  unavailable with what is missing, not silently absent.
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
  offer only those, naming the ones it looked for and did not find. A runtime is whatever has to be
  run to get an agent speaking the protocol, which for some is the tool itself and for others is a
  separate adapter, so discovery MUST NOT assume every runtime is one installed command.
- **FR-003a**: The system MUST tell the user when a runtime is installed but not signed in, and MUST
  say what to run to fix it when the runtime says so itself.
- **FR-004**: Users MUST be able to start an agent by choosing a folder, a runtime, and a first
  instruction.
- **FR-005**: The system MUST build the options shown when starting an agent from the single list of
  configurable options the session advertises, using the type and grouping the runtime gives for
  each one. It MUST NOT keep its own list of models, modes or efforts for any runtime, so a runtime
  that adds one needs no change here.
- **FR-005a**: The system MUST NOT rely on the older separate model and mode fields, which the three
  runtimes send inconsistently. Whatever a runtime offers is taken from the one list.
- **FR-005b**: The system MUST apply an option change during a session when the user makes one, and
  MUST follow the advertised options changing mid-session.
- **FR-005c**: The system MUST also offer a free-text field for anything the protocol does not
  advertise, passed to the runtime as given when it is started.
- **FR-005d**: The system MUST NOT prevent an agent being started with a runtime that advertises no
  options at all.
- **FR-006**: The system MUST record every agent's full history, and MUST keep recording while no
  window is open.
- **FR-007**: The system MUST show an agent's history and new output in the window, with new output
  appearing without the user asking for it.
- **FR-008**: Users MUST be able to send a follow-up message to a running or waiting agent.
- **FR-009**: Users MUST be able to stop a running agent.
- **FR-009a**: The system MUST show the user any permission the agent asks for, with the choices the
  agent offered, and MUST send back the one the user picks. A permission request is a question the
  agent waits on, and a typed message is not an answer to it.
- **FR-009b**: The system MUST hold a permission request that arrives while no window is open,
  keeping the agent alive and waiting, and MUST present it when a window opens. It MUST NOT answer
  on the user's behalf.

**Lifecycle**

- **FR-010**: The system MUST give every agent exactly one of these states at a time: running,
  waiting on the user, finished, stopped, archived. Running means a turn is in flight. Finished means
  the agent ended a turn having said all it had to say and is idle, with its process alive and able
  to take a follow-up.
- **FR-011**: The system MUST record how each turn ended, and MUST distinguish an agent that finished
  what it was asked from one that hit a limit, refused, or was cancelled.
- **FR-011a**: The system MUST move an agent to stopped when the user stops it or its process dies,
  and MUST record which of those happened. A process dying on its own is a crash, not a finish,
  because these runtimes do not exit when their work is done.
- **FR-011b**: The system MUST end an agent by asking it to stop and closing its session before
  killing anything, so that a runtime that persists its own session is left in a state it can be
  asked about later.
- **FR-012**: The system MUST archive a finished agent automatically [NEEDS CLARIFICATION: these
  runtimes never exit when the work is done, so "finished and exited cleanly" cannot be detected.
  When does a finished agent archive itself? See the question in research.md.]
- **FR-012a**: The system MUST NOT archive an agent that hit a limit, refused, crashed, or was
  stopped by the user.
- **FR-013**: Users MUST be able to archive any agent by hand, and the system MUST stop a running
  agent before archiving it.
- **FR-014**: The system MUST keep an archived agent's full history readable.
- **FR-015**: The system MUST show why an agent was archived, distinguishing archived by the user
  from archived because the agent finished.

**The daemon**

- **FR-016**: The system MUST have exactly one daemon running at a time, however many windows or
  launches of the app there are.
- **FR-017**: The system MUST start the daemon if it is not running when the app opens, without the
  user being asked to do anything.
- **FR-018**: The daemon MUST survive the app's death, and the app MUST reconnect to the running
  daemon and show current state when it opens again.
- **FR-019**: The daemon MUST exit on its own once it is holding no agents and no app is connected to
  it, and MUST NOT install a login item, a background service or anything else that runs when the
  user is not using the app.
- **FR-019a**: The daemon MUST count an agent that is running, waiting on a permission answer, or
  finished with its process still alive as an agent it is holding, and MUST NOT exit while it holds
  one.
- **FR-019b**: The system MUST mark as stopped every agent whose process is gone, including all
  agents that were alive when the user logged out or the Mac restarted, and MUST record that they
  ended that way rather than by finishing.
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
- **SC-005**: No agent is ever lost: after the app and the Mac have both been restarted, every agent
  ever started is still listed with its full history, and the ones that were running when the Mac
  restarted are listed as stopped with that as the reason.
- **SC-008**: Starting an agent offers every option its runtime advertises, with no change to this
  app when a runtime adds a model, a mode or an effort level.
- **SC-009**: All three of claude, grok and copilot can be started, driven, followed up and stopped
  through one code path, with no runtime-specific handling of options.
- **SC-010**: A permission request asked while the app is shut is still answerable when the app
  opens, with the agent still alive and still waiting.
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
- The app answers permission requests, because the protocol requires the client to: the agent asks a
  question with a set of answers and waits for one. This feature shows the question and sends back
  the user's choice. It adds no rules or remembered allowances of its own, and the way to be asked
  less often is the runtime's own options, which the start form already offers.
- The window shows the agent's conversation and its state. Cost, resource limits, capacity, browsing
  the folder and diffing the repository are all later features.
- Archiving is a lifecycle state, not deletion. Nothing in this feature deletes an agent or its
  history.
- Finished means the agent ended its turn having said all it had to say. This feature does not look
  at git, so a finished agent may have committed nothing. A rule that reads the repository is a later
  feature, better written after watching real agents finish.
- These runtimes are long-lived servers, not commands that run and exit, so a finished agent still
  has a process. Whether that process is kept for a follow-up or closed is part of the open question
  on FR-012.
- The daemon is only alive while there is work or a window. Nothing runs at login, so an agent cannot
  outlive a logout or a restart, and the record says so when that happens.
- The app and the daemon are both this project's code, built and shipped together. The daemon is not
  a separate thing the user installs.
