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

**Decision**: order the archived list by `lastActivityAt` descending. No timestamp field is added for
this, and nothing needs migrating.

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

---

## Clarification session 2026-09-18: the project lead

Five answers turned a layout feature into one that also lets an agent act on other agents. Five more
findings, checked the same way.

## 10. Lazy start is already built, by someone else, today

**Question**: FR-036 says a lead spends nothing until it is first prompted. Today `agents/start`
makes a session and sends a prompt in one call. Does a record with no runtime even work?

**Finding**: it does now. The queued-prompts work that landed on `main` on 2026-09-18 added
`liveSession(for:)` (`Daemon/DaemonCore+Commands.swift:193`), which returns the live session or
starts the runtime, and creates a new runtime session when the agent has no `runtimeSessionID`
(`:224`). `sendNextQueued` calls it before a prompt leaves the queue, with the comment "The runtime is
started before the prompt leaves the queue, so a runtime that will not start leaves the words exactly
where they were." `Agent` also gained `queuedPrompts` and `AgentState` gained `hasTurnInFlight`.

**Decision**: a lead is created as an ordinary agent record with no `runtimeSessionID`,
`state: .stopped`, `endedReason: .endTurn` — the same shape `agents/start` already writes — and its
runtime starts on the first prompt through the path that already exists.

**Rationale**: FR-036 costs one guard rather than a feature. The lead is created by
`projects/list` when a project first appears, which is a file write and nothing else.

**Consequence**: this feature now depends on that work being on `main`. It is.

## 11. The lead's powers are an MCP server the daemon provides

**Question**: how does a runtime call into us to start an agent? ACP has no client method for it, and
inventing one means no runtime would ever call it.

**Finding**: `Agent.mcpServers` already exists, is sent at `session/new` and `session/load`
(`DaemonCore+Commands.swift:212, 226`), and `MCPServer` supports stdio, http and sse, "advertised by
all three" runtimes (`Model/MCPServer.swift`). The app already ships a helper executable at
`Agents.app/Contents/Helpers/agentsd` (`Client/DaemonClient.swift:128`), whose source is
`Daemon/Sources/main.swift`.

**Decision**: the daemon offers the lead one MCP server, named `project`, over stdio:
`agentsd mcp --agent <uuid>`. That process speaks MCP on its stdio and proxies each tool call to the
daemon over the Unix socket it already knows how to find. Its tools are `list_agents`, `start_agent`,
`prompt_agent`, `read_transcript` and `stop_agent`.

**Rationale**: MCP is the one way a runtime will call code we wrote, and all three runtimes take MCP
servers today. stdio needs no port, no token and no listener — the runtime spawns the helper, and the
helper is already in the bundle. It also makes the spec's assumption true for free: the powers are
*offered*, so a runtime that ignores MCP still gives a working conversation about the project.

**Alternatives considered**: an HTTP or SSE server in the daemon. Rejected: a port and a shared secret
on a single-user Mac, to solve a problem stdio does not have. Extending the ACP client surface with
custom methods. Rejected: no runtime would call them.

## 12. The approval has to be ours, not the runtime's

**Question**: FR-039 says every action goes through the same permission question as any tool call, and
FR-040 says "always" is remembered. A runtime asking its own MCP permission question would seem to
satisfy that.

**Finding**: it would not, and we cannot rely on it. Whether a runtime asks before calling an MCP
tool is the runtime's decision, it differs between the three, and an answer the user gives inside the
runtime is invisible to us — so FR-040's "always" would live somewhere we cannot read, per runtime,
and FR-042's transcript record would be missing the ones the user declined.

**Decision**: the MCP tool call is held by the daemon, which raises an ordinary `PermissionRequest`
through the surface that already exists, waits for the answer, and then either does the work or
returns a refusal to the lead as the tool's result. Our question is the authoritative one.

**Rationale**: this is the only design where FR-039, FR-040 and FR-042 are properties of our code
rather than hopes about someone else's. It reuses `pendingPermissions`, `permissions/pending`,
`permissions/answer` and the existing question UI, and it works when no window is open, which the
permission surface already handles.

**Known wrinkle**: a runtime that also asks its own question means two prompts for one action. We
cannot suppress the runtime's. The live suite gets a case per runtime to find out which do it, and
the answer is documented rather than designed around, because ours is the one that decides.

## 13. A lead is an agent with a role, not a new kind of thing

**Question**: is the lead a field on `Project`, a second record type, or an `Agent`?

**Decision**: `Agent` gains `role: AgentRole` — `.worker` or `.lead` — optional on read, defaulting to
`.worker`, so every record written before this feature loads unchanged. A project's lead is the agent
whose `cwd` is the project folder and whose `role` is `.lead`.

**Rationale**: the lead has a runtime, a folder, a conversation, a state, a transcript, a cost and a
context meter. It *is* an agent, and making it one means the chat view, the transcript, the prompt bar,
the permission flow and the store all work on it with no special case. The three differences the spec
names — created with its project, served the `project` MCP server, not archivable alone — are three
guards, not a second type.

**Consequence**: `Project` still stores nothing about its lead, so the union in §1 is unchanged and
`projects.json` keeps holding only archived state.

## 14. The guards are where the danger is

**Question**: what stops a lead starting a lead, reaching another project, or stopping itself?

**Decision**: four checks, in `AgentsKit`, each with its own test:

1. `start_agent` always creates a `.worker`. A lead cannot be made through the tool at all.
2. Every tool that names an agent checks that agent's `cwd` equals the calling lead's `cwd`, and
   refuses otherwise. The lead is told why.
3. `stop_agent` refuses the caller's own id.
4. The `project` MCP server is attached only to agents whose `role` is `.lead`.

**Rationale**: this is the part of the feature where a mistake reaches somebody's work rather than
their window, so the rules are pure functions over the records, tested first, in the kit — the same
treatment path confinement got in 003 for the same reason.
