# Research: Projects, not agents

**Date**: 2026-09-18. Every finding below was checked against this repository on that date, not
recalled. File and line references are to the tree as it stands.

## 1. A project has no state of its own worth storing, except the two things it does

**Question**: is a project a record we keep, or a view over the agents we already have?

**Finding**: almost everything a project shows is already on the agents. `Agent.cwd` is the folder
(`Model/Agent.swift`), `Agent.lastActivityAt` is the activity, and the name is the folder's last path
component. Only two facts cannot be derived: that a project is archived, and that a folder is a
project before any agent has run in it.

**Decision**: the project list is the union of two sources — every distinct `cwd` across all agents,
and every stored project record. A record exists only when there is something to remember (archived,
or added by hand). A folder with agents and no record is a live project.

**Rationale**: this makes FR-034 free. Every agent written by 001, 002 or 003 already carries its
folder, so projects appear for old records with no migration step and nothing to run. It also means
an agent arriving by a route we did not think of — an adopted runtime session, a forked agent — lands
in the right project without anything being told about it.

**Alternatives considered**: a record per project, written when an agent starts. Rejected: it is a
second source of truth for the same fact, and the first time the two disagree (an agent whose folder
has no record) the app has to decide which to believe. Deriving avoids the question.

## 2. "Recently archived" is already on the record

**Question**: ordering archived agents newest-first needs an archived-at time. `Agent` has
`archivedReason` but no `archivedAt`.

**Finding**: `DaemonCore.move` sets `agent.lastActivityAt = Date()` on every state transition,
including the one into `.archived` (`Daemon/DaemonCore.swift:131`). For an agent in `.archived`,
`lastActivityAt` *is* when it was archived: nothing else can move it, because an archived agent holds
no runtime (`AgentState.holdsRuntime`) and so receives no updates.

**Decision**: order the archived list by `lastActivityAt` descending. No new field, no migration.

**Rationale**: adding `archivedAt` would be a second timestamp that has to be kept true, and would be
absent on every agent archived before this feature — the exact agents the list is for.

**Alternatives considered**: add `archivedAt`, optional on read, back-filled from `lastActivityAt`.
Rejected as the same number under a second name.

## 3. "Needs input" already has one source of truth

**Question**: the group must hold agents blocked on a permission *and* agents blocked on an
elicitation form. Are those one state or two?

**Finding**: one. Both paths call `move(agentID, on: .permissionAsked)` — permissions at
`Daemon/DaemonCore.swift:230`, elicitation forms at `Daemon/DaemonCore+Serving.swift:62` — and the
state machine sends `.running` to `.waitingOnUser` for that event (`Model/AgentState.swift`).

**Decision**: "Needs input" is `state == .waitingOnUser`, nothing more. "Working" is
`state == .running`. "Completed" is `.finished` and `.stopped`. Archived is `.archived`.

**Rationale**: the grouping is then a total function over `AgentState`, so a test can exhaust it and
no agent can fall out of every group. That property is worth more than a cleverer rule.

**Consequence**: the app's separate `permissions` and `elicitations` arrays stay as they are — they
carry the *question*, which the conversation needs. The group only needs the state.

## 4. The app already holds every archived agent, so "show more" is a view concern

**Question**: does the archived list need a paged daemon call?

**Finding**: no. `DaemonAPI.ListRequest.includeArchived` defaults to `true`
(`Daemon/DaemonAPI.swift:192`) and `AppModel.agents` is the whole list. Archived agents are already in
the window, and are already filtered out of the sidebar by `AgentListView`'s group states.

**Decision**: "show more" raises a count held in the view. No new method, no cursor, no fetch.

**Rationale**: a paging API would be real work protecting against a list that is, in this app, tens of
records for one person on one Mac. If an agent count ever makes `agents/list` the wrong shape, that is
a change to `agents/list` for every caller, not a special case for this list.

## 5. Archiving a project refuses; archiving an agent stops first

**Question**: the spec (FR-009) says archiving a project is refused while an agent is live. What does
archiving an *agent* do today?

**Finding**: it stops it. `DaemonCore.archive` calls `stop(agentID)` when the agent
`holdsRuntime`, then moves it (`Daemon/DaemonCore+Commands.swift:278`). The state machine itself
refuses (`AgentState.applying` returns nil for `.archivedByUser` from `.running`), so the command is
being deliberately kind about one agent the user is looking at.

**Decision**: keep agent archiving as it is. Project archiving refuses, and names the live agents.

**Rationale**: stopping one agent the user just pointed at is a small, visible thing. Silently
cancelling four turns across a project because the user tidied the sidebar is not. The refusal names
them so the user can decide.

## 6. Two folders, one name

**Question**: `~/work/api` and `~/side/api` are both called "api". What does the sidebar show?

**Decision**: a pure function in `AgentsKit` takes the set of project folders and returns a display
name each: the last path component, extended leftwards one component at a time until it is unique
among the set. `~/work/api` becomes "work/api" only while `~/side/api` is also listed.

**Rationale**: names stay short in the common case, which is every case until it is not. Doing it over
the whole set rather than per project is what makes the name stable and the disambiguation minimal.

**Alternatives considered**: always show the parent, or always show the full path. Both make every row
longer to solve a problem most users never have. Tilde-abbreviated full path in the row's tooltip
covers the rest.

## 7. The folder may not be there

**Question**: what does the app do when a project's directory has been moved, renamed or deleted?

**Finding**: `agents/start` already refuses. `DaemonCore.start` stats `cwd` before it launches
anything and throws `folderGone` — *"…is not there any more."* — at `Daemon/DaemonCore+Commands.swift:74`.
So the failure is already ours and already early. What is missing is only that the folder's absence is
invisible until somebody tries.

**Decision**: the daemon stats each project folder when it lists projects and marks it missing.
Missing projects stay in the list with their agents readable. `agents/start` is unchanged: the guard
it already has is the right one, and the sidebar now says so before the user reaches it.

**Rationale**: the daemon is the one that knows, and doing it there means two windows say the same
thing. Tens of `stat` calls per list is not a cost worth designing around. Reusing the existing
`folderGone` rather than adding a second code for the same condition keeps one answer to one
question.

## 8. Three panes

**Question**: how does a projects sidebar, a grouped agent panel and a conversation sit together?

**Decision**: `NavigationSplitView(sidebar:content:detail:)` — the three-column form. Projects in the
sidebar, the grouped agent list as content, `ChatView` as detail, unchanged.

**Rationale**: it is the platform's own shape for this exact arrangement (Mail's mailboxes, messages,
message), it keeps a project and an agent both selected — which the spec's assumption asks for — and
`ChatView` moves across without being touched. Feature 002's right-hand inspector attaches to the
detail column and is unaffected.

**Alternatives considered**: two columns with the conversation replacing the agent list on selection.
Rejected: going back to the list to start a second agent loses the conversation, and the panel's whole
job is to be glanceable while work is in flight.

## 9. What the user chose has to survive a relaunch

**Decision**: the selected project and whether the archived list is shown are window state, kept in
`UserDefaults` by the app. Neither is a fact about the work, so neither goes to the daemon.

**Rationale**: the daemon owns what is true about agents. Which of them a window happens to be looking
at is not that. This also keeps two windows independent, which they are today.
