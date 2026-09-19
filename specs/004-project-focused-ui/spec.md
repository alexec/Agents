# Feature Specification: Projects, not agents

**Feature Branch**: `004-project-focused-ui`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "The current UI is focussed on agents. It is time to uplift and focus on projects. A project is a directory. The project name is the directory name. A project can be archived and unarchived (much like an agent). The left sidebar shows a list of projects instead of agents. The right panel shows the agents in groups. The first group is the "Needs input" group, then the "working" group, then the "completed" group. The user has the option to show archived agents in another list, and that shows recently archived agents, with a show more option."

## Why this feature exists

The app was built around agents because agents were the new thing. But nobody sits down to work on an
agent. They sit down to work on a codebase, and the agents are how the work gets done. After a few
weeks of use the sidebar is one long list of every agent ever started, across every folder, and
finding the two that matter means reading past thirty that do not.

A project is the folder. Put the folders in the sidebar and the agents beside them, sorted by whether
they are waiting on the user, and the window answers the question the user actually arrives with:
what needs me, and where.

And once a project is a thing rather than a filter, it can be handed a goal rather than a task. Each
project has a lead: one agent whose job is the project itself, which starts the others, gives them
their work and reports how they got on. The user describes what they want done once, to one
conversation, and approves the lead's moves as they come. That is the difference between a window
that organises work and one that takes it on.

## Clarifications

### Session 2026-09-18

- Q: What is the project lead agent allowed to do to the other agents in its project? → A: Delegate and supervise — start agents in the project, prompt them, read their transcripts and states, stop them. Archiving stays with the user.
- Q: How does a project's lead agent come to exist? → A: Always there, started lazily — every project has a lead, visible from the start, but no process runs and nothing is spent until it is first prompted.
- Q: When the lead starts, prompts or stops another agent, does it need the user's permission first? → A: Yes — the same permission question as any other tool call, with the existing allow-once and allow-always answers.
- Q: Where does the lead appear, and does it sit inside the three groups? → A: Pinned above the groups in its own place, outside them, and selected by default when a project is picked.
- Q: What happens to a project's lead when the project is archived? → A: It goes away with the project and comes back with it, conversation intact. It cannot be archived on its own, and a lead with a turn in flight blocks archiving like any other agent.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Pick a project, see what needs you (Priority: P1)

The user opens the window. The sidebar lists the folders they work in, by name. They pick one and the
panel beside it shows that project's agents in three groups, in this order: the ones waiting on the
user, the ones working, and the ones that are done. Picking an agent opens its conversation, the same
conversation as before.

**Why this priority**: This is the whole uplift. Everything else in this feature is tidying around it,
and on its own it changes what the window is for.

**Independent Test**: Start agents in two folders, leave one waiting on a permission, and confirm each
project lists only its own agents, that the waiting one is at the top under "Needs input", and that
picking it opens its conversation.

**Acceptance Scenarios**:

1. **Given** agents exist in three folders, **When** the user opens the window, **Then** the sidebar
   lists three projects, named by their directory names, and no agents.
2. **Given** a project is selected, **When** the panel beside the sidebar draws, **Then** it shows only
   that project's agents, in the groups "Needs input", "Working" and "Completed", in that order, and
   omits any group that has nothing in it.
3. **Given** an agent in the selected project is asked for a permission, **When** the request arrives,
   **Then** that agent moves to "Needs input" without the user doing anything.
4. **Given** an agent in a project that is not selected needs input, **When** the sidebar draws,
   **Then** that project's row says so.
5. **Given** an agent is picked from the panel, **When** it is selected, **Then** its conversation
   opens, with the same transcript, prompt bar and controls as before this feature.
6. **Given** a project is selected, **When** the user starts an agent, **Then** that project's folder is
   the one it starts in, without the user choosing a folder again.

---

### User Story 2 - Put a project away when it is done (Priority: P2)

A piece of work finishes. The user archives the project and the sidebar is shorter. Months later they
come back to it, unarchive it, and everything is as they left it: the same agents, the same
conversations.

**Why this priority**: Without this the sidebar grows forever and the feature has traded a long list
of agents for a long list of folders. It is second because a list of projects is already shorter than
a list of agents, so the app is useful for a while before this bites.

**Independent Test**: Archive a project, confirm it leaves the sidebar and its agents are no longer
reachable from any project, unarchive it, and confirm both come back unchanged.

**Acceptance Scenarios**:

1. **Given** a project with no running agents, **When** the user archives it, **Then** it leaves the
   main sidebar list and its agents stop appearing in the panel.
2. **Given** an archived project, **When** the user shows archived projects, **Then** it is listed
   there, with when it was archived.
3. **Given** an archived project, **When** the user unarchives it, **Then** it returns to the sidebar
   with the same agents, in the same states, and their conversations intact.
4. **Given** a project with an agent that is running or waiting on the user, **When** the user tries to
   archive it, **Then** the app declines and says which agents must be stopped first.
5. **Given** any project is archived or unarchived, **When** the file system is inspected, **Then**
   nothing in the directory itself has changed.
6. **Given** the archived project was the selected one, **When** it is archived, **Then** the selection
   moves to another project rather than leaving an empty panel.

---

### User Story 3 - Look back at agents you archived (Priority: P3)

The user archived an agent last week and wants to read what it did. They turn on the archived list in
the project's panel, see the handful archived most recently, and ask for more if what they want is not
among them.

**Why this priority**: Reading an archived agent is rare, and today it is possible by scrolling the
one long list. This feature would otherwise remove that, so it has to come back — just not before the
things people do daily.

**Independent Test**: Archive several agents in one project, turn on the archived list, confirm the
most recently archived are shown newest first, ask for more, and confirm the rest arrive.

**Acceptance Scenarios**:

1. **Given** a project with archived agents, **When** the user turns on the archived list, **Then** the
   most recently archived agents appear, newest first, below the three live groups.
2. **Given** more archived agents exist than are shown, **When** the user asks to show more, **Then**
   further agents are added to the list, still newest first.
3. **Given** every archived agent in the project is listed, **When** the list draws, **Then** there is
   no "show more" left to press.
4. **Given** the archived list is on, **When** the user selects an archived agent, **Then** its
   conversation opens and can be read.
5. **Given** the archived list was left on, **When** the window is opened again, **Then** it is still
   on, and the same for off.
6. **Given** a project has no archived agents, **When** the user turns the list on, **Then** it says so
   plainly rather than showing an empty box.

---

### User Story 4 - Hand the project to its lead (Priority: P2)

Every project has a lead agent: one conversation that is about the project rather than about a task.
The user picks a project and the lead is what opens. They describe what they want done, and the lead
starts the agents to do it, gives each one its work, watches how they get on, and stops one that has
gone wrong. The user answers a permission question each time it does, until they say "always".

**Why this priority**: tied with Story 2, and both depend on Story 1. This is the largest piece of
work in the feature and the reason the window is organised by project at all — a project that can be
handed a goal rather than a task is worth more than a project that is only a filter.

**Independent Test**: open a project, tell its lead to get two things done, and confirm it starts two
agents in that project, that each gets its own instruction, that the user is asked before each one
starts, and that the lead can report what they did and stop one of them.

**Acceptance Scenarios**:

1. **Given** a project that has never been opened, **When** the user selects it, **Then** the lead's
   conversation opens, and no runtime has been started for it.
2. **Given** the lead has never been prompted, **When** the user sends it a first prompt, **Then** its
   runtime starts at that moment and not before.
3. **Given** a lead with work to hand out, **When** it starts an agent, **Then** the user is asked to
   allow it, the same way any tool call asks, and the agent starts in the project's folder.
4. **Given** the user answered "always" to starting agents, **When** the lead starts another, **Then**
   it is not asked again and the transcript records what it did.
5. **Given** agents the lead started, **When** it asks how they are getting on, **Then** it can read
   their states and their transcripts, and can prompt them again.
6. **Given** an agent that has gone wrong, **When** the lead stops it, **Then** the user is asked
   first, and on approval the agent stops as though the user had stopped it.
7. **Given** the lead is working, **When** the user tries to archive the project, **Then** it is
   refused and the lead is named among the agents to stop.
8. **Given** an archived project, **When** the user unarchives it, **Then** its lead is there with the
   whole conversation it had before.
9. **Given** any project, **When** the user looks at the panel, **Then** the lead is pinned above
   "Needs input" and appears in none of the three groups.
10. **Given** a lead that is waiting on a permission answer, **When** its project is not selected,
    **Then** that project's row in the sidebar says it needs the user.

---

### Edge Cases

- **Two folders with the same name.** `~/work/api` and `~/side/api` are two projects both called
  "api". Each row shows enough of the path to tell them apart, and only when there is something to
  tell apart.
- **The folder moved, was renamed, or was deleted.** The project stays in the list, marked as missing,
  and its agents and their conversations stay readable. Starting a new agent in it is refused with a
  sentence saying the folder is gone.
- **A folder inside another project's folder.** An agent started in `~/work/api/docs` belongs to a
  project called "docs", not to "api". Projects are matched by exact folder, never by containment.
- **A project with no agents.** It is listed, and its panel says what to do rather than showing three
  empty groups.
- **The last project is archived.** The window shows the same first-run guidance as an empty app:
  pick a folder and start something.
- **An agent changes group while it is being looked at.** It moves between groups in place; the user's
  selection follows it rather than being dropped.
- **An archived project's agent needs input.** It cannot happen — a project can only be archived when
  none of its agents is live — but a runtime that asks anyway must not resurrect the project silently.
  The request is held and the project's archived state is unchanged.
- **Nothing is selected.** The panel offers to start an agent, as the window does today.
- **The lead is asked to touch an agent in another project.** Refused. A lead reaches only the agents
  in its own project, and the refusal says so rather than failing silently.
- **The lead asks to start an agent and the user declines.** The lead is told, in the same way a
  declined tool call tells it, and carries on rather than stalling.
- **The lead's runtime is not installed or not signed in.** The project still opens and its agents
  still work. The lead's prompt bar says what is wrong, as an agent's does.
- **The lead stops an agent that has already finished.** Nothing happens, and the lead is told so.
- **The lead is asked to stop itself.** Refused. Stopping the lead is the user's, from its own
  conversation.
- **The project folder is missing and the lead is asked to start an agent.** Refused with the folder
  named, the same refusal the user gets.

## Requirements *(mandatory)*

### Functional Requirements

#### Projects

- **FR-001**: The system MUST represent a project as one directory, named by that directory's own name
  (its last path component).
- **FR-002**: The system MUST create a project for a folder the first time an agent is started in it,
  without the user being asked to create anything.
- **FR-003**: Users MUST be able to add a project by choosing a folder, before any agent has run in it.
- **FR-004**: The system MUST treat two different directories as two different projects even when their
  names are identical, and MUST show enough of the path to distinguish them when it does.
- **FR-005**: The system MUST assign each agent to exactly one project, matched on the agent's working
  folder exactly. Folders an agent was additionally granted MUST NOT put it in a second project.
- **FR-006**: The system MUST keep a project listed when its directory no longer exists, marked as
  missing, with its agents still readable.
- **FR-007**: The system MUST persist projects across restarts, and MUST show every open window the
  same list at the same time.

#### Archiving

- **FR-008**: Users MUST be able to archive a project and to unarchive it again.
- **FR-009**: The system MUST refuse to archive a project while any of its agents is running or waiting
  on the user, and MUST name those agents in the refusal.
- **FR-010**: The system MUST record when a project was archived, and that it was the user who did it.
- **FR-011**: Archiving MUST hide a project and its agents from the main list without changing any
  agent's own state, and unarchiving MUST restore both exactly.
- **FR-012**: Archiving or unarchiving a project MUST NOT create, move, rename or delete anything in the
  directory it names.
- **FR-013**: Users MUST be able to see archived projects in a list separate from the live ones.

#### The sidebar

- **FR-014**: The sidebar MUST list projects, not agents.
- **FR-015**: The sidebar MUST order live projects by their most recent agent activity, newest first.
- **FR-016**: A project row MUST show its name and MUST indicate when one of its agents needs the user,
  whichever project is selected.
- **FR-017**: Selecting a project MUST show that project's agents and MUST NOT change any agent's state.
- **FR-018**: The system MUST remember the selected project between launches, and MUST fall back to the
  most recently active one when that project is gone or archived.

#### The agent panel

- **FR-019**: The panel MUST group the selected project's agents under "Needs input", "Working" and
  "Completed", in that order.
- **FR-020**: "Needs input" MUST hold every agent with an outstanding permission request or form
  awaiting an answer.
- **FR-021**: "Working" MUST hold every agent with a turn in flight.
- **FR-022**: "Completed" MUST hold every agent that has settled — finished, stopped by the user, or
  stopped by an error — and MUST say which, per agent.
- **FR-023**: The panel MUST omit a group that has nothing in it rather than showing it empty.
- **FR-023a**: The three groups MUST hold every agent in the project except its lead, and each agent
  MUST be in exactly one of them.
- **FR-024**: Agents MUST move between groups as their state changes, while the panel is open, without
  the user refreshing anything.
- **FR-025**: Within each group, agents MUST be ordered by most recent activity, newest first.
- **FR-026**: Selecting an agent MUST open its conversation, with everything it had before this
  feature: transcript, prompt bar, controls, cost and usage.
- **FR-027**: The user's selected agent MUST survive that agent moving between groups.

#### Archived agents

- **FR-028**: Users MUST be able to turn on a list of the selected project's archived agents, shown
  below the three live groups and separate from them.
- **FR-029**: The archived list MUST show the most recently archived agents first, and MUST start with
  a limited number rather than all of them.
- **FR-030**: The archived list MUST offer to show more while more exist, and MUST NOT offer it when
  every archived agent in the project is already listed.
- **FR-031**: An archived agent MUST be selectable and its conversation readable.
- **FR-032**: The system MUST remember whether the archived list is on, across launches.

#### The project lead

- **FR-035**: Every project MUST have exactly one lead agent, which the user does not have to create.
- **FR-036**: A lead MUST NOT start a runtime, spend tokens or hold a process until it is first
  prompted.
- **FR-037**: A lead MUST be able to start agents in its own project, prompt them, read their states
  and transcripts, and stop them.
- **FR-038**: A lead MUST NOT reach any agent outside its own project, and MUST NOT archive or
  unarchive anything.
- **FR-039**: Each of a lead's actions on another agent MUST go through the same permission question
  as any other tool call, with the same allow-once and allow-always answers.
- **FR-040**: A permission the user answers "always" MUST NOT be asked again for that action in that
  project.
- **FR-041**: An agent a lead starts MUST be indistinguishable afterwards from one the user started,
  and MUST appear in the groups in the usual way.
- **FR-042**: The transcript MUST record every action a lead takes on another agent, including the
  ones the user declined.
- **FR-043**: The panel MUST show the lead pinned above the three groups, and MUST NOT show it in any
  of them.
- **FR-044**: Selecting a project MUST open its lead's conversation.
- **FR-045**: A lead that needs the user MUST mark its project's row in the sidebar, as any agent does.
- **FR-046**: A lead MUST NOT be archived, unarchived or deleted on its own.
- **FR-047**: Archiving a project MUST be refused while its lead has a turn in flight, and the refusal
  MUST name the lead among the agents to stop.
- **FR-048**: Archiving a project MUST hide its lead with it, and unarchiving MUST restore that lead's
  conversation exactly.
- **FR-049**: A lead MUST be stoppable by the user from its own conversation, and MUST NOT be able to
  stop itself.

#### Carried over

- **FR-033**: Everything that could be done to an agent before this feature — start, prompt, stop,
  archive, unarchive, answer a permission, answer a form — MUST still be possible from the new layout.
- **FR-034**: Agents recorded before this feature MUST appear under a project derived from the folder
  already on their record, with no migration step the user has to run.

### Key Entities

- **Project**: A directory the user works in. Has a name (the directory's own name), the folder it
  points at, whether it is archived and when, and when it last saw activity. Holds many agents and
  exactly one lead. Nothing it does touches the directory — archiving one changes nothing on disk.
- **Agent**: Unchanged. Belongs to exactly one project, by its working folder. Keeps its own state,
  transcript, cost and archived flag.
- **Project lead**: The one agent per project that coordinates the rest. An ordinary agent in every
  way that matters — a runtime, a folder, a conversation, a state — with three differences: it is
  created with its project rather than by the user, it is served the means to act on its project's
  agents, and it cannot be archived apart from its project.
- **Agent group**: A view over a project's agents — "Needs input", "Working", "Completed", and the
  archived list. Derived, never stored, so an agent is never in two groups or none. The lead sits
  outside all four.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user with agents across five or more folders can find the one agent waiting on them in
  under 5 seconds, without scrolling past agents from other folders.
- **SC-002**: Reaching any agent takes at most two selections: the project, then the agent.
- **SC-003**: The sidebar's length is the number of folders worked in, not the number of agents ever
  started: a user with 50 agents across 6 folders sees 6 rows.
- **SC-004**: An agent that starts needing input appears under "Needs input" within 1 second of the
  request arriving, in every open window.
- **SC-005**: 100% of agents that existed before this feature are reachable after it, under a project,
  with their conversations intact and no user action to migrate them.
- **SC-006**: Archiving and unarchiving a project leaves every one of its agents in the state it had
  before, verified across a restart.
- **SC-007**: Selecting a project with 200 agents shows its grouped agents in under 1 second.
- **SC-008**: No archive or unarchive, of a project or an agent, changes any file in the directory.
- **SC-009**: A user can get two independent pieces of work started from one conversation, without
  opening the start-an-agent flow once.
- **SC-010**: A project that has never been prompted costs nothing: no process, no tokens, verified by
  there being no runtime for it.
- **SC-011**: 100% of a lead's actions on other agents are either approved by the user or covered by an
  approval the user gave earlier, and all of them appear in the transcript.
- **SC-012**: An agent started by a lead is indistinguishable from one started by hand: same groups,
  same controls, same record.

## Assumptions

Decisions taken where the description did not say. Each is a candidate for `/speckit-clarify`.

- **Layout**: projects on the left, the grouped agent panel beside them, and the conversation beside
  that — three panes, so a project and an agent can both stay chosen. The right-hand inspector from
  feature 002 is unaffected and still belongs to the conversation.
- **"Completed" covers everything settled.** Three groups were named, and the app has four settled
  shapes: finished cleanly, stopped by the user, stopped by an error, and cancelled. They share the
  group and each row says which it was, rather than growing the list of groups.
- **Archiving a project leaves its agents alone.** Their own archived flags are untouched, so
  unarchiving the project restores exactly what was there. The alternative — archiving every agent
  with the project — loses that distinction on the way back.
- **A project cannot be archived while an agent is live**, mirroring the rule that an agent must be
  stopped before it is archived.
- **Projects are matched by exact folder.** A nested folder is its own project. Rolling nested folders
  up into a parent project is out of scope.
- **Deleting a project is out of scope.** Archiving is the way to make the list shorter, as it is for
  agents. Nothing in this feature removes a project record or touches the folder.
- **The archived agent list starts at ten** and shows ten more each time, which fits a screen and
  matches how far back people look in practice.
- **Renaming a project is out of scope**: the name is the directory's name, and renaming the project
  would mean renaming the folder.
- **Per-project settings are out of scope**, beyond the lead. A project is a folder, an archived flag
  and a lead. Default runtimes or MCP servers per project can come later.
- **The lead's runtime is chosen the way any agent's is**, and can be changed. Nothing here says which
  runtime coordinates best, and one runtime being better at it is a reason to choose, not to hard-code.
- **The lead has the project's folder and no more.** Its folder scope is the project's directory, the
  same as an agent started there by hand.
- **A lead that cannot coordinate is still a lead.** Its powers are offered to the runtime, not
  required of it, so a runtime that ignores them leaves a working conversation about the project
  rather than a broken one.
- **Leads do not coordinate each other.** A lead reaches its own project's agents. Nothing in this
  feature lets one lead talk to another, or to another project's agents.
- **Projects are held centrally**, as agents already are, so two open windows agree and the list
  survives every window being closed.
