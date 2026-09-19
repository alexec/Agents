# Implementation Plan: Projects, not agents

**Branch**: `004-project-focused-ui` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Revised** 2026-09-18 after the clarification session added the project lead.

> **The project lead was removed on 2026-09-19.** Sections below that describe a lead agent, its
> tools, its guards or its permission handling record a design that was built and then taken out
> again, before the layout it sat on had settled. They are kept as the reasoning for when it comes
> back. Nothing they describe is in the code.

**Input**: Feature specification from `specs/004-project-focused-ui/spec.md`

## Summary

The window stops being a list of agents and becomes a list of folders, with the agents for the
selected folder beside it, grouped by whether they are waiting on the user.

The research turned this from a data feature into a view feature. A project has exactly two facts
that cannot be derived from the agents we already store — that it is archived, and that a folder is a
project before any agent has run in it — so the project list is the union of every agent's `cwd` and
a small file of records for those two cases. That is what makes old agents appear under projects with
no migration step: their folder is already on their record.

The rest follows. "Needs input" is one existing state, because permissions and elicitation forms both
route through `.waitingOnUser`. "Recently archived" is an existing timestamp, because archiving is a
state transition and transitions stamp `lastActivityAt`. "Show more" is a count in a view, because
the window already holds every archived agent. What is left is four daemon methods, one notification,
one new file on disk, and a third column.

Then the clarification added the project lead, and that is a different kind of work. Every project has
one agent whose job is the project: it starts the others, briefs them, reads how they got on, and
stops one that has gone wrong, with the user approving each move. The research put it on ground that
already exists — a lead is an `Agent` with a role, its powers are an MCP server the daemon offers, its
approvals are the permission question the app already asks, and its runtime starts lazily through the
queued-prompt path that landed on `main` this morning. That keeps the new surface small, but it is
still the part of this feature where a mistake reaches somebody's work rather than their window, so
the four guards around it are pure, tested first, and in the kit.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`.
Unchanged.

**Primary Dependencies**: None beyond the platform. Foundation, SwiftUI, Observation. This feature
adds none. The lead's powers are an MCP server we write and the runtimes already know how to consume;
`MCPServer` and the plumbing that sends it at `session/new` arrived with 003.

**Storage**: One new file, `~/Library/Application Support/Agents/projects.json`, holding tens of
records. `agent.json` gains one field, `role`, optional on read and defaulting to `.worker`, so every
record written by 001 through 003 loads unchanged. Window state — the selected project, whether the
archived lists are open — is `UserDefaults`, app-side.

**Testing**: `swift test` in `AgentsKit`. Grouping, project naming, the project record and the lead's
four guards are pure and get unit tests; the store, the daemon methods, the MCP tools and their
notifications get integration tests against the existing fake agent, which can be made to call a tool
on demand. Two tests matter most: that grouping is total over `AgentState.allCases`, because that is
what stops an agent falling out of the window, and that each guard refuses, because that is what stops
a lead reaching work it was not given. The opt-in live suite gains one case to find out which runtimes
ask their own MCP permission question on top of ours.

**Target Platform**: macOS 27, Apple silicon, one Mac.

**Project Type**: Desktop app plus a helper executable in its bundle. Unchanged.

**Performance Goals**: Selecting a project with 200 agents draws in under 1 second (SC-007). An agent
reaching "Needs input" shows there within 1 second, in every open window (SC-004). Both are filters
over a list already in memory plus one broadcast, so the goal is to not accidentally make them
quadratic.

**Constraints**: Nothing this feature does may write to a project's directory (SC-008). No new
dependency. No second source of truth for which agents exist. Nothing a lead does to another agent may
happen without the user's approval or an approval they gave earlier (SC-011), and a lead may not reach
outside its own project (FR-038). A project nobody has prompted must cost nothing (SC-010).

**Scale/Scope**: 50 functional requirements over 4 user stories. Tens of projects, hundreds of agents,
one lead per project, one person, one Mac.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the Spec Kit template. No principles have been written for
this project, by the user's explicit decision, so there is nothing to check against and no violation
can be claimed.

The rules in force are the ones 001 recorded and 003 carried forward. The design honours them:

| Rule in force | Where the design honours it |
|---|---|
| One person, one Mac, no accounts | Nothing here adds an account or a network call |
| The app is a window, the daemon is the owner | The daemon owns projects, stats the folders, and decides the refusal; the app owns only which project a window is looking at |
| One code path for every runtime | Projects know nothing about runtimes |
| Logic where `swift test` can reach it | Grouping, naming and the project record are pure functions in `AgentsKit` |
| Nothing installed | No new process, no new file type, one new JSON file beside the existing ones |
| An option we do not understand is skipped, not guessed | `Project` keeps and rewrites unknown fields, as `Agent` does; an unknown `role` decodes as `.worker` |
| A change is asked for, a read is recorded | The lead's reads are served; everything it changes raises the permission question 003 already built |

**Re-check after Phase 1**: the lead adds one field to `agent.json` (`role`, optional on read) and one
new process shape — `agentsd mcp`, a short-lived child the runtime spawns, which is the same helper
binary already in the bundle rather than anything installed. Neither is a new dependency, a background
service or a second transport: the MCP process talks to the daemon over the socket that already
exists. No violation to justify.

## Project Structure

### Documentation (this feature)

```text
specs/004-project-focused-ui/
├── plan.md              # This file
├── spec.md              # What it does
├── research.md          # Nine findings, each checked against the tree
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── daemon-api.md    # Four methods, one notification, two failure codes
│   ├── agent-tools.md   # The `project` MCP server: what a lead may do, and what it may not
│   └── ui.md            # The three columns, and what each promises
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks, not created here)
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKit/
├── Model/
│   ├── Project.swift        # NEW. folder, archivedAt, addedAt, unknown fields
│   ├── ProjectNaming.swift  # NEW. pure: a set of folders in, a display name each out
│   ├── AgentGroup.swift     # NEW. pure and total over AgentState
│   ├── AgentRole.swift      # NEW. worker | lead
│   └── Agent.swift          # Grows: `role`, optional on read, defaulting to worker
├── Store/
│   ├── ProjectStore.swift   # NEW. one JSON file, read whole, written whole
│   └── StoreLocations.swift # Grows: `projects`
├── Daemon/
│   ├── DaemonCore+Projects.swift # NEW. list, add, archive, unarchive, the union, the stat,
│   │                             # and making a lead for a project that has none
│   ├── DaemonCore+Lead.swift     # NEW. the five tools, the four guards, the held permission
│   ├── DaemonCore+Dispatch.swift # Grows: four cases
│   ├── DaemonCore+Commands.swift # Grows: agents/archive refuses a lead
│   └── DaemonAPI.swift           # Grows: methods, ProjectSummary, two failure codes
├── MCP/                          # NEW. The server we offer, not the ones we pass on
│   ├── MCPServer+Project.swift   # The tool definitions and their shapes
│   └── ProjectToolService.swift  # Scope check, permission, do it, record it
└── Client/                       # Grows: the four calls and the new notification

Daemon/Sources/
└── main.swift                    # Grows: an `mcp --agent <uuid>` mode that speaks MCP on stdio
                                  # and proxies to the daemon over the existing socket

App/Sources/
├── Projects/                # NEW
│   ├── ProjectListView.swift    # The sidebar: live projects, archived disclosure
│   ├── ProjectRow.swift         # Name, needs-you mark, missing, context menu
│   └── ProjectAgentsView.swift  # The panel: three groups, archived disclosure, show more
├── Projects/
│   └── LeadRow.swift            # NEW. The pinned row above the groups
├── AgentList/
│   ├── AgentRow.swift           # Grows: says how a completed agent ended
│   └── AgentListView.swift      # Retired. Its empty-state view moves to Projects/
├── ContentView.swift            # Two columns become three
└── AppModel.swift               # Grows: projects, selectedProject, the four calls
```

**Structure Decision**: unchanged from 001. Two thin shells around one library. Everything that
decides anything — which project an agent is in, which group it falls in, what a project is called,
whether an archive is allowed, whether a lead may touch an agent — is a pure function or an actor
method in `AgentsKit`, where `swift test` reaches it. The app draws what it is told, and the MCP
process decides nothing: it is a pipe with a manifest.

## Key design decisions

### 1. The project list is derived, and the file holds only the exceptions

Every distinct agent `cwd` is a project. `projects.json` holds a record only when a project is
archived or was added before any agent ran in it. The daemon returns the union.

This is the decision the rest of the feature rests on. It means agents written by 001, 002 and 003
appear under projects with nothing to run and nothing to back-fill (FR-034), and it means an agent
arriving by a route nobody thought about — an adopted runtime session, a fork — lands in the right
project without being told. If `projects.json` is lost, every live project is still there; only
archived state goes. That is the right thing to lose.

### 2. Grouping is a total function, and a test exhausts it

`AgentGroup(for:)` maps every `AgentState` to exactly one group. A test runs it over
`AgentState.allCases`. The failure this prevents — a state nobody thought about, so an agent in no
group, so an agent the user cannot see — is the only way this feature can lose somebody's work.

"Needs input" is `.waitingOnUser`, which both permissions and elicitation forms already set. There is
no second condition to keep in step.

### 3. Archiving a project refuses; archiving an agent still stops it

`agents/archive` stops the agent it was given. `projects/archive` refuses while any agent is live and
names them. Stopping one agent the user just pointed at is small and visible; cancelling four turns
because the user tidied the sidebar is not. The difference is deliberate and the error message is
where the feature earns it.

### 4. The counts come from the daemon

A sidebar row must say a project needs the user even when that project is not selected, in every open
window. The daemon knows every agent, so it sends the per-group counts with each project, and
broadcasts `project/changed` when an agent change moves them. The app does not re-derive it, so two
windows cannot disagree.

### 5. Show more is a count, not a call

The window already holds every archived agent — `agents/list` includes them and always has. The
archived list shows ten and raises that by ten. Building a paged API for a list that is tens of
records for one person would be work protecting against a problem this app does not have.

### 6. Missing folders are shown, not newly guarded

The daemon stats each folder when it lists projects. A missing project stays listed, marked, with its
agents readable. `agents/start` is not touched: it already stats `cwd` and refuses with `folderGone`
before launching anything. The gap this closes is that the absence was invisible until somebody
tried. One `stat` per project per list is not a cost worth designing around.

### 7. What a window is looking at is not a fact about the work

The selected project and the two archived disclosures live in `UserDefaults`. The daemon owns what is
true about agents and projects; it does not own which of them somebody is reading. This also keeps
two windows independent, as they are today.

### 8. A lead is an `Agent` with a role

`Agent` gains `role: .worker | .lead`. The lead has a runtime, a folder, a conversation, a state, a
transcript, a cost and a context meter — it *is* an agent — so the chat view, the prompt bar, the
permission flow, the transcript store and the pick-up-a-stopped-agent path all work on it unchanged.
The three differences the spec names become three guards rather than a second record type, and
`projects.json` still stores nothing about it.

### 9. The powers are an MCP server, because that is the only door a runtime will knock on

ACP has no client method for managing agents, and inventing one means no runtime ever calls it. All
three runtimes take MCP servers, and `Agent.mcpServers` is already sent at `session/new`. So the lead
alone is given one server, `project`, over stdio: `agentsd mcp --agent <uuid>`, the helper binary
already in the bundle, proxying to the daemon over the socket it already knows how to find. No port,
no token, no listener. A runtime that ignores MCP still gives a working conversation about the
project, which is what makes the spec's "offered, not required" true rather than hopeful.

### 10. We ask the permission, not the runtime

Whether a runtime asks before calling an MCP tool is its own decision, differs between the three, and
an answer given inside the runtime is invisible to us — so "always" would live somewhere we cannot
read and the declined calls would be missing from the transcript. Instead the daemon holds the tool
call, raises the `PermissionRequest` the app already knows how to show and answer, and returns either
the work or a refusal the lead can read.

This is the decision that makes FR-039, FR-040 and FR-042 properties of our code instead of hopes
about someone else's. Its cost is that a runtime which also asks means two prompts for one action; we
cannot suppress that, so the live suite finds out which runtimes do it and the answer is written down.

### 11. The guards are the dangerous part, so they are pure and first

Four rules, each a function over records, each with its own test, all in the kit: `start_agent` only
ever makes a `.worker`; every tool that names an agent checks it shares the caller's folder;
`stop_agent` refuses the caller's own id; only a `.lead` is given the server. This is where a mistake
reaches somebody's work rather than their window, which is the same reason path confinement got this
treatment in 003.

### 12. `ChatView` is not touched

It moves from the detail column of a two-column split to the detail column of a three-column one.
Feature 002's right-hand inspector attaches to it and is unaffected by this feature.

## Phasing

Story 1 first; the other three build on it and are independent of each other.

1. **P1 — the layout.** `Project`, `ProjectNaming`, `AgentGroup`, `ProjectStore`, `projects/list`,
   `project/changed`, the three columns. At the end of this the app is project-focused and nothing can
   be archived yet.
2. **P2 — archiving projects.** `projects/add`, `projects/archive`, `projects/unarchive`, the refusal,
   the sidebar's archived disclosure. Needs P1's record and store.
3. **P2 — the project lead.** In this order, because each step is worth having on its own and the
   dangerous part comes before the powerful part:
   1. `AgentRole`, the lead record, created by `projects/list`, pinned in the panel and opened on
      selection. A lead you can talk to about the project, with no powers at all.
   2. The four guards and their tests, written before there is anything to guard.
   3. The `agentsd mcp` mode and the `project` server, with `list_agents` and `read_transcript` only —
      reads, nothing held, nothing changed.
   4. The held permission, then `start_agent`, `prompt_agent`, `stop_agent` behind it.
   5. `agents/archive` refuses a lead; project archive carries it.

   Step 3.3 is the first point a runtime can call us, and step 3.4 is the first point it can change
   anything. Neither lands before the guards do.
4. **P3 — archived agents.** The panel's archived disclosure, ten at a time, show more, remembered.
   Pure view work on top of P1.

Marking missing folders (research §7) rides with P1, because a sidebar that lies about a folder is
worse than one that cannot archive.

## What this feature now depends on

The lazy start the lead needs is `liveSession(for:)` and the prompt queue, which landed on `main` on
2026-09-18 from the queued-prompts work (research §10). This plan assumes it is there. It is.

## Complexity Tracking

No constitution violations to justify.

Two places this feature adds a concept rather than reusing one:

| Addition | Why needed | Simpler alternative rejected because |
|---|---|---|
| `AgentGroup` | The mapping from state to group is written once, in the kit, with a test that exhausts it | Three copies in three views is three chances for an agent to fall out of all of them |
| The `project` MCP server and its helper mode | It is the only door a runtime will knock on to reach code we wrote | A custom ACP client method would never be called; an HTTP server means a port and a shared secret on a single-user Mac |

The lead itself adds no concept: it is an `Agent` with a role, which is why the chat view, the store,
the permission flow and the pick-up path all work on it unchanged.
