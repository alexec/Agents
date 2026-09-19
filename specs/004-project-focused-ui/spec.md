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


## Clarifications

### Session 2026-09-18

**Reverted on 2026-09-19.** Everything agreed in this session was built and then taken out again,
before the layout it sat on had settled. The answers are kept because they were given and are still
the answers, not because the feature is in. See the last assumption for where it stands.

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
- **FR-014b**: The sidebar's only creating control MUST add a project. There MUST NOT be a control
  for starting an agent by hand: work starts by telling a project what is wanted.
- **FR-015**: The sidebar MUST order live projects by their most recent agent activity, newest first.
- **FR-016**: A project row MUST show its name and MUST indicate when one of its agents needs the user,
  whichever project is selected.
- **FR-017**: Selecting a project MUST show that project's agents and MUST NOT change any agent's state.
- **FR-018**: The system MUST remember the selected project between launches, and MUST fall back to the
  most recently active one when that project is gone or archived.

#### The agent panel

- **FR-019**: The panel MUST group the selected project's agents under "Needs attention", "Running",
  "Finished" and "Stopped", in that order.
- **FR-019b**: The panel MUST show the project's name at the top, and below it a prompt for saying
  what the user wants done, above the groups.
- **FR-019c**: What the user types into that prompt MUST start an agent on it, in that folder.
- **FR-020**: "Needs attention" MUST hold every agent with an outstanding permission request or form
  awaiting an answer.
- **FR-021**: "Running" MUST hold every agent with a turn in flight.
- **FR-022**: "Finished" MUST hold every agent that ended cleanly, and "Stopped" every agent that was
  stopped by the user or by an error, each row saying which it was.
- **FR-023**: The panel MUST omit a group that has nothing in it rather than showing it empty.
- **FR-023a**: The four groups MUST hold every agent in the project, each in exactly one of them.
- **FR-024**: Agents MUST move between groups as their state changes, while the panel is open, without
  the user refreshing anything.
- **FR-025**: Within each group, agents MUST be ordered by most recent activity, newest first.
- **FR-026**: Selecting an agent MUST open its conversation, with everything it had before this
  feature: transcript, prompt bar, controls, cost and usage.
- **FR-027**: The user's selected agent MUST survive that agent moving between groups.

#### Archived agents

- **FR-028**: Users MUST be able to turn on a list of the selected project's archived agents with a
  "Show archived" control at the bottom of the panel, shown below the live groups and separate.
- **FR-029**: The archived list MUST show the most recently archived agents first, and MUST start with
  a limited number rather than all of them.
- **FR-030**: The archived list MUST offer to show more while more exist, and MUST NOT offer it when
  every archived agent in the project is already listed.
- **FR-031**: An archived agent MUST be selectable and its conversation readable.
- **FR-032**: The system MUST remember whether the archived list is on, across launches.

#### Carried over

- **FR-033**: Everything that could be done to an agent before this feature — start, prompt, stop,
  archive, unarchive, answer a permission, answer a form — MUST still be possible from the new layout.
- **FR-034**: Agents recorded before this feature MUST appear under a project derived from the folder
  already on their record, with no migration step the user has to run.

### Key Entities

- **Project**: A directory the user works in. Has a name (the directory's own name), the folder it
  points at, whether it is archived and when, and when it last saw activity. Holds many agents.
  Nothing it does touches the directory — archiving one changes nothing on disk.
- **Agent**: Unchanged. Belongs to exactly one project, by its working folder. Keeps its own state,
  transcript, cost and archived flag.
- **Agent group**: A view over a project's agents — "Needs input", "Working", "Completed", and the
  archived list. Derived, never stored, so an agent is never in two groups or none.

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
- **Per-project settings are out of scope.** A project is a folder and an archived flag. Default
  runtimes or MCP servers per project can come later.
- **A coordinating agent is out of scope, for now.** A "project lead" — one agent per project that
  starts and briefs the others — was specified, built and then removed on 2026-09-19, before the
  layout had settled. It is a good idea resting on a UX that was still moving; it comes back when
  the shape of a project page is decided. See the clarification session below for what was agreed.
- **Projects are held centrally**, as agents already are, so two open windows agree and the list
  survives every window being closed.
