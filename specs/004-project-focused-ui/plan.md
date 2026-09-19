# Implementation Plan: Projects, not agents

**Branch**: `004-project-focused-ui` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

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

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`.
Unchanged.

**Primary Dependencies**: None beyond the platform. Foundation, SwiftUI, Observation. This feature
adds none.

**Storage**: One new file, `~/Library/Application Support/Agents/projects.json`, holding tens of
records. `agent.json` is untouched: no new field, nothing optional to add, nothing to migrate. Window
state — the selected project, whether the archived lists are open — is `UserDefaults`, app-side.

**Testing**: `swift test` in `AgentsKit`. Grouping, project naming and the project record are pure
and get unit tests; the store, the four methods and their notifications get integration tests against
the existing fake agent. The one test that matters most is that grouping is total over
`AgentState.allCases`, because that is what stops an agent falling out of the window.

**Target Platform**: macOS 27, Apple silicon, one Mac.

**Project Type**: Desktop app plus a helper executable in its bundle. Unchanged.

**Performance Goals**: Selecting a project with 200 agents draws in under 1 second (SC-007). An agent
reaching "Needs input" shows there within 1 second, in every open window (SC-004). Both are filters
over a list already in memory plus one broadcast, so the goal is to not accidentally make them
quadratic.

**Constraints**: Nothing this feature does may write to a project's directory (SC-008). No new
dependency. No second source of truth for which agents exist.

**Scale/Scope**: 34 functional requirements over 3 user stories. Tens of projects, hundreds of
agents, one person, one Mac.

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
| An option we do not understand is skipped, not guessed | `Project` keeps and rewrites unknown fields, as `Agent` does |

**Re-check after Phase 1**: unchanged. The design adds no dependency, no background work, no second
transport, and no field to `agent.json`.

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
│   ├── daemon-api.md    # Four methods, one notification, one guard
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
│   └── Agent.swift          # Untouched
├── Store/
│   ├── ProjectStore.swift   # NEW. one JSON file, read whole, written whole
│   └── StoreLocations.swift # Grows: `projects`
├── Daemon/
│   ├── DaemonCore+Projects.swift # NEW. list, add, archive, unarchive, the union, the stat
│   ├── DaemonCore+Dispatch.swift # Grows: four cases
│   └── DaemonAPI.swift           # Grows: methods, ProjectSummary, two failure codes
└── Client/                       # Grows: the four calls and the new notification

App/Sources/
├── Projects/                # NEW
│   ├── ProjectListView.swift    # The sidebar: live projects, archived disclosure
│   ├── ProjectRow.swift         # Name, needs-you mark, missing, context menu
│   └── ProjectAgentsView.swift  # The panel: three groups, archived disclosure, show more
├── AgentList/
│   ├── AgentRow.swift           # Grows: says how a completed agent ended
│   └── AgentListView.swift      # Retired. Its empty-state view moves to Projects/
├── ContentView.swift            # Two columns become three
└── AppModel.swift               # Grows: projects, selectedProject, the four calls
```

**Structure Decision**: unchanged from 001. Two thin shells around one library. Everything that
decides anything — which project an agent is in, which group it falls in, what a project is called,
whether an archive is allowed — is a pure function or an actor method in `AgentsKit`, where
`swift test` reaches it. The app draws what it is told.

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

### 8. `ChatView` is not touched

It moves from the detail column of a two-column split to the detail column of a three-column one.
Feature 002's right-hand inspector attaches to it and is unaffected by this feature.

## Phasing

The stories are independent, in the spec's order, and each is shippable on its own.

1. **P1 — the layout.** `Project`, `ProjectNaming`, `AgentGroup`, `ProjectStore`,
   `projects/list`, `project/changed`, the three columns. At the end of this, the app is
   project-focused and nothing can be archived yet. This is most of the feature.
2. **P2 — archiving projects.** `projects/add`, `projects/archive`, `projects/unarchive`, the
   refusal, the sidebar's archived disclosure. Needs P1's record and store.
3. **P3 — archived agents.** The panel's archived disclosure, ten at a time, show more, remembered.
   Pure view work on top of P1.

Marking missing folders (research §7) rides with P1, because a sidebar that lies about a folder is
worse than one that cannot archive.

## Complexity Tracking

No constitution violations to justify. The one place this feature adds a concept rather than reusing
one is `AgentGroup`, and it exists so that the mapping from state to group is written once, in the
kit, with a test that exhausts it, rather than three times in three views.
