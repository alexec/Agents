# Feature Specification: An Agent Can Run a Few Agents of Its Own

**Feature Branch**: `028-agents-manage-agents`

**Created**: 2026-09-24

**Status**: Implemented (uncommitted)

**Input**: User description: "agent management tools that allow an agent to start, stop, and archive other agents. Only those it creates itself. Only those within the project. Maximum 3 agents."

## Why this feature exists

An agent working on something large often has pieces that could be done alongside each other:
one part of the codebase to investigate while another is changed, a long check to run while it
carries on. Today the only way to get a second agent is for the person to start one by hand and
pass the work between them.

It does not currently have a safe way to do this for itself. The tools the app gives an agent end
its turn, show a file and manage the project's workflows; none of them touches another agent. The
only route that does is the daemon's own socket, which an agent with a shell can reach and which
lets it start, prompt, stop or archive **any** agent in **any** project, the person's own
conversations and itself included, with no limit and nobody told.

This feature gives an agent a small, bounded version of that on purpose: it may start agents in its
own project, stop them and archive them. It may not touch any agent it did not start, and the
project can never have more than three agent-started agents at once. Everything it does shows up
where the person already looks, and the person keeps every power over those agents they have over
any other.

**This feature does not close the socket route.** That is separate work (see Assumptions); until
it is done, these limits bind an agent that uses the tools, not one that goes around them.

## Clarifications

### Session 2026-09-24

- Q: What does "maximum 3 agents" count? → A: At most three agent-started agents exist in a project at once, across every agent there, counting any that are not archived. Archiving one frees its place.
- Q: Can an agent that another agent started start agents of its own? → A: No. One level only: an agent started by another agent is not given the tools.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An agent starts helpers and they appear to the person (Priority: P1)

The person asks an agent to do something with separable parts. The agent starts a second agent in
the same project with a prompt of its own. The new agent appears in the project's agent list like
any other, marked as started by the first, and gets to work. The person can open it, read it,
prompt it, stop it or archive it exactly as they could any agent.

**Why this priority**: Starting is the capability. Stop and archive are only worth having once
there is something to stop and archive, and the person seeing what was started is the condition
for allowing it at all.

**Independent Test**: Ask an agent to start another agent with a short prompt. Confirm a new agent
appears in the same project, says which agent started it, runs the prompt, and responds to the
person's own prompt, stop and archive as normal.

**Acceptance Scenarios**:

1. **Given** an agent the person started, in a project with fewer than three agent-started agents, **When** it asks to start an agent with a prompt, **Then** a new agent starts in the same project folder with that prompt, and the caller is told it started and how to refer to it.
2. **Given** the new agent, **When** the person looks at the project's agent list, **Then** it is there, shown with the name of the agent that started it.
3. **Given** the new agent, **When** the person prompts, stops or archives it, **Then** it behaves exactly as an agent they started themselves would.
4. **Given** the request names a runtime, model or permission mode, **When** the agent starts, **Then** it uses them; **Given** it names none, **Then** it starts on the project's default runtime with that runtime's defaults, as a workflow's agent does.
5. **Given** the request names a runtime, model or permission mode the app does not offer, **When** it is made, **Then** nothing is started and the caller is told which were not recognised and what was available.

---

### User Story 2 - The limits hold (Priority: P1)

Whatever an agent asks for, it cannot reach past its own project, touch an agent it did not start,
or push the project past three agent-started agents.

**Why this priority**: This is the condition the feature was asked for under. Without it Story 1
is the socket gap with a nicer front door.

**Independent Test**: With three agent-started agents in a project that are not archived, ask any
agent there to start another and confirm it is refused, saying why. Archive one and confirm the
next request succeeds. Ask an agent to stop or archive an agent the person started, an agent
started by a different agent, and itself, and confirm each is refused and nothing changes.

**Acceptance Scenarios**:

1. **Given** a project with three agent-started agents that are not archived, **When** any agent there asks to start another, **Then** nothing is started and it is told the project already has three, and which three.
2. **Given** that project, **When** one of the three is archived, by the person or by the agent that started it, **Then** the next request to start one succeeds.
3. **Given** an agent, **When** it asks to stop or archive an agent it did not start — one the person started, one a workflow started, one another agent started, or itself — **Then** nothing changes and it is told it may only manage agents it started.
4. **Given** an agent, **When** it asks for an agent to be started in a different folder or project, **Then** no such request can be made: the new agent always starts in the caller's own project.
5. **Given** an agent that was itself started by another agent, **When** it looks for the tools, **Then** they are not offered to it, and a call made anyway is refused.

---

### User Story 3 - An agent stops and archives what it started (Priority: P2)

Once a helper has done its part, or has gone the wrong way, the agent that started it stops it or
archives it. Stopping leaves it in the list with its transcript, ready to be prompted again;
archiving puts it away and frees its place under the limit.

**Why this priority**: Without it, every helper stays until the person tidies up, and the project
fills to three and stays there. It depends on Story 1.

**Independent Test**: Have an agent start a helper on a long task, then ask the first agent to stop
it; confirm it stops exactly as it does when the person stops it. Then ask it to archive it;
confirm it is archived and the project's count goes down by one.

**Acceptance Scenarios**:

1. **Given** a working agent the caller started, **When** the caller stops it, **Then** it stops exactly as the person's Stop does, and its transcript says which agent stopped it.
2. **Given** an agent the caller started, in any state, **When** the caller archives it, **Then** it is archived exactly as the person's Archive does — stopped first if it was working — and its transcript says which agent archived it.
3. **Given** an agent the caller started that has already stopped or finished, **When** the caller stops it, **Then** nothing changes and no error is shown.
4. **Given** an agent the caller started that the person has since archived, **When** the caller asks to stop or archive it, **Then** nothing changes and the caller is told it is already archived.

---

### User Story 4 - An agent can see what it started (Priority: P2)

To know when to stop or archive a helper, the agent that started it can list the agents it started
and see, for each, its state and the one-line account the helper gave when it last finished a turn.

**Why this priority**: Stop and archive are guesses without it. Kept deliberately small: state and
the helper's own one-line outcome, not the transcript.

**Independent Test**: Start two helpers, let one finish, then ask the starting agent to list them.
Confirm both appear, one working and one finished with its outcome line, and that no agent it did
not start appears.

**Acceptance Scenarios**:

1. **Given** an agent that has started agents, **When** it lists them, **Then** it sees each one that is not archived: how to refer to it, its prompt's opening words, its state, and its last reported outcome if it has one.
2. **Given** that list, **When** it is read, **Then** it also says how many of the project's three places are in use, so the caller knows whether it can start another.
3. **Given** an agent that has started none, **When** it lists them, **Then** it is told it has started none and how many places the project has free.

---

### Edge Cases

- **Two agents ask for the last place at the same moment.** One is started, the other is refused; the project never holds four.
- **The person starts agents by hand.** They never count against the three and are never manageable by an agent.
- **A workflow starts an agent.** That agent counts as the person's for this feature: it does not use one of the three and cannot be managed by another agent. A workflow's agent may itself use the tools, since the person set the workflow up.
- **The agent that started a helper is archived or stopped.** Its helpers carry on untouched; they are the person's to manage from then on. They still count against the three until archived.
- **The daemon restarts.** Which agent started which, and the count, survive the restart; helpers that were working come back as any agent does.
- **The project is archived.** Its agents are handled as they are today; nothing here changes that.
- **A helper asks the person a question or for permission.** It appears in the person's attention the way any agent's does; the agent that started it does not answer on the person's behalf.
- **A helper finishes, stops or asks for something.** The project's workflows fire for it as they do for any agent.
- **The caller's own conversation has ended.** A call arriving for a conversation that is no longer open is refused and changes nothing, as the workflow tool's calls are today.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST offer an agent tools to start an agent, stop an agent, archive an agent, and list the agents it has started.
- **FR-002**: A started agent MUST run in the caller's own project folder. The tools MUST NOT accept a folder or project; the caller's identity decides it.
- **FR-003**: Starting MUST take a prompt and MAY take a runtime, model and permission mode, with the same meanings and defaults as a workflow's `runtime:`, `model:` and `permission-mode:`. An unrecognised value MUST stop the start rather than fall back.
- **FR-004**: The app MUST record, durably, which agent started each agent-started agent, and show it to the person wherever the agent is listed and at the top of its chat.
- **FR-005**: A project MUST never hold more than three agent-started agents that are not archived, however many requests arrive together. A start that would exceed it MUST be refused, naming the three.
- **FR-006**: Stop and archive MUST refuse, changing nothing, unless the target was started by the caller. That includes the caller itself.
- **FR-007**: Stop and archive MUST do exactly what the person's Stop and Archive do, by the same path, and the transcript MUST say which agent did it. *(Planned: the ending reads "Stopped by the agent that started it" rather than "Stopped by you", so the row never credits the person with a stop they did not make; everything else is the person's path unchanged.)*
- **FR-008**: The tools MUST NOT be offered to an agent that another agent started, and MUST refuse if called from one.
- **FR-009**: Every refusal MUST say in plain words why, so the calling agent can tell the person or change course.
- **FR-010**: The person MUST keep every power over an agent-started agent that they have over any other, and nothing an agent does with these tools MUST ask the person first.
- **FR-011**: Listing MUST return only agents the caller started and not yet archived, with each one's state and last reported outcome, and the number of the project's places in use.
- **FR-012**: The briefing an agent receives MUST describe the tools and their limits, and say to use them when the work has parts that can go on alongside each other, not by default.

### Key Entities

- **Agent-started agent**: An agent whose start was requested by another agent through these tools. Carries the agent that started it. Counts against its project's limit until archived.
- **Starting agent**: The agent that made the request. The only one besides the person that may stop or archive the agents it started.
- **Project limit**: Three agent-started agents that are not archived, per project, across all starting agents.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An agent can start a helper, see it finish, and archive it without the person touching anything, and the person can see all of it in the agent list as it happens.
- **SC-002**: Across repeated trials of concurrent start requests, a project never holds more than three agent-started agents that are not archived.
- **SC-003**: Every attempt to stop or archive an agent the caller did not start is refused, and zero agents change state as a result.
- **SC-004**: Zero agents are ever started outside the caller's project through these tools.
- **SC-005**: A person looking at any agent-started agent can tell which agent started it without opening anything else.
- **SC-006**: Every refusal is readable by the calling agent as a reason it can repeat to the person.

## Assumptions

- **The socket route stays open for now.** Any process running as the person can reach the daemon socket and do anything there. Closing it (for example, telling the app's own clients apart from an agent's shell) is a separate feature and should follow this one. Until then these limits are a guard for agents that use the tools, not a wall.
- Starting through these tools does not ask the person, following the workflow tool, where asking first was tried and found worse. The limit of three and the visible list are the guard.
- "Archived" is the only thing that frees a place. A stopped or finished helper still counts, so a project cannot fill up with idle helpers unseen.
- A helper gets the same app tools as any agent except these four. It can end turns, show files and manage workflows.
- Sending a further prompt to a helper is out of scope. The starting agent gives one prompt at start; after that the helper is the person's to talk to. Reading a helper's full transcript is also out of scope.
- The starting agent is not woken or told when a helper finishes. It finds out by listing.
- Helpers appear on the phone as any agent does, with who started them shown.
- A workflow's agent counts as the person's, because the person wrote the workflow.
