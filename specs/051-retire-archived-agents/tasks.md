# Tasks: Retire Archived Agents

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/daemon-api.md](contracts/daemon-api.md),
[quickstart.md](quickstart.md)

**Tests**: Included. Retirement deletes things the person cannot get back, so every rule gets a
test written before the code that makes it pass. Pure rules go in `Pkg/Tests/AgentsKitTests/Unit/`.
Daemon behaviour goes in `Pkg/Tests/AgentsKitTests/Integration/`, modelled on `ParkingTests.swift`
and `LeaseTests.swift`, which build a `DaemonCore` on a temporary root with an injected `now`
and restart it on the same root.

**Where**: Everything runs in `.agents/worktrees/051-retire-archived-agents` on branch
`agents/write-spec-spec-only`. Never edit the shared checkout. `Pkg/` means `Packages/AgentsKit/`.
Scratch roots are `/tmp/run-051*`. Never touch `~/Library/Application Support/Agents` or its
`daemon.sock`, and stop scratch daemons by the pid in their own `daemon.lock`.

**Rules this feature must keep**:
- Only archived agents are ever retired. None is retired within 24 hours of archiving (FR-005, FR-006).
- The tombstone is written and synced before anything is deleted, and an interrupted retire is finished at the next start (FR-017).
- A slim agent never reaches `agent.json` (research R2).
- The only files deleted are the agent's own directory and an app-made worktree that archiving's rule would remove. Runtime files, `events.jsonl`, `spend.json` and other agents are never touched (FR-019).
- Older phones must keep decoding `Agent` and `ProjectSummary`. Only optional fields are added (research R9).
- The words live in `RetirementWords`, and the Mac and the phone call the same functions.
- There is no per-agent pin (spec, Clarifications).

**Order**: Foundational first: the pure rules and the files. Then a **look gate**. The Settings
section, the row notes, the retired line and the retired page are built against hand-written
`retention.json`, `retired.jsonl` and `retirement` values on a scratch root, and screenshotted
for Alex before any retiring code runs (the rule: settle the UX before building depth). After
that come US1 (the MVP), US2, US3, US5, US4, US6 and US7.

---

## Phase 1: Setup

- [X] T001 Merge `main` into `agents/write-spec-spec-only` in this worktree. Verify with `git merge-base --is-ancestor main HEAD`, not by trusting the merge output. Conflicts should only be in `specs/`.
- [X] T002 Record the baseline: run `swift test` in `Pkg/` twice and write down in `specs/051-retire-archived-agents/walk/README.md` which tests fail before any change. The suite is flaky under load, so a later failure is this lane's only if it is new, and only after six runs on both commits.
- [X] T003 [P] Capture a fixture of a real-sized archived record: copy one `agent.json` from a scratch Claude agent (not the real store) into `Pkg/Tests/AgentsKitTests/Fixtures/archived-agent.json`, with its `advertisedOptions` and `availableCommands` intact and its title and paths replaced with neutral ones.
- [X] T004 [P] Write `scripts/seed-archived.swift`, a `swift` script. Flags: `--root`, `--count N`, `--archived-days-ago D`, `--transcript-bytes B`, `--legacy` (no `archivedAt`), `--live` (state `finished`, not archived), `--project <folder>`. It writes `agents/<id>/agent.json` from the T003 fixture with a fresh id and dates, and a `transcript.jsonl` of B bytes of valid entries. It prints the ids. It refuses any `--root` under `~/Library`.

---

## Phase 2: Foundational (blocks every story)

This phase adds the pure rules, the types, the files and the wire shapes. Nothing behaves
differently yet.

### Tests first

- [X] T005 [P] Write `Pkg/Tests/AgentsKitTests/Unit/RetentionPlanTests.swift` against the R5 rules, with `now`, `saneNow`, sizes and holds as plain values. It must fail until T011. Cases:
  - off (`forever` with `none`) retires nothing and gives no notes
  - age at 30 days retires, 29 days does not
  - the cap retires oldest `archivedAt` first, with ties to the oldest `lastActivityAt`, until at or under the cap
  - "An agent archived less than 24 hours ago MUST NOT be retired by age, by the cap or by the clock jumping"
  - a held agent is never picked and gets `.held(hold)`
  - a future `archivedAt` counts as now
  - a forward jump of more than a day retires nothing by age until a day of real time has passed
  - the first check after a start uses `min(now, lastCheck + 1 day)`
  - notes: `.at` only within 7 days; `.nextUnderCap` on exactly one agent, and only when a cap is set
  - `overCap` names its holding reasons with counts when stuck over
- [X] T006 [P] Write `Pkg/Tests/AgentsKitTests/Unit/TombstoneTests.swift`:
  - A tombstone built from the T003 fixture keeps exactly the FR-015 fields.
  - Its JSON is under 2,048 bytes with a 200-character title and five currencies.
  - It carries no prompt, transcript, option or credential text.
  - A title longer than 200 characters is truncated.
- [X] T007 [P] Write `Pkg/Tests/AgentsKitTests/Unit/AgentStoreSlimTests.swift`:
  - Saving a slimmed agent leaves `agent.json`'s `advertisedOptions`, `availableCommands` and `plans` as they were on disk.
  - Saving a slim agent whose `agent.json` is missing or unreadable is refused and logged.
  - A whole agent saves as today.
  - `slimmed()` followed by `madeWhole(from:)` round-trips to the original.

### Implementation

- [X] T008 [P] Add to `Pkg/Sources/AgentsKitCore/Model/Agent.swift`:
  - `archivedAt: Date?` and `retirement: Retirement?`, both in `CodingKeys` and read with `decodeIfPresent`.
  - `isSlim: Bool`, kept out of `CodingKeys` like `rawState`, with a comment saying why.
  - `func slimmed() -> Agent`, which empties `advertisedOptions`, `availableCommands` and `plans` and sets `isSlim`.
  - `func madeWhole(from disk: Agent) -> Agent`.
- [X] T009 [P] Create `Pkg/Sources/AgentsKitCore/Model/Retirement.swift`, with every type `Codable, Hashable, Sendable`:
  - `enum Retirement { at(Date), nextUnderCap, held(Hold), unknown(String) }`, encoded as `{ "at": date }`, `{ "nextUnderCap": {} }` and `{ "held": "worktreeHasWork" }`. Anything else decodes to `.unknown`.
  - `enum Hold: String { firstDay, worktreeHasWork, workflowRunning, openInWindow }`.
  - `enum RetiredBecause: String { age, cap, person }`.
  - `struct Tombstone` with exactly the FR-015 fields in data-model.md, and `init(from agent: Agent, host: HostID, retiredAt: Date, because: RetiredBecause)`, which truncates the title to 200 characters.
  - `struct OverCap { bytesOver: Int, holding: [Hold: Int] }`.
- [X] T010 [P] Create `Pkg/Sources/AgentsKitCore/Model/RetentionSettings.swift`:
  - `enum KeepFor: String { days7, days14, days30, days90, forever }`, with `days30` the default and `var interval: TimeInterval?`.
  - `enum Cap: String { gb1, gb2, gb5, gb10, none }`, with `gb2` the default and `var bytes: Int?`, where GB means 1,000,000,000 bytes, as Finder shows it.
  - `struct RetentionSettings { keepFor, cap; var isOff: Bool }`.
  - An unknown raw value decodes to the default, never to `forever` or `none`.
- [X] T011 Create `Pkg/Sources/AgentsKitCore/Model/RetentionPlan.swift`: `struct RetentionPlan` with `static func decide(archived: [Candidate], holds: [UUID: Hold], settings: RetentionSettings, now: Date, saneNow: Date) -> RetentionDecision`. `Candidate` is `{ id, archivedAt, lastActivityAt, sizeOnDisk }`. `RetentionDecision` is `{ retire: [(UUID, RetiredBecause)], notes: [UUID: Retirement?], overCap: OverCap? }`. Also add `static func saneNow(now: Date, lastCheck: Date?, elapsedUptime: Duration?) -> Date`. Follow research R5 rules 1–7 exactly. Make T005 pass.
- [X] T012 [P] Create `Pkg/Sources/AgentsKitCore/Model/RetirementWords.swift` with every function in the contract's Words table. The day counts in `rowNote` round down in the person's calendar, like `LeaseWords.clock`. Add `Pkg/Tests/AgentsKitTests/Unit/RetirementWordsTests.swift`, covering each example sentence in contracts/daemon-api.md verbatim.
- [X] T013 Add the wire shapes to `Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`:
  - Methods: `retentionState = "retention/state"`, `retentionSet = "retention/set"`, `agentsRetire = "agents/retire"`, `agentsRetired = "agents/retired"`.
  - Notifications: `retentionChanged = "retention/changed"`, `agentRemoved = "agent/removed"`.
  - Types: `RetentionState`, `RetentionSetRequest { settings, confirmed }`, `RetentionSetResult { applied, wouldRetire: RetirePreview?, state: RetentionState? }`, `RetirePreview { count, bytes }`, `RetireRequest { agentID, confirmed }`, `RetiredRequest { folder?, ids?, limit? }` (limit defaults to 200, at most 200), `AgentRemovedNotification { agentID }`.
  - `ProjectSummary.retiredCount: Int?`, read with `decodeIfPresent`.
  - `Failure.agentRetired = -32050` and `Failure.retireRefused = -32051`, with comments naming 051.
  - Add all four methods to the role table: the two writes are for `control` only, and the reads for whatever can read `agents/list`. Put them wherever `cost/setLimits` is listed.
- [X] T014 [P] Create `Pkg/Sources/AgentsKit/Store/RetentionStore.swift`, on `LimitStore`'s pattern. It reads and writes `retention.json` as `{ settings, lastCheck: Date? }`: missing means defaults, and unreadable is set aside and means defaults. Add `StoreLocations.retention`.
- [X] T015 [P] Create `Pkg/Sources/AgentsKit/Store/RetiredStore.swift`:
  - `append(_ t: Tombstone) throws` writes one line and calls `fsync` on the handle before returning. It throws if either fails.
  - `loadAll() -> [UUID: Tombstone]` skips a torn last line and counts other unreadable lines into `DaemonLog`, like `EventStore.load`.
  - Add `StoreLocations.retired` (`retired.jsonl`).
  - Test it in `Pkg/Tests/AgentsKitTests/Unit/RetiredStoreTests.swift`: a torn last line, and many appends read back in order.
- [X] T016 [P] Create `Pkg/Sources/AgentsKit/Store/ArchiveIndex.swift`:
  - `struct IndexEntry { agent: Agent (slim), sizeOnDisk: Int, fileModifiedAt: Date }`.
  - `load() -> [UUID: IndexEntry]?` returns nil when the file is missing or unreadable.
  - `save(_:) throws` writes whole and atomically. The file is `{ version: 1, writtenAt, entries }`.
  - `static func sizeOnDisk(_ dir: URL) -> Int` totals the allocated size of the directory's files.
  - Add `StoreLocations.archiveIndex` (`archive.json`).
- [X] T017 Make `AgentStore.save` slim-safe in `Pkg/Sources/AgentsKit/Store/AgentStore.swift`. When `agent.isSlim`, read `agent.json`, call `madeWhole(from:)` and write that. If the read fails, refuse and log, like `refusal(for:)`. Add the invariants "`archivedAt != nil` requires `state == .archived`" and "`retirement != nil` requires `state == .archived`" to `refusal(for:)`, each with a `Mend` that clears the field. Make T007 pass.
- [X] T018 Add `AgentStore.retire(_ id: UUID, tombstone: Tombstone, retiredStore:) throws` to `Pkg/Sources/AgentsKit/Store/AgentStore.swift`. It does these steps in order:
  1. `retiredStore.append`
  2. `closeTranscript`
  3. delete `transcript.jsonl`
  4. delete `agent.json`
  5. remove the directory

  Also add `finishRetiring(ids:)`, which runs steps 2–5 for ids whose directory still exists. Take a `failAfter: Int?` test seam in an internal initializer, so a test can stop after any step. Write `Pkg/Tests/AgentsKitTests/Unit/RetireOrderTests.swift`: for each step, failing after it leaves the agent either whole and loadable, or with a tombstone and removable by `finishRetiring`, never with neither (SC-006).

**Checkpoint**: `swift test --filter 'RetentionPlan|Tombstone|AgentStoreSlim|RetirementWords'` is green, and the full suite shows no new failures against T002.

*Done 2026-09-25, with these changes from the text above:*
- *T011: the clock is its own value, `RetentionClock` (in `RetentionPlan.swift`), and `decide` takes only `saneNow`. See research R5.*
- *T015 and T018: the tombstone-file and retire-order tests live in `AgentStoreSlimTests.swift`.*
- *T017: `save` clears `archivedAt` and `retirement` on an agent that is not archived, instead of refusing it (data-model, Rules).*
- *T018: the record is deleted before the transcript. The step-by-step test showed that the other order leaves a readable agent with an empty conversation.*
- *Full suite: under load average 30 from other sessions there were 87 issues against 11–16 at baseline. Every sampled new failure passes on its own. T061's six-run comparison settles it.*

---

## Phase 3: Look gate: see it before building it (US3, US4 surfaces)

The surfaces are built and fed by hand, before any retiring code, so Alex can judge them.

- [X] T019 [US3] Serve what the surfaces need, read-only, in `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Retention.swift` (new) and `DaemonCore+Dispatch.swift`:
  - Load `retention.json` and `retired.jsonl` at start into `retentionSettings` and `retired`.
  - `retention/state` counts archived agents and totals their sizes by `ArchiveIndex.sizeOnDisk`, per call for now; T039 moves this to the index.
  - `agents/retired`.
  - `ProjectSummary.retiredCount`, with retired costs added to `costToDate` in `DaemonCore+Projects.swift`.

  `retention/set` saves and broadcasts but retires nothing yet.
- [X] T020 [P] [US3] Add an **Archived agents** section to `App/Sources/Settings/AgentsSettingsView.swift`, with its body in a new `App/Sources/Settings/ArchiveSettingsView.swift`:
  - `RetirementWords.settingsSummary`.
  - A **Keep archived agents** picker: 7 days, 14 days, 30 days, 90 days, Forever.
  - A **Up to** picker: 1 GB, 2 GB, 5 GB, 10 GB, No limit.
  - The over-cap sentence when `overCap` is set.
  - A confirm sheet showing `RetirementWords.confirmSettings` when `retention/set` answers `applied: false`.

  Use the section and picker styles already in `AgentsSettingsView`. Nothing is tinted.
- [X] T021 [P] [US4] Add the row note to `App/Sources/AgentList/AgentRow.swift`: when `agent.state == .archived`, show `RetirementWords.rowNote(agent.retirement, now)` as the secondary line, in the style of the existing ended-reason line. Add the same to `Remote/Sources/Projects/AgentCard.swift`.
- [X] T022 [P] [US4] Add the retired line under the Archived section: `RetirementWords.retiredLine(summary.retiredCount)`, in `App/Sources/Projects/SessionsColumn.swift` and `Remote/Sources/Projects/ProjectPageView.swift`. Show it only when the count is above 0, as the last row of the open section.
- [X] T023 [US4] Add the retired page:
  - Create `App/Sources/Chat/RetiredAgentView.swift` and `Remote/Sources/Chat/RemoteRetiredView.swift`. They show the title, "Retired", `RetirementWords.retiredSentence`, the project, the runtime, created and archived dates, cost, "Started by …" when set, and the worktree name and branch when set. Share the body in `Shared/UI/` if both can use it.
  - `AgentsModel` gains `tombstones: [UUID: Tombstone]` and `func tombstone(for id: UUID) async -> Tombstone?`, which calls `agents/retired { ids: [id] }` and caches the answer.
  - In `App/Sources/AppModel.swift`, `openAgent(_:)`, and the chat's view for a selection the model has no agent for, fall back to it.
  - Do the same wherever the phone navigates to an agent by id.
  - `startedByAgentLabel` uses the tombstone title when the starter is retired, adding "(retired)".
- [X] T024 [US4] Seed `/tmp/run-051-look`:
  - Use `scripts/seed-archived.swift` for agents at 25, 27 and 29 days.
  - Write `retirement` values into three records by hand (`.at` 5 days, `.nextUnderCap`, `.held(.worktreeHasWork)`).
  - Write three tombstones into `retired.jsonl`, one of which a live seeded agent names as `startedByAgent`.
  - Write one `events.jsonl` line naming a retired id.
  - Write a `retention.json` with 30 days and 2 GB.

  Launch the scratch app with the run-app skill. Screenshot into `specs/051-retire-archived-agents/walk/look/`:
  - Settings ▸ Agents ▸ Archived agents, and the confirm sheet (set 7 days)
  - the Archived list with notes and the retired line
  - the retired page reached from the event
  - the started-by line

  Build Remote for the generic iOS simulator to prove it compiles.
- [X] T025 [US4] **Look gate**: ask Alex with AskUserQuestion, attaching the screenshots from T024, whether the Settings section, notes, retired line and retired page are right. Change them until he approves. Record the approval in `walk/README.md`. No retiring code is written before this.

---

## Phase 4: User Story 1: Old archived agents go away by themselves (P1) 🎯 MVP

**Goal**: an agent archived 30 or more days ago is retired by itself, a tombstone is left, and
nothing else is touched.

**Independent test**: quickstart §2, the first block.

### Tests for User Story 1

- [X] T026 [P] [US1] Write `Pkg/Tests/AgentsKitTests/Integration/RetirementTests.swift` with an injected `now`. It must fail until T032. Cases:
  - An agent archived 31 days ago is retired at the first check: its directory is gone, a tombstone exists, it is gone from `agents/list`, `agent/removed` is broadcast, and the `agent.retired` event is raised.
  - One archived 29 days ago is kept.
  - A `finished`, a `stopped` and a parked agent 400 days old are kept (FR-005).
  - Unarchive, then archive again, restarts the 30 days (Story 1, scenario 4).
  - A legacy record with no `archivedAt` gets one at first start and is not retired for 30 days (FR-008).
  - Restarting after 31 days retires it soon after start, and `agents/list` answers without waiting on the check.
- [X] T027 [P] [US1] Add to the same file: an agent method on a retired id (`agents/unarchive`, `agents/prompt`, `agents/transcript`, `agents/fork`) fails with `-32050`, and the message is `RetirementWords.retiredSentence` (contracts, Failures).

### Implementation for User Story 1

- [X] T028 [US1] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` (`archive`) and the `move` handling for `.archivedByUser`/`.archivedByAgent`/`.unarchivedByUser`: set `archivedAt = now()` on archive, and clear `archivedAt` and `retirement` on unarchive. Do it in the same `changed` as the state change.
- [X] T029 [US1] In `DaemonCore.loadFromDisk` (`Pkg/Sources/AgentsKit/Daemon/DaemonCore.swift`), set `archivedAt` to the start time for any archived record without one, and save it once (FR-008).
- [X] T030 [US1] In `DaemonCore.loadFromDisk`, **before** filling `agents`, call `store.finishRetiring(ids:)` for ids that are in `retired` and still have a directory, and skip those ids. Log each one.
- [X] T031 [US1] Implement `retire(_ id: UUID, because: RetiredBecause) async throws` in `DaemonCore+Retention.swift`, the one path every retire takes. It follows the data-model "Retire steps" 1–5:
  - The tombstone goes to `retired`.
  - The agent is dropped from `agents` and `lastWhole`.
  - The worktree step reuses `removeWorktreeIfDone`'s facts, but only when no agent that is not archived has the same worktree root (FR-018).
  - `agent/removed` and `project/changed` are broadcast.
  - `raise` is called with `agent.retired`, whose details are `agent`, `agent_title`, `project` and `because`.

  Add `agent.retired` to the catalogue in `Pkg/Sources/AgentsKitCore/Model/EventCatalogue.swift`, with the contract's sentence.
- [X] T032 [US1] Implement the check in `DaemonCore+Retention.swift`:
  1. `startRetentionChecks()`: a detached timer task, like `startPruningEvents`, that checks 30 s after start and hourly after.
  2. `checkRetention()`: builds `Candidate`s from archived agents, computes `saneNow` from `retention.json`'s `lastCheck` and a `ContinuousClock` reading kept in memory, and calls `RetentionPlan.decide` with no holds (holds come in US5).
  3. It calls `retire` for each id in order, and saves notes that changed with `changed(_:)`.
  4. It writes `lastCheck`, and broadcasts `retention/changed` if anything moved.

  Log "retiring <id> (<because>)" to `DaemonLog`. Make T026 pass.
- [X] T033 [US1] Map the retired-id failure: in the dispatch for every method taking an `agentID`, when `agents[id] == nil` and `retired[id] != nil`, throw `-32050` with `retiredSentence`. Put it once, in the helper those methods use to find an agent (`noSuchAgent` today). The same applies to the agent tools that name another agent (`archive_agent`, `stop_agent`, helpers). Make T027 pass.
- [X] T034 [US1] Handle `agent/removed` in `Pkg/Sources/AgentsKitCore/Client/AgentsModel.swift`: remove the agent from `agents`, and if it was selected or watched, clear that so the retired page shows (T023). Add a unit test in `AgentsModelTests.swift`.

**Checkpoint**: quickstart §2's first block passes on a scratch daemon. This is the MVP.

---

## Phase 5: User Story 2: A cap on the space archived agents take (P1)

**Goal**: over the cap, the oldest archived go first until under it. Never on their first day.

**Independent test**: quickstart §2, the Cap bullet.

- [X] T035 [P] [US2] Add to `RetirementTests.swift`, with the cap set to 10 MB and seeded 4 MB agents archived at 10, 9, 8 and 0.5 days:
  - The 10- and 9-day agents are retired, and the 8-day and half-day agents are kept.
  - With every agent under a day old and over the cap, nothing is retired, and `retention/state.overCap` names `firstDay` (FR-013).
  - Live agents' sizes never count.
- [X] T036 [US2] Measure `sizeOnDisk` for each candidate in `checkRetention` with `ArchiveIndex.sizeOnDisk`, off the actor in a detached task. T039 caches it in the index. Pass the cap to `RetentionPlan`. Make T035 pass.
- [X] T037 [US2] Run a check straight after `archive` when the cap is set and the new total may cross it, debounced to at most once a minute, so a heavy archive day does not wait an hour.

---

## Phase 6: User Story 3: Choose how long, or keep them forever (P1)

**Goal**: the person sets the time and the cap, sees what a change would retire and confirms,
and the settings reach every server.

**Independent test**: quickstart §2, the Off bullet, and the Settings screenshots.

- [X] T038 [P] [US3] Add to `RetirementTests.swift`:
  - `retention/set` unconfirmed that would retire 3 answers `applied: false` with the count and bytes, and changes nothing.
  - Confirmed, it retires them and broadcasts `retention/changed`.
  - One that would retire nothing applies at once.
  - `forever` with `none` retires nothing for agents 400 days old and 50 GB total.
  - The settings survive a restart.
  - A device connection is refused `retention/set`.
- [X] T039 [US3] Implement `retention/set` fully in `DaemonCore+Retention.swift`: build the preview by calling `RetentionPlan.decide` with the proposed settings (no holds, so it is an upper bound: say "up to" in the words when holds exist), save, check, broadcast. Make T038 pass.
- [X] T040 [US3] In `App/Sources/AppModel.swift`, add `setRetention(_:confirmed:)`, following `setCostLimits`: after its own daemon applies the settings, call `retention/set { confirmed: true }` on every connected server. In `refreshServer`, push the Mac's settings on connect, the same way limits are pushed. Subscribe to `retention/changed` in `AgentsModel` to keep `retentionState` current.
- [X] T041 [US3] Wire `ArchiveSettingsView` (T020) to `setRetention`. A picker change sends unconfirmed. On `applied: false` it shows the confirm sheet, and Cancel puts the picker back.

---

## Phase 7: User Story 5: Nothing still in use is retired (P2)

**Goal**: work in a worktree, a running workflow, or a window reading the agent keeps it.

**Independent test**: quickstart §2, the Holds bullet.

- [X] T042 [P] [US5] Add to `RetirementTests.swift`, using real `git` repos in the temp root, as `WorktreeTests` do:
  - An archived 40-day agent whose app-made worktree has an uncommitted file is kept, with note `.held(.worktreeHasWork)`. The same is true with commits that are not merged.
  - After commit, merge and removal, it is retired at the next check.
  - A worktree shared with a live agent is not a hold. The agent is retired and the worktree left.
  - A worktree the person made is never removed.
  - A run in `workflowRuns` with this `agentID` holds the agent until the run ends.
  - A presence with `watching == id` holds it.
- [X] T043 [US5] Implement `holds(for candidates:) async -> [UUID: Hold]` in `DaemonCore+Retention.swift`, per research R7:
  - `removalFacts` off the actor, only for candidates.
  - `workflowRuns.values` matched by `agentID` or `triggeringAgentID`.
  - `presences.values` matched by `watching`.
  - `lastWhole` within 10 minutes.

  In `checkRetention`, call `decide` once without holds to find the candidates, then again with their holds. Make T042 pass.

---

## Phase 8: User Story 4: See what is about to go, bring it back in time (P2)

**Goal**: notes on rows, unarchive and branch whole, a retired page for every link.

**Independent test**: the story's own test in spec.md, on a scratch daemon.

- [X] T044 [P] [US4] Add to `RetirementTests.swift`:
  - An archived 27-day agent has `retirement == .at(archivedAt + 30 days)`.
  - Unarchiving clears it and returns the agent whole, with its commands, transcript and options.
  - Branching from an archived agent gives a new agent with its own transcript copy, and retiring the original leaves the branch whole (Story 4, scenarios 3 and 4).
- [X] T045 [US4] Check every place the Mac and the phone lead to an agent by id and make sure each reaches the retired page for a retired id:
  - the event row's ›
  - the event detail
  - "Started by"
  - a workflow's Recent runs row
  - a worktree row's agent
  - a notification tap on the phone

  List them in `walk/README.md` with how each was checked (SC-005).

---

## Phase 9: User Story 6: The daemon stops carrying archived agents (P2)

**Goal**: slim archived agents, one index read at start, let go after reading, and drop live
state on archive.

**Independent test**: quickstart §3, and the map-drop test.

### Tests for User Story 6

- [ ] T046 [P] [US6] Write `Pkg/Tests/AgentsKitTests/Integration/SlimAgentTests.swift`. Cases:
  - After start, archived agents are slim and live ones whole.
  - A presence watching a slim agent makes it whole and broadcasts `agent/changed` with its commands.
  - `agents/transcript`, `unarchive` and `fork` make it whole first.
  - With `now` moved 11 minutes on and no watcher, the sweep slims it again.
  - Changing a slim agent (mark read) saves without losing the lists on disk.
  - `agents/list { archivedCommands: true }` for a slim agent returns empty commands. Record that as expected: the whole record arrives when it is opened.
- [ ] T047 [P] [US6] Write `Pkg/Tests/AgentsKitTests/Integration/ArchiveIndexTests.swift`. Cases:
  - First start with no `archive.json` reads every directory and writes the index.
  - The second start reads only the index. Assert with a counting `AgentStore` seam that archived `agent.json` files are not opened.
  - An index entry whose `agent.json` is newer than `fileModifiedAt` is read in full, and `agent.json` wins.
  - A directory not in the index is read in full and indexed.
  - A corrupt index is rebuilt.
- [ ] T048 [P] [US6] Write `Pkg/Tests/AgentsKitTests/Integration/ArchiveDropsLiveStateTests.swift`. Give an agent entries in every map in data-model.md's "Maps dropped on archive" table, archive it, and assert through `liveStateKeys(for:)` that none has a key for it except `stops`. Archive another mid-turn: the late reply writes nothing to its record or transcript, and no queued prompt is sent (FR-027).

### Implementation for User Story 6

- [ ] T049 [US6] Add `DaemonCore+Hydration.swift`:
  - `makeWhole(_ id:) async` reads `agent.json` through the store and uses `madeWhole(from:)`, then sets `lastWhole[id]`, calls `changed`, and broadcasts.
  - `slimIdle()` runs every 60 s and slims any archived agent with no watching presence and `lastWhole` older than 10 minutes.

  Call `makeWhole` from:
  - the presence handler in `DaemonCore+Attention.swift`, when `watching` names a slim agent
  - `transcript(_:)`
  - `unarchive`
  - `fork`/branch in `DaemonCore+Runtimes.swift`
- [ ] T050 [US6] Slim on archive and at start. At the end of `archive`, after the stop and the worktree step, replace the agent with `slimmed()`. In `loadFromDisk`, archived agents come from the index already slim.
- [ ] T051 [US6] Rewrite `loadFromDisk` in `DaemonCore.swift` and add `AgentStore.loadLive(excluding:)`, per research R3: list `agents/`, load `ArchiveIndex`, fully read what the index does not name or what is newer than its entry, then fold archived results into the index and write it once. Keep `seedingCost` and the mends as they are. Maintain `archiveIndex` and write `archive.json` on archive, unarchive, retire and note changes. Replace T019's per-call sizing with index sizes. Make T047 pass.
- [ ] T052 [US6] Add `dropLiveState(for:)` and `liveStateKeys(for:)` (internal, for tests) in `DaemonCore.swift`, covering every row of the data-model table, and call `dropLiveState` in `archive` after `stop`. Make T048 pass.
- [ ] T053 [US6] Run quickstart §3 with the run-app skill's daemon launcher: 1,000 archived and 10 live agents against 10 live, 5 starts each, measuring footprint. Also run once on `main` for comparison. Record the figures in `walk/README.md`. The result must meet SC-003 (within 10%) and SC-004 (within 20 MB). If it does not, profile with `sample` before changing anything.

---

## Phase 10: User Story 7: Retire an archived agent now (P3)

**Goal**: one agent, at once, from its menu.

**Independent test**: quickstart §2, the Retire now bullet.

- [ ] T054 [P] [US7] Add to `RetirementTests.swift`:
  - `agents/retire` unconfirmed returns the size.
  - Confirmed on a 2-hour-old archived agent, it retires it, with `because: person`. The one-day floor applies only to the automatic rules; FR-006 is about the check, and the person asked.
  - On a live agent it fails with `-32051`, as it does on a held agent, with the hold's reason as the message.
  - On a retired agent it fails with `-32050`.
- [ ] T055 [US7] Implement `agents/retire` in `DaemonCore+Retention.swift` through `retire(_:because: .person)`, after checking `holds(for: [id])`. Make T054 pass.
- [ ] T056 [US7] Add **Retire Now…** to the archived agent's context menu in `App/Sources/AgentList/AgentRow.swift`, and nowhere for agents that are not archived. When the menu opens, it asks for holds through `agents/retire { confirmed: false }`. A `-32051` answer disables the item with the message as its help text. Otherwise it confirms with `RetirementWords.confirmRetire`, using a destructive button, then sends `confirmed: true`. Not on the phone (FR-028).

---

## Phase 11: Polish and proof

- [ ] T057 Run quickstart §2 in full on `/tmp/run-051` against a scratch daemon, and record each bullet's result in `walk/README.md`.
- [ ] T058 Run quickstart §4, the kill test, ten times, and record each outcome (SC-006).
- [ ] T059 Run quickstart §5 with the run-app skill on `/tmp/run-051`, and screenshot each Mac item into `walk/`.
- [ ] T060 [P] Write the docs:
  - A new section in `docs/how-to/archive-park-stop.md`: "How long archived agents are kept", covering the time, the cap, Forever, the notes, Retire now and what a retired agent leaves.
  - The two settings in `docs/reference/settings.md`.
  - `agent.retired` in `docs/reference/events.md`.
  - Then run `python3 scripts/docs-check.py`.
- [ ] T061 Merge `main` again, rebuild both schemes one after the other, and run the full suite six times on the branch and six on `main`. Record the differences in `walk/README.md`. Only new failures are this lane's.
- [ ] T062 Ask Alex with AskUserQuestion to look at the row notes, the retired line and the retired page on his iPhone and iPad. Install Remote from this branch on one device at a time, after saying it replaces his Remote. Batch the question as quickstart §5 says.
- [ ] T063 Before merging, stop and ask Alex. Merging turns retirement on for the real store: at the first start, every archived agent gets `archivedAt` = that start (FR-008), so nothing goes for 30 days by age. The 2 GB cap **does** apply after the first day, and the real store has 791 MB archived, so nothing is retired at once. Say both facts in the question.

---

## Dependencies

- Phase 1 → Phase 2 → Phase 3 (the look gate, T025) → everything else.
- US1 (Phase 4) comes before US2, US3, US5, US4 and US7, which all retire through T031 and T032.
- US2 needs T036's sizes. US3's preview (T039) needs US2's cap handling.
- US5 (holds) should come before US7, since Retire now uses the holds.
- US6 (Phase 9) depends only on Phase 2 and T028. It can be built alongside Phases 5–8 by a second lane in its own worktree, but it touches `loadFromDisk`, `archive` and the presence handler, so merge it after US1 lands to keep conflicts small.
- Phase 11 comes last.

## Parallel opportunities

- **Phase 1**: T003 and T004.
- **Phase 2**: tests T005–T007 together, then T008, T009, T010, T012, T014, T015 and T016 in parallel. They are all separate new files except T008, which touches `Agent.swift` alone. T011 follows T005 and T009–T010. T017 and T018 follow T008 and T015.
- **Phase 3**: T020, T021 and T022 in parallel after T019. T023 after T021.
- **Within stories**: each story's test task is [P] with the others. The implementation tasks touch `DaemonCore+Retention.swift` and run in order.
- **Across stories**: US6 (T046–T053) in its own worktree, alongside US2–US5.

## Implementation strategy

1. **MVP = Phases 1–4.** Archived agents go after 30 days, leave a tombstone and are explained
   everywhere they are named. The store stops growing without limit for anyone who uses it past
   a month.
2. Add **US2** (cap) and **US3** (settings) next. With them the store has a hard bound and the
   person can turn it off. Only then is this safe to merge (T063).
3. **US5** before merging as well: without it, a worktree with uncommitted work could lose the
   only record of why that work exists.
4. **US6** is the memory and start-time half. It is worth shipping even if retirement stays
   off, and it can land separately after US1.
5. **US4** extras and **US7** are last.

Total: 63 tasks.
