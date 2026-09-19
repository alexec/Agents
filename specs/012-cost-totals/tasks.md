---
description: "Task list for Cost Totals"
---

# Tasks: Cost Totals

**Input**: Design documents from `/specs/012-cost-totals/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included. A total that is quietly wrong looks exactly like a total that is right — there is no crash, no empty state and nothing to click on, and the first person to notice is the one reconciling against an invoice. Money is also the one thing that cannot be validated by trying it: `FakeACPAgent.Script.usage` carries a `cost` block, which is how every case below is exercised without spending anything. [quickstart.md](./quickstart.md) names them all.

**Organization**: Grouped by user story, in the priority order the spec sets. Each phase is shippable without the next.

**The one thing to understand before starting**: this feature adds no daemon method, no notification, no store and no persisted field. Both totals are sums over `Agent.costToDate`, which already exists and is already written to disk. `allProjects()` already groups every agent by folder, and `changed(_:)` already broadcasts the recomputed summary immediately after a cost is banked. **Any task that adds a `cost/*` method, writes a JSON file, caches a total, or stores "how much has this project spent" has misread the plan** — see [research.md §1, §2, §10](./research.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US3)

## Path Conventions

An existing Swift package plus a macOS app and an iOS remote. The line between the two source roots is the one `Package.swift` already draws:

- `Packages/AgentsKit/Sources/AgentsKitCore/` — everything both platforms can hold. No `Process`, no PTY, no file system.
- `Packages/AgentsKit/Sources/AgentsKit/` — the Mac's half: the daemon and the stores.
- `App/Sources/` — the SwiftUI Mac app. Globbed by `project.yml`, so a **new folder needs `xcodegen generate`**.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration}/` — Swift Testing (`import Testing`).

No file under `Remote/Sources/` is touched: the phone is out of scope, and every rule is put in Core so it can adopt them later without the daemon changing.

---

## Phase 1: Setup (Baseline)

**Purpose**: Establish that cost already flows end to end before anything is built on it, so a break in the existing path is visible rather than blamed on this feature.

- [X] T001 Run `swift test --package-path Packages/AgentsKit --filter TurnUsage` and confirm the existing test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/TurnUsageTests.swift` passes. It is the only test in the repository that asserts a turn's cost is banked into `costToDate`, and it is the input to every figure this feature shows. If it fails, stop — nothing below can be correct
- [X] T002 Read `allProjects(includeArchived:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift` and `changed(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` end to end before editing either. `allProjects` already does the grouping (`Dictionary(grouping: agents.values) { Project.standardize($0.cwd) }`) and already walks each folder's agents to build `counts` — that loop is where the project total goes. `changed(_:)` already ends with `projectChanged(forAgentIn: agent.cwd)`, and `finishTurn` calls it on the line straight after banking the cost, which is why this feature needs no notification of its own
- [X] T003 Confirm the fake runtime can report money: check that `FakeACPAgent.Script.usage` in `Packages/AgentsKit/Tests/AgentsKitTests/Fake/FakeACPAgent.swift` carries a `cost` dictionary through to `TurnUsage.cost`. Every integration test below is vacuous without it, and a vacuous cost test passes silently. Also confirm the *absence* of `cost` survives — usage with no price is the case `isUnmeasured` exists to name

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The one rule and the two fields that both user stories read. Small, and everything depends on it.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T004 [P] Create `Packages/AgentsKit/Sources/AgentsKitCore/Model/Spending.swift` containing, for now, only `public extension Agent { var isUnmeasured: Bool }` returning `lastTurnUsage != nil && costToDate.isEmpty`. Document the three cases it separates verbatim from [data-model.md](./data-model.md): never finished a turn (`lastTurnUsage` nil → false, nothing has happened yet); ran and was priced (→ false); **ran and the runtime reported no price (→ true, unmeasurable, not free)**. Add a doc comment saying this is computed and must never become stored state, following `Usage.isCloseToFull` and `AgentGroup(for:)`. The file is separate from `Usage.swift` deliberately: `Usage` and `Cost` are what a runtime reported about one agent, `Spending` is what a reader is owed about all of them
- [X] T005 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/SpendingTests.swift` covering `isUnmeasured` alone for now, exhausting the three-row table in [data-model.md](./data-model.md): `lastTurnUsage` nil and `costToDate` empty → false; `lastTurnUsage` set and `costToDate` non-empty → false; `lastTurnUsage` set and `costToDate` empty → true. Follow the exhaustive style of `Unit/AgentGroupTests.swift`. Depends on T004
- [X] T006 Add two fields to `DaemonAPI.ProjectSummary` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, per [contracts/daemon-api.md](./contracts/daemon-api.md): `public var costToDate: [String: Decimal]` documented as "What every agent in this folder has spent over its whole life, per currency. **Empty when nothing has been spent**, which is how a view knows to show no figure rather than a zero"; and `public var unmeasuredAgents: Int` documented as "How many agents here finished a turn the runtime would not price. **Zero in the ordinary case; non-zero means `costToDate` is a floor rather than the whole.**" Default both in the memberwise initialiser (`[:]` and `0`) and decode both with `decodeIfPresent ?? default`, so an old daemon's response degrades to silence rather than to a wrong number. Model the documentation on the existing `counts`, which is likewise computed per call and never stored
- [X] T007 Fill the two new fields inside the **existing** per-folder loop in `allProjects(includeArchived:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift` — the same `for agent in inFolder` pass that builds `counts`. Accumulate `costToDate[currency] += amount` per currency across every agent in `inFolder`, and count `agent.isUnmeasured`. Do **not** filter by state, group, or archived flag: the daemon holds every agent there has ever been (`AgentStore.loadAll`), and including all of them is exactly what makes archiving change no total. Do not add a second pass and do not add a cache. Depends on T004, T006

**Checkpoint**: Every project's total is on the wire and live, because `changed(_:)` already broadcasts it. Nothing is visible yet.

---

## Phase 3: User Story 1 — What has this project cost? (Priority: P1) 🎯 MVP

**Goal**: One figure on the project page saying what that project has cost, including its ended and archived chats, following spend as it arrives.

**Independent Test**: Open a project with several agents, some finished and some archived. Read one figure off the project page. Add up by hand what each of its chats says it cost and confirm the two agree.

### Tests for User Story 1

- [X] T008 [US1] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ProjectsTests.swift` with the content of a summary's total, driving `DaemonCore` against a temporary root: two agents in one folder each running a priced turn → the folder's `costToDate["USD"]` is the sum of both agents'; **archiving one agent leaves the total unchanged** (this is SC-005 and the assertion most likely to catch a future regression, because archiving is the one operation that visibly removes an agent from a page); ending an agent leaves it unchanged; a `GBP` turn beside a `USD` one produces exactly two keys with the right amounts and no third (SC-006 — nothing converted, nothing combined); a turn with usage but no `cost` gives `unmeasuredAgents == 1` and **does not** add a zero entry to `costToDate`; a folder where an agent was started but no turn has finished gives empty `costToDate` and `unmeasuredAgents == 0`. Depends on T007
- [X] T009 [US1] Add one more case to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ProjectsTests.swift`: capture the `project/changed` notification produced by a priced turn and assert the total is on it. This is FR-005, and it is the assertion that documents why the feature needs no notification of its own — if it ever fails, someone has moved the cost banking out from under `changed(_:)`. Same file as T008, so not parallel with it. Depends on T008

### Implementation for User Story 1

- [X] T010 [US1] Add the total to `heading` in `App/Sources/Projects/ProjectAgentsView.swift`, as a caption in the existing `VStack(alignment: .leading, spacing: 4)` under the project name, in the slot beside the folder-is-gone warning. Render `Cost.total(of: summary.costToDate)` — **when it returns nil, show nothing at all, not a zero** (FR-004); that nil is the existing signal `ContextMeter` already relies on. Name the period in the caption (e.g. `£201.40 all time`) rather than showing a bare figure: FR-022 requires that it cannot be mistaken for the sidebar's "This session" total. Append the unmeasured note when `summary.unmeasuredAgents > 0`, so the figure reads as a floor (FR-006). Use `.font(.callout)` and `.foregroundStyle(.secondary)` to match the sibling warning line, and `.lineLimit(1)`. Do not change the page's layout or its 144pt gutter. Depends on T006
- [X] T011 [US1] Add `.help(…)` and an `.accessibilityLabel(…)` to the caption from T010 saying in words what it counts — what this project has cost in total, across every chat including archived ones — following the pattern in `ProjectRow.accessibilityLabel`, whose comment notes that a visual signal "is not something VoiceOver can read". Same file as T010. Depends on T010
- [X] T012 [US1] Validate Story 1 by hand per [quickstart.md](./quickstart.md): open a project and read the line under its name; send a prompt and watch the figure move **without leaving the page**; archive a chat and watch the figure **not** move; open a project nothing has ever run in and confirm there is no line at all

**Checkpoint**: Shippable. The project page answers "what has this work cost" without opening a chat. The Spending window does not exist yet and is not needed.

---

## Phase 4: User Story 2 — What has all of it cost? (Priority: P2)

**Goal**: A Spending window whose first line is the grand total and whose body is every project's share, largest first, each figure matching that project's own page.

**Independent Test**: Spend in two or three projects. Open the new window. Confirm the grand total is there, that each project is listed with its own figure, that those figures are the same ones the project pages show, and that they add up to the grand total exactly.

### Implementation for User Story 2

- [X] T013 [US2] Extend `Packages/AgentsKit/Sources/AgentsKitCore/Model/Spending.swift` with `public struct Spending: Sendable` built from `[DaemonAPI.ProjectSummary]`, per [data-model.md](./data-model.md): `grandTotal: [String: Decimal]` (every project's `costToDate` added **per currency**, empty when nothing has ever been spent); `currencies: [String]` (codes with any spend, in code order); `func shares(in currency: String) -> [Share]` (every project with spend in that currency, **largest first**); `unmeasuredAgents: Int` (summed across projects); `isEmpty: Bool`. `Share` carries `folder`, `name`, `isArchived` and `amount`. Nothing filters archived projects or missing folders. A project with empty `costToDate` appears in no share list and contributes nothing. **Nothing in this type converts or adds across currencies** — `grandTotal` is a dictionary, never a number
- [X] T014 [US2] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Unit/SpendingTests.swift` with `Spending`, no daemon, hand-built summaries. **Write the invariant test first**: for every currency, the `shares` sum exactly to `grandTotal` (FR-011). Then: shares come back largest first within a currency; two currencies each order independently and no figure crosses between them; a project with empty `costToDate` is in no share list; archived projects and projects with `exists: false` **are** listed and carry `isArchived`; `unmeasuredAgents` is the sum across projects; nothing spent anywhere gives `isEmpty == true` with empty `grandTotal` and `currencies`. The invariant holds by construction today — see [research.md §3](./research.md) — and the test exists because it is exactly what a later feature would break silently by filtering `allProjects()` before totalling. Depends on T013
- [X] T015 [US2] Create `App/Sources/Spending/SpendingView.swift` reading `Spending(model.projects)` from the `AppModel` in the environment. The grand total is the first thing on the page. Beneath it, the shares: **one section per currency, ordered within it, and with a single currency one plain list and no section heading** ([research.md §9](./research.md)). Format every figure through `Cost.total(of:)` so the window and the project page cannot word the same number differently. When `spending.isEmpty`, say so in a sentence rather than drawing a row of zeroes (FR-017). The view is **read-only**: no button on it starts, stops, archives or deletes anything (FR-019)
- [X] T016 [US2] Add a second scene to `App/Sources/AgentsApp.swift`: `Window("Spending", id: "spending") { SpendingView().environment(model) }`. It shares the single `AppModel` created as `@State` on the `App`, which is what makes its figures move in step with the main window and needs no fetch of its own. Add a menu item that opens it, beside the existing `CommandGroup(after: .toolbar)`. Because the main window is never navigated away from, FR-018 — leaving the page returns you to what you were looking at — is satisfied with no state to unwind
- [X] T017 [US2] Make `SessionSpend` in `App/Sources/Projects/ProjectListView.swift` the way in: wrap its existing row in a button that calls `openWindow(id: "spending")` via `@Environment(\.openWindow)`, keep it as a `safeAreaInset`, and use `.buttonStyle(.plain)` so it still reads as a status line rather than growing chrome. **Change its text as little as possible** — `010-cost-limits` replaces what this line *says* and 012 only changes what it *does*; see [research.md §8](./research.md). Update its `.help` to mention that it opens Spending
- [X] T018 [US2] Run `xcodegen generate` — `App/Sources/Spending/` is a new folder and `project.yml` globs the source roots, so the file is not in the project until this runs — then `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build`. Depends on T015, T016, T017
- [X] T019 [US2] Validate Story 2 by hand per [quickstart.md](./quickstart.md): spend in two or three projects; open Spending from the money line **and** from the menu item; confirm the grand total is first, every spending project is listed biggest first, and **each listed figure equals what that project's own page shows** (SC-004); add the shares up on paper and confirm they equal the grand total (SC-003); leave the window open, send a prompt, and watch both the grand total and that project's line move (FR-016); close it and confirm the main window is on exactly the project and chat you left it on (FR-018) — **Partly validated**: grand total first, sections ordered biggest first, `api`'s $18.00 matches its own page (SC-004), shares add to the grand total (SC-003), and the menu route all confirmed against a seeded throwaway root. **Not validated**: the money-line route and the live-follow (FR-016), both of which need a real priced turn — `SessionSpend` only renders once something has been spent in the sitting.

**Checkpoint**: Shippable. Both totals exist and agree with each other.

---

## Phase 5: User Story 3 — The total is the whole bill, and says so when it is not (Priority: P3)

**Goal**: Make the totals trustworthy — the archived half of the work counted and marked, and the unmeasurable part admitted rather than hidden inside a figure that looks complete.

**Independent Test**: Spend in a project, archive an agent in it, then archive the project. Start an agent in a folder that is not a project at all and let it spend. Confirm the grand total has not moved down at any point, that the archived project is still named and marked as archived, and that spend belonging to no project is accounted for.

### Implementation for User Story 3

- [X] T020 [P] [US3] Mark archived projects in the share list in `App/Sources/Spending/SpendingView.swift`, reading `Share.isArchived`. They are listed with their spend like any other — nothing filters them — and it is evident which they are (FR-013). Follow the wording and the `.foregroundStyle(.secondary)` treatment of `ArchivedProjectRow` in `App/Sources/Projects/ProjectListView.swift` so the two surfaces describe an archived project the same way
- [X] T021 [US3] Add the unmeasured line to `App/Sources/Spending/SpendingView.swift`: when `spending.unmeasuredAgents > 0`, say how many agents could not be measured, so the grand total reads as a floor rather than as the whole (FR-015, SC-008). Say nothing at all when the count is zero. Same file as T020. Depends on T020
- [X] T022 [P] [US3] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ProjectsTests.swift`: archiving a whole **project** leaves its `costToDate` unchanged and leaves it present in `allProjects(includeArchived: true)`; an agent started in a folder that was never added as a project produces a derived project carrying that agent's spend, so no penny falls outside the union (this is the test that discharges FR-012 — see [research.md §3](./research.md); **do not build an "Other" row**, the category cannot be populated); a project whose folder no longer exists still reports its spend with `exists: false`. Depends on T008
- [X] T023 [US3] Validate Story 3 by hand per [quickstart.md](./quickstart.md), watching the grand total after each step and confirming **it never falls**: spend in a project; archive a chat; archive the project; start an agent in a folder never added as a project and let it spend; delete the project's folder from disk; run an agent on a runtime that reports no cost. Then restart — `pkill -f 'agentsd.*<your test root>'`, reopen against the same root — and confirm every total is exactly what it was (SC-007, FR-020), which works because this feature wrote nothing and the agent records did

**Checkpoint**: All three stories are independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T024 [P] Two currencies, end to end by hand: script a `GBP` turn beside a `USD` one and confirm the project page shows two figures and the Spending window shows two sections, and that **no surface anywhere shows one combined number** (SC-006). This is the requirement most easily lost during UI work and the one the app cares most about
- [X] T025 [P] Confirm nothing this feature added is reachable by an agent: grep `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift` and the MCP tool surface for any new entry. There should be none to find, because the feature adds no daemon method at all — record that as the verification of FR-019 and SC-010
- [X] T026 [P] Check SC-009 with a populated root: open Spending against a root with a large number of agent records and confirm it appears with its figures filled in without a visible wait. If it does not, the cause is the daemon's existing startup decode, not this feature — do **not** respond by adding a cache ([research.md §10](./research.md))
- [X] T027 Re-read the diff against the rule at the top of this file: no new `cost/*` method, no new notification, no new file at the daemon root, no new field on `Agent`, no cached or stored total. If any appeared, it was not needed
- [X] T028 Run the whole suite — `swift test --package-path Packages/AgentsKit` — and the full quickstart pass in [quickstart.md](./quickstart.md) ("The whole feature, in one pass") — **Suite: 702 tests in 83 suites, all passing.** The quickstart's hand pass was done against a seeded throwaway root rather than by spending; the two steps that need a real priced turn are noted on T019.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies; T001–T003 are reads and a test run and can be done in any order
- **Foundational (Phase 2)**: depends on Setup. **Blocks both user stories** — T006 and T007 are what put a total on the wire at all
- **US1 (Phase 3)**: depends on Phase 2 only
- **US2 (Phase 4)**: depends on Phase 2 only. Independent of US1 in code — it reads `ProjectSummary.costToDate`, not anything US1 built — though shipping US1 first is what makes SC-004's cross-check meaningful
- **US3 (Phase 5)**: T020 and T021 depend on US2's view existing; T022 depends only on US1's test file
- **Polish (Phase 6)**: after the stories you intend to ship

### Within the foundational phase

```text
T004 (isUnmeasured) ──┬── T005 (its unit test)
                      └── T007 (fills unmeasuredAgents)
T006 (ProjectSummary fields) ── T007
```

T004 and T006 are in different files and different packages and can be done in parallel. T007 needs both.

### Parallel opportunities

- **Phase 2**: T004 and T006 together, then T005 and T007 together
- **Phase 3**: none — T008 and T009 are the same test file, T010 and T011 the same view
- **Phase 4**: T013 (Core) can go alongside T015/T016/T017 (app) once T006 is in, but T018's build gates all of them
- **Phase 5**: T022 (tests) runs alongside T020/T021 (view)
- **Phase 6**: T024, T025 and T026 are independent

```text
Phase 2, in parallel:
T004  Agent.isUnmeasured in Spending.swift
T006  ProjectSummary + costToDate, unmeasuredAgents

Phase 6, in parallel:
T024  Two currencies by hand
T025  Out of agents' reach
T026  SC-009 with a populated root
```

---

## Implementation strategy

### MVP (User Story 1 only)

1. Phase 1 → Phase 2 → Phase 3. Seven implementation tasks, two of them one-line.
2. **Stop and validate**: open a project, read what it has cost, archive a chat, watch the figure hold.
3. This alone answers the question the app could not answer at all — what this piece of work has cost — without a new window, a new command, or a byte written to disk.

### Incremental

1. Setup + Foundational → every project's total is on the wire and live, invisible.
2. US1 → the project page answers for itself. Ship.
3. US2 → the grand total, and where it went. Ship.
4. US3 → the totals become trustworthy rather than merely readable. Ship.
5. Phase 6 before calling any of it done.

### Notes

- Commit after each task or logical group.
- The seam with `010-cost-limits` is one view — `SessionSpend` in `ProjectListView.swift`. 010 changes what it says; 012 changes what it does. Whichever lands second inherits the other's version, and neither should rewrite the other's half.
- Avoid: storing or caching a total; adding a `cost/*` daemon method; building an "Other" row for spend that belongs to no project; comparing or adding two currencies; showing a zero where nothing has been spent; putting any of this within reach of an agent.
