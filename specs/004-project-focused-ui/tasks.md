---
description: "Task list for Projects, not agents"
---

# Tasks: Projects, not agents

**Input**: Design documents from `specs/004-project-focused-ui/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included. The spec's quickstart names the suites, and two properties in this feature — that
grouping is total over `AgentState`, and that a lead cannot reach work it was not given — can only be
held by tests.

**Organization**: By user story, in the plan's phase order. US1 first; US2 and US4 are both P2 and
independent of each other; US3 is pure view work on US1.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1, US2, US3, US4 — maps to the user stories in spec.md

## Path Conventions

Two shells around one library, unchanged from 001:

- `Packages/AgentsKit/Sources/AgentsKit/` — everything that decides anything
- `Packages/AgentsKit/Tests/AgentsKitTests/` — `Unit/`, `Integration/`, `Live/`, `Fake/`
- `App/Sources/` — the window
- `Daemon/Sources/` — the `agentsd` helper

---

## Phase 1: Setup

**Purpose**: Confirm the ground this feature stands on, and make the one place new files land.

- [X] T001 Confirm `liveSession(for:)` and `Agent.queuedPrompts` are on `main` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` and `Packages/AgentsKit/Sources/AgentsKit/Model/Agent.swift` — the lead's lazy start depends on them (research §10). Stop and say so if they are gone.
- [X] T002 [P] Add `projects` to `StoreLocations` in `Packages/AgentsKit/Sources/AgentsKit/Store/StoreLocations.swift`, returning `root.appendingPathComponent("projects.json")`, and leave `createDirectories()` unchanged since the file sits beside `agents/`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure pieces every story needs. All of it is `AgentsKit`, none of it touches the app.

**⚠️ CRITICAL**: No user story work begins until this phase is complete.

- [X] T003 [P] Create `AgentGroup` in `Packages/AgentsKit/Sources/AgentsKit/Model/AgentGroup.swift`: cases `needsInput`, `working`, `completed`, `archived`, and a total `init(for: AgentState)` mapping `.waitingOnUser`→`needsInput`, `.running`→`working`, `.finished` and `.stopped`→`completed`, `.archived`→`archived`.
- [X] T004 [P] Write `Unit/AgentGroupTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/` asserting `AgentGroup(for:)` is total over `AgentState.allCases` — every case maps, none maps twice. This is the test that stops an agent falling out of the window.
- [X] T005 [P] Create `ProjectNaming` in `Packages/AgentsKit/Sources/AgentsKit/Model/ProjectNaming.swift`: `displayNames(for folders: [URL]) -> [URL: String]`, each folder's last path component extended leftwards one component at a time until unique within the set.
- [X] T006 [P] Write `Unit/ProjectNamingTests.swift` covering no collision, one collision, a collision needing two components, a folder at the filesystem root, and two folders differing only in case.
- [X] T007 [P] Create `Project` in `Packages/AgentsKit/Sources/AgentsKit/Model/Project.swift`: `folder: URL` (resolved, standardised, no trailing slash — the identity), `archivedAt: Date?` (nil means live), `addedAt: Date`, `unknownFields: [String: JSONValue]` kept and rewritten as `Agent` does; derived `id` (the folder), `isArchived` (`archivedAt != nil`).
- [X] T008 [P] Write `Unit/ProjectTests.swift` covering folder standardisation (trailing slash, `..`, symlink, case), identity equality, and an unknown-field round trip that does not drop keys.
- [X] T009 Create `ProjectStore` in `Packages/AgentsKit/Sources/AgentsKit/Store/ProjectStore.swift`: reads and writes the whole JSON array at `locations.projects` using `StoreCoding`'s encoder and decoder. A missing or unreadable file is an empty list, never an error (depends on T002, T007).
- [X] T010 Extend `DaemonAPI` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonAPI.swift` with `Method.projectsList/Add/Archive/Unarchive` (`"projects/list"`, `"projects/add"`, `"projects/archive"`, `"projects/unarchive"`), `Notification.projectChanged` (`"project/changed"`), `ProjectSummary` (`project`, `name`, `exists`, `lastActivityAt`, `counts: [AgentGroup: Int]`), `ProjectsListRequest(includeArchived: Bool = true)`, `ProjectRequest(folder: URL)`, and `Failure.noSuchProject = -32011`, `Failure.projectHasLiveAgents = -32012` (depends on T003, T007).

**Checkpoint**: The kit knows what a project is and what a group is. Nothing is wired up yet.

---

## Phase 3: User Story 1 - Pick a project, see what needs you (Priority: P1) 🎯 MVP

**Goal**: The sidebar lists folders, the panel beside it shows that folder's agents in three groups,
and picking one opens its conversation.

**Independent Test**: Start agents in two folders, leave one waiting on a permission, and confirm each
project lists only its own agents, the waiting one is at the top under "Needs input", and picking it
opens its conversation.

### Tests for User Story 1

- [X] T011 [P] [US1] Write `Integration/ProjectsTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/` for `projects/list`: the union of agent `cwd`s and stored records, ordering by newest activity, disambiguated names, `exists` false for a missing folder, and counts per group.
- [X] T012 [P] [US1] Write `Integration/ProjectMigrationTests.swift` asserting agents written before this feature — records with no project anywhere — appear under a derived project with nothing to run, and that a folder with agents and no record takes `addedAt` from its oldest agent's `createdAt`.

### Implementation for User Story 1

- [X] T013 [US1] Create `DaemonCore+Projects.swift` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/` with `allProjects(includeArchived:) -> [ProjectSummary]`: union every distinct agent `cwd` with every `ProjectStore` record, stat each folder for `exists`, compute `lastActivityAt` as the newest agent activity or `addedAt`, count workers per `AgentGroup`, and name them all through `ProjectNaming.displayNames(for:)` over the whole returned set (depends on T005, T009, T010).
- [X] T014 [US1] Add the `projects/list` case to `handle(method:params:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift` (depends on T013).
- [X] T015 [US1] Broadcast `project/changed` from `DaemonCore.changed(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` whenever an agent change moves its project's counts or `lastActivityAt`, sending one `ProjectSummary` (depends on T013).
- [X] T016 [US1] Add `projects` to `AppModel` in `App/Sources/AppModel.swift`: `private(set) var projects: [ProjectSummary]`, load it in `refreshEverything()`, upsert by `folder` on the `project/changed` notification in `received(_:_:)`, and add `workers(in:group:)` filtering the held agent list by `cwd` and group, newest first (depends on T010, T014, T015).
- [X] T017 [US1] Add `selectedProject: URL?` to `App/Sources/AppModel.swift`, persisted to `UserDefaults` under `selectedProjectFolder`, restored at launch and falling back to the most recently active project when the stored one is gone or archived (FR-018).
- [X] T018 [P] [US1] Create `App/Sources/Projects/ProjectRow.swift`: the disambiguated name, a mark when `counts.needsInput > 0`, dimmed and marked when `exists` is false, and the tilde-abbreviated full path as help text.
- [X] T019 [US1] Create `App/Sources/Projects/ProjectListView.swift`: live projects newest-activity first, selection bound to `model.selectedProject`, the "New agent" toolbar button carried over from `AgentListView`, and the empty state moved across unchanged (depends on T016, T017, T018).
- [X] T020 [US1] Create `App/Sources/Projects/ProjectAgentsView.swift`: the selected project's workers under "Needs input", "Working", "Completed" in that order, each group omitted when empty, ordered newest first within a group, with the selection bound to `model.selection` (depends on T016).
- [X] T021 [US1] Add the ended reason to `App/Sources/AgentList/AgentRow.swift` so a row in "Completed" says whether it finished, was stopped by the user, or stopped on an error (FR-022).
- [X] T022 [US1] Turn `NavigationSplitView` in `App/Sources/ContentView.swift` into its three-column form — `ProjectListView` as sidebar, `ProjectAgentsView` as content, the existing `ChatView`-plus-`SidebarView` detail untouched — keeping the `GeometryReader`, the environment objects and the right-hand sidebar from 002 exactly as they are (depends on T019, T020).
- [X] T023 [US1] Animate group membership in `App/Sources/Projects/ProjectAgentsView.swift` so an agent moves between groups in place and the selection follows the agent rather than the row position (FR-024, FR-027).
- [X] T024 [US1] Delete `App/Sources/AgentList/AgentListView.swift` once its empty state and toolbar have moved, and remove its references (depends on T019, T022).

**Checkpoint**: The app is project-focused. Nothing can be archived yet and there is no lead.

---

## Phase 4: User Story 2 - Put a project away when it is done (Priority: P2)

**Goal**: Archive a project, and unarchive it with everything as it was.

**Independent Test**: Archive a project, confirm it leaves the sidebar and its agents leave the panel,
unarchive it, and confirm both come back unchanged across a restart.

### Tests for User Story 2

- [X] T025 [P] [US2] Write `Integration/ProjectArchiveTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/`: archiving with a live agent is refused and the error names it; archiving with none succeeds and leaves every agent's own `state` and `archivedReason` untouched; unarchiving restores exactly; the archived state survives a daemon restart; `projects/add` on an existing project returns it rather than failing.

### Implementation for User Story 2

- [X] T026 [US2] Add `addProject(_:)`, `archiveProject(_:)` and `unarchiveProject(_:)` to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift`: add standardises the folder, fails `folderGone` when the directory is not there, and is idempotent; archive sets `archivedAt` and fails `projectHasLiveAgents` when any agent in the folder is `running` or `waitingOnUser`, naming them in the message; unarchive clears `archivedAt` and succeeds whether or not the folder exists. Each broadcasts `project/changed` (depends on T013).
- [X] T027 [US2] Add the `projects/add`, `projects/archive` and `projects/unarchive` cases to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift` (depends on T026).
- [X] T028 [US2] Add `addProject(_:)`, `archiveProject(_:)` and `unarchiveProject(_:)` to `App/Sources/AppModel.swift`, surfacing a refusal through the existing `problem` alert (depends on T026, T027).
- [X] T029 [US2] Add archive and unarchive to the context menu in `App/Sources/Projects/ProjectRow.swift`, and to the app menu with the selected project as target (depends on T028).
- [X] T030 [US2] Add the archived-projects disclosure to the bottom of `App/Sources/Projects/ProjectListView.swift`, listing archived projects with when they were archived, its open state persisted to `UserDefaults` under `showsArchivedProjects` (depends on T028).
- [X] T031 [US2] Move the selection to another project in `App/Sources/AppModel.swift` when the selected one is archived, rather than leaving an empty panel (FR-018, US2 scenario 6) (depends on T017, T028).

**Checkpoint**: Projects can be put away and brought back. US1 still works on its own.

---

## Phase 5: User Story 4 - Hand the project to its lead (Priority: P2) — REVERTED 2026-09-19

**Goal**: ~~Every project has a lead agent.~~ **Built, then removed on 2026-09-19** — the UX it sat
on had not settled, and the user asked for it out until the shape of a project page is decided. Every
task below was completed and then reverted; they are the plan for when it comes back.

**Independent Test**: Open a project, tell its lead to get two things done, and confirm it starts two
agents in that project, each with its own instruction, that the user is asked before each one starts,
and that the lead can report what they did and stop one of them.

**⚠️ Order matters here**: the guards (T035–T036) land before anything a runtime can call (T038), and
that lands before anything it can change (T041). A half-guarded lead is worse than no lead.

### Tests for User Story 4

- [X] T032 [P] [US4] Write `Unit/AgentRoleTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/`: a record with no `role` key decodes as `.worker`; an unrecognised role decodes as `.worker`; a round trip keeps unknown fields.
- [X] T033 [P] [US4] Write `Integration/LeadLazyStartTests.swift`: a project listed but never prompted has a lead record and no runtime and no session; the first prompt starts one through `liveSession(for:)`.

### The lead exists, with no powers at all

- [X] T034 [US4] Create `AgentRole` in `Packages/AgentsKit/Sources/AgentsKit/Model/AgentRole.swift` (`worker`, `lead`) and add `role: AgentRole` to `Agent` in `Packages/AgentsKit/Sources/AgentsKit/Model/Agent.swift` — decoded with `decodeIfPresent` defaulting to `.worker`, added to `CodingKeys`, encoded only when `.lead`, so every record written by 001 through 003 loads unchanged.
- [X] T035 [US4] Create the lead in `allProjects(...)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift` when a project has no agent with `role == .lead`: an `Agent` with the project's folder as `cwd`, `role: .lead`, no `runtimeSessionID`, `state: .stopped`, `endedReason: .endTurn`, saved and broadcast as `agent/changed`. Nothing is started and nothing is spent (depends on T013, T034).
- [X] T036 [US4] Add `leadID: UUID` and `leadNeedsInput: Bool` to `ProjectSummary` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonAPI.swift`, and exclude the lead from `counts` so the three groups are workers only (depends on T010, T035).
- [X] T037 [US4] Add `lead(of:)` to `App/Sources/AppModel.swift` and filter `workers(in:group:)` to `role == .worker`, then pin the lead above "Needs input" in `App/Sources/Projects/ProjectAgentsView.swift` via a new `App/Sources/Projects/LeadRow.swift`, with a rule under it and no archive action in its menu (FR-043, FR-046) (depends on T016, T020, T036).
- [X] T038 [US4] Select the project's lead when a project is selected in `App/Sources/AppModel.swift`, so picking a folder opens the conversation about that folder (FR-044), and include `leadNeedsInput` in the sidebar mark in `App/Sources/Projects/ProjectRow.swift` (FR-045) (depends on T018, T037).

### The guards, before there is anything to guard

- [X] T039 [P] [US4] Create `ProjectToolGuards` in `Packages/AgentsKit/Sources/AgentsKit/MCP/ProjectToolGuards.swift`: four pure checks over records — a tool may only ever create `.worker`; a named agent must share the caller's `cwd`; `stop_agent` refuses the caller's own id; only an agent with `role == .lead` may be given the `project` server (depends on T034).
- [X] T040 [P] [US4] Write `Unit/ProjectToolGuardsTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/` exercising each guard's refusal and its one allowed case, with the refusal wording from `contracts/agent-tools.md`.

### The server, reads only

- [X] T041 [US4] Create `MCPServer+Project.swift` in `Packages/AgentsKit/Sources/AgentsKit/MCP/` defining the five tools and their JSON schemas exactly as `contracts/agent-tools.md` states: `list_agents`, `start_agent` (`runtime` optional, `instruction`, `title` optional), `prompt_agent` (`agent`, `text`), `read_transcript` (`agent`, `limit` optional, `before` optional), `stop_agent` (`agent`, `reason` optional).
- [X] T042 [US4] Create `ProjectToolService` in `Packages/AgentsKit/Sources/AgentsKit/MCP/ProjectToolService.swift` implementing `list_agents` and `read_transcript` only: scope-checked through `ProjectToolGuards`, served without a permission question because they are reads, each recorded in the lead's transcript (depends on T039, T041).
- [X] T043 [US4] Add an `mcp --agent <uuid>` mode to `Daemon/Sources/main.swift` that speaks MCP over stdio, resolves the daemon socket the way `DaemonClient` does, and proxies each tool call to the daemon — holding no state and deciding nothing (depends on T041).
- [X] T044 [US4] Attach the `project` MCP server to a lead's `mcpServers` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift` when the lead record is made — `.stdio` transport, the bundled `agentsd` path, args `["mcp", "--agent", id]` — and only for `role == .lead` (depends on T035, T039, T043).

### The permission, then the tools that change things

- [X] T045 [US4] Add the held permission to `Packages/AgentsKit/Sources/AgentsKit/MCP/ProjectToolService.swift`: a changing tool raises an ordinary `PermissionRequest` through the existing `pendingPermissions` surface, waits for `permissions/answer`, then does the work or returns a refusal as the tool's result. "Always" is remembered per project and per tool and is not asked again (FR-039, FR-040) (depends on T042).
- [X] T046 [US4] Implement `start_agent` in `Packages/AgentsKit/Sources/AgentsKit/MCP/ProjectToolService.swift` behind the permission: always `role: .worker`, in the project's folder, with no `project` server attached, refusing a missing folder or an unavailable runtime with the same words the user would get (depends on T045).
- [X] T047 [US4] Implement `prompt_agent` in `Packages/AgentsKit/Sources/AgentsKit/MCP/ProjectToolService.swift` behind the permission, appending to that agent's existing prompt queue so it waits its turn, and refusing an archived agent (depends on T045).
- [X] T048 [US4] Implement `stop_agent` in `Packages/AgentsKit/Sources/AgentsKit/MCP/ProjectToolService.swift` behind the permission, stopping exactly as `agents/stop` does, refusing the caller's own id, and telling the lead plainly when the agent has already settled rather than failing (depends on T045).
- [X] T049 [US4] Record every tool call in the lead's transcript in `Packages/AgentsKit/Sources/AgentsKit/MCP/ProjectToolService.swift`, including the ones the user declined (FR-042) (depends on T045).

### Archiving, with the lead carried along

- [X] T050 [US4] Refuse `agents/archive` for an agent whose `role` is `.lead` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, with "The project lead is archived with its project." (FR-046) (depends on T034).
- [X] T051 [US4] Carry the lead in `archiveProject(_:)` and `unarchiveProject(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift`: its state moves to `.archived` with the project and back again, its transcript untouched, and a lead with a turn in flight blocks the archive and is named as "the project lead" (FR-047, FR-048) (depends on T026, T035).

### Proving it

- [X] T052 [P] [US4] Write `Integration/ProjectLeadTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/`: each guard refuses; a held permission allowed does the work; declined returns a refusal the lead can read and does not stall it; "always" is not asked twice; every call lands in the transcript either way.
- [X] T053 [P] [US4] Write `Integration/LeadArchiveTests.swift`: a working lead blocks project archiving and is named; archive and unarchive carry the lead and keep its transcript; `agents/archive` refuses a lead.
- [X] T054 [P] [US4] ~~Extend `FakeACPAgent.swift` so the fake agent can call a named MCP tool.~~ **Not needed, and not done.** The premise was wrong: the MCP helper is a pipe that decides nothing, so driving it through a fake runtime would test the pipe rather than the rules. `Integration/ProjectLeadTests.swift` calls `DaemonCore.callLeadTool` directly, which is where every guard, every permission and every refusal actually lives.
- [X] T055 [P] [US4] Write `Live/LeadRuntimeTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/`, gated on `AGENTS_LIVE=1`, recording which runtimes ask their own MCP permission question on top of ours (research §12).

**Checkpoint**: A project can be handed a goal. US1 and US2 still work on their own.

---

## Phase 6: User Story 3 - Look back at agents you archived (Priority: P3)

**Goal**: See a project's recently archived agents, ten at a time, and read them.

**Independent Test**: Archive several agents in one project, turn on the archived list, confirm the
most recently archived are shown newest first, ask for more, and confirm the rest arrive.

### Implementation for User Story 3

- [X] T056 [US3] Add the archived disclosure below the three groups in `App/Sources/Projects/ProjectAgentsView.swift`, listing `AgentGroup.archived` agents ordered by `lastActivityAt` descending — which for an archived agent is when it was archived (research §2) (depends on T020).
- [X] T057 [US3] Show ten at a time in `App/Sources/Projects/ProjectAgentsView.swift` with a "Show more" that raises the count by ten, and no "Show more" once every archived agent in the project is listed (FR-029, FR-030) (depends on T056).
- [X] T058 [US3] Persist the disclosure's open state to `UserDefaults` under `showsArchivedAgents` in `App/Sources/Projects/ProjectAgentsView.swift` (FR-032) (depends on T056).
- [X] T059 [US3] Say plainly that there is nothing archived, rather than showing an empty box, when the disclosure is opened on a project with no archived agents in `App/Sources/Projects/ProjectAgentsView.swift` (depends on T056).

**Checkpoint**: All four stories work independently.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T060 [P] Add the accessibility pass from `contracts/ui.md` across `App/Sources/Projects/`: group headings are headings, a row that needs the user says so in its label, and the lead's pinned row is announced as the project lead.
- [X] T061 [P] Confirm `swift test --package-path Packages/AgentsKit` is green, including every suite added here.
- [ ] T062 Walk `specs/004-project-focused-ui/quickstart.md` end to end on a Debug build, including the edges: a moved folder, two folders called `api`, a nested folder, and the lead's three refusals. **Partly done.** The Debug build was launched and ran: the daemon came up, the window opened, projects were derived from the real store, and each got a lead. The rest is clicking, which needs a person at the machine. The edges are all covered by tests.
- [X] T063 Check SC-007 and SC-010 against a Debug build. **SC-010 verified**: after launch, all three leads the app created were `stopped` with no `runtimeSessionID`, and no runtime process belonged to one. **SC-007 not measured** — no project on this Mac has 200 agents, so there was nothing to time.
- [X] T064 Update `README.md` to describe the window as projects and their agents rather than a list of agents.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: needs Setup. Blocks every story.
- **US1 (Phase 3)**: needs Foundational. Blocks US2, US3 and US4 — they all draw in the panel or the
  sidebar it builds.
- **US2 (Phase 4)** and **US4 (Phase 5)**: both need US1, and are independent of each other.
- **US3 (Phase 6)**: needs US1 only.
- **Polish (Phase 7)**: needs whichever stories are being shipped.

### Within User Story 4

The order inside Phase 5 is not a preference. T039 and T040 — the guards and their tests — land before
T041 to T044, which are the first point a runtime can call code we wrote. Those land before T045 to
T049, which are the first point it can change anything.

### Parallel Opportunities

- **Phase 2**: T003, T005, T007 and their tests T004, T006, T008 are six files with no shared
  dependencies — all parallel. T009 and T010 follow.
- **Phase 3**: T011 and T012 in parallel; T018 in parallel with T013 to T017.
- **Phase 5**: T032 and T033 in parallel; T039 and T040 in parallel; the four proving tasks T052 to
  T055 in parallel once T049 is done.
- **Phase 7**: T060 and T061 in parallel.
- **Across stories**: once US1 is done, US2, US3 and US4 can be worked in parallel by different people.

---

## Parallel Example: Phase 2

```bash
# Six files, no shared dependencies:
Task: "Create AgentGroup in Packages/AgentsKit/Sources/AgentsKit/Model/AgentGroup.swift"
Task: "Write Unit/AgentGroupTests.swift"
Task: "Create ProjectNaming in Packages/AgentsKit/Sources/AgentsKit/Model/ProjectNaming.swift"
Task: "Write Unit/ProjectNamingTests.swift"
Task: "Create Project in Packages/AgentsKit/Sources/AgentsKit/Model/Project.swift"
Task: "Write Unit/ProjectTests.swift"
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1: Setup.
2. Phase 2: Foundational.
3. Phase 3: User Story 1.
4. **Stop and validate**: walk quickstart scenario 1. The app is project-focused, nothing archives,
   there is no lead. That is a shippable window.

### Incremental delivery

1. Setup + Foundational → the kit knows what a project is.
2. + US1 → project-focused window. **MVP.**
3. + US2 → the sidebar can be kept short.
4. + US4 → a project can be handed a goal. The largest piece, and the one with the guards.
5. + US3 → archived agents readable again.

### Notes

- `[P]` means different files and no dependency on anything incomplete.
- Commit after each task or logical group.
- Stop at any checkpoint: every story is independently testable and independently shippable.
- The two tests that carry this feature are T004 (grouping is total) and T040 (the guards refuse).
  Neither is optional.
