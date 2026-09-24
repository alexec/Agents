---

description: "Task list for 025 surviving-a-restart"
---

# Tasks: What Survives a Restart

**Input**: Design documents from `/specs/025-surviving-a-restart/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/stored-files.md](./contracts/stored-files.md),
[contracts/transcript-line.md](./contracts/transcript-line.md), [quickstart.md](./quickstart.md)

**Tests**: Included, and not optional. Every story here is "the second daemon knows what
the first one knew", and the only honest way to check that is to build a second core on
the same root and ask it. A test that exercises one daemon proves nothing about this
feature at all.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to

## Before you touch anything

1. **`xcodegen generate` after adding any source file.** The pbxproj is generated and lists
   files explicitly, so a new file that is not regenerated in does not exist to Xcode. Six
   new files below.
2. **Build with `-skipPackagePluginValidation`**, one scheme at a time. SwiftTerm ships a
   build-tool plug-in and `xcodebuild` has nobody to ask about it; without the flag it
   fails with three unexplained build commands.
3. **Never pattern-kill `agentsd`** — it hosts these sessions. Take the pid from the target
   root's `daemon.lock`.
4. **The suite is broadly flaky under load.** A single red test is not evidence. Compare
   several full runs on this branch and on `main` before concluding the branch did it.
5. **The working tree is not clean** — `README.md` is modified and `.agents/` and
   `.claude/skills/run-app/` are untracked, none of it this feature's. Do not sweep them
   into a commit.

---

## Phase 1: Setup

**Purpose**: The branch, and somewhere for the new code to live.

- [X] T001 Create the branch `025-surviving-a-restart` from `main`, leaving the unrelated
      working-tree changes (`README.md`, `.agents/`, `.claude/skills/run-app/`) untouched
      and uncommitted.
- [X] T002 Add `attention` to `Packages/AgentsKit/Sources/AgentsKit/Store/StoreLocations.swift`,
      returning `root.appendingPathComponent("attention.json")`, with a doc comment in the
      manner of the `workflows` and `devices` properties beside it: what is in it, that the
      daemon is its only writer, and that losing it costs a repeated notification and
      nothing else.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The one conformance and the one wording that more than one story needs. Both
are additive and neither changes behaviour on its own.

**⚠️ CRITICAL**: T003 blocks US1 and US2. T004 blocks US4.

- [X] T003 [P] Add `Codable` to `Delivery` in
      `Packages/AgentsKit/Sources/AgentsKitCore/Attention/Delivery.swift`. No new fields:
      the four it has — `needID`, `to`, `alertedAt`, `alertCount` — are exactly what
      FR-001 names, and `NeedID` and `Surface` are already `Codable` as tagged objects. Add
      a line to its doc comment saying it is now written down, and that it still carries
      nothing about what the need *says* (FR-007).
- [X] T004 [P] Add the closing-line wording to
      `Packages/AgentsKit/Sources/AgentsKitCore/Model/RuntimeNote.swift` as a `public static
      let` beside `stoppedWithDaemon`. **Do not add it to `isPassing`** — that set names
      notes the chat drops once superseded, and this one is permanent. Say so in the doc
      comment, because the next person to add a note will read that function first.

**Checkpoint**: The package still builds and every existing test still passes. Nothing
observable has changed.

---

## Phase 3: User Story 1 - You are not told twice about the same thing (Priority: P1) 🎯 MVP

**Goal**: A need that outlives a restart keeps its delivery and its first-raised time, so
the person is not alerted again and the ladder does not start over.

**Independent Test**: Deliver and alert a need on a fake surface, drop the core, build a
second on the same root, and confirm the need is still shown in the same place with
`alertCount` unmoved and `raisedAt` unchanged.

### Tests for User Story 1

> Write these first. They fail against today's code, which is the point.

- [X] T005 [P] [US1] Create
      `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AttentionStoreTests.swift`: a round
      trip of all three arrays; a missing file reading as empty; an unreadable file reading
      as empty rather than throwing; an entry naming an unknown device dropped on load
      (FR-006); a `withdrawing` entry older than seven days dropped on load.
- [X] T006 [US1] Add to
      `Packages/AgentsKit/Tests/AgentsKitTests/Integration/AttentionTests.swift` a case
      that builds a second `DaemonCore` on the same `StoreLocations` after the first has
      delivered and alerted a report need, and expects: the need outstanding, the delivery
      on the same surface, `alertCount` still 1, and `raisedAt` equal to the first core's
      value rather than the second's clock (FR-002, FR-003).
- [X] T007 [US1] Add a case to the same file for the settling pause: a need raised inside
      the pause before the restart is **not** given a fresh pause by the second core
      (scenario 3).
- [X] T008 [US1] Add a case to the same file asserting the re-alert rule is untouched — a
      delivery whose `alertedAt` is older than `reAlertInterval` still alerts after the
      restart (scenario 5). This is the test that stops the fix from becoming a mute.

### Implementation for User Story 1

- [X] T009 [US1] Create `Packages/AgentsKit/Sources/AgentsKit/Store/AttentionStore.swift`
      with `AttentionRecords` (`raised: [RaisedNote]`, `deliveries: [Delivery]`,
      `withdrawing: [PendingWithdrawal]`) and `RaisedNote` (`need: NeedID`, `at: Date`).
      `load()` returns empty records for a missing or unreadable file; `save(_:)` writes
      whole and atomically, creating the root directory first. Model it on `DeviceStore`,
      which is the closest neighbour. `withdrawing` and `PendingWithdrawal` are declared
      here now and used in US2 — one file, written once.
- [X] T010 [US1] Add to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`:
      `lazy var attentionStore = AttentionStore(locations: locations)`, and a
      `var lastWrittenAttention: AttentionRecords?` holding the last copy written. Amend
      the doc comments on `deliveries` and `needRaisedAt`, which currently say they are
      never written down — that sentence becomes false here and must not be left standing.
- [X] T011 [US1] In
      `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Attention.swift`, add
      `loadAttention()`: read the records, drop any delivery or withdrawal naming a device
      not in `devices` (FR-006), and populate `deliveries` and `needRaisedAt`. Amend the
      file's header comment, which opens "Three things live here and none is written to
      disk" — two of the three now are, and why is the first thing the next reader needs.
- [X] T012 [US1] In the same file, add `writeAttentionIfMoved()`: build the records from
      the two dictionaries, compare against `lastWrittenAttention`, and write only on a
      difference. Call it at the end of `reconsider()`. **Not unconditionally**:
      `reconsider()` runs on every presence report from every window and device, several
      times a second with nobody doing anything (research §2).
- [X] T013 [US1] ~~In `Daemon.swift`, call `loadAttention()` in `start()` before
      `recover()`, and add a `reconsider()` after `pickUpAfterRestart`.~~ **Done
      differently, and `Daemon.swift` is untouched.** Two changes of mind while building:
      (1) `loadAttention()` belongs at the top of `recover()`, not in `Daemon.start()` —
      `recover()` is already "read the record and tell the truth about it", and putting it
      there means every test and any future embedder driving a `DaemonCore` directly gets
      it too, rather than only the one caller that goes through `Daemon`. (2) The
      `reconsider()` after recovery is actively wrong: nothing is connected that early, so
      it decides every restored delivery has nowhere to go, moves it to nowhere, and moves
      it back the moment a window appears — two broadcasts and a file rewrite to arrive
      where it started. The first presence report does it, moments later, when there is
      somebody to tell. Both are written up on `loadAttention`.
- [X] T014 [US1] Confirm `needs()` still prunes `needRaisedAt` to the live set, so a
      question asked again later is a new need with a new time, and a loaded note for a
      need that never comes back is dropped rather than accumulating (data-model, Rules).

**Checkpoint**: ✅ Reached 2026-09-24. Proved twice over. In the suite: five cases in
`AttentionRestartTests`, three of which were red before the implementation. And against
the real `agentsd` on a scratch root — daemon 1 logs `attention: report:… first to mac`
and writes `alertCount: 1`; daemon 2, after a kill and restart, logs
`nowhere → mac, alert false` and leaves `alertedAt` and `raisedAt` exactly as the first
daemon left them. Before the change, daemon 2 logged `first to mac` with `alert: true`.
Full suite green three runs running (1185 tests); both schemes build.

---

## Phase 4: User Story 2 - A question that is gone stops asking (Priority: P1)

**Goal**: A banner on a phone for a need that died with the daemon is taken down, including
when the bridge was not listening at the moment it was decided.

**Independent Test**: Deliver a permission to a fake device, drop the core, build a second
on the same root, and confirm a withdrawal — a `MailboxItem` with a `nil` envelope — is
posted for it.

**Depends on**: US1. There is nothing to withdraw until the deliveries are on disk.

### Tests for User Story 2

- [X] T015 [US2] Add to
      `Packages/AgentsKit/Tests/AgentsKitTests/Integration/AttentionTests.swift` a case
      using `FakeMailbox`: a permission delivered to a fake device, the core dropped, a
      second core built on the same root, and a withdrawal posted for that need id with
      the note then gone from the file (FR-004).
- [X] T016 [US2] Add a case for the retry: with no mailbox and no broadcaster set, the
      withdrawal stays in `withdrawing`, and goes out on the next `reconsider()` once a
      connection exists (FR-005). This is the case that would not exist if the obvious
      implementation had been written.
- [X] T017 [P] [US2] Add a case asserting a withdrawal for an unpaired device is dropped
      rather than posted (FR-006), and one asserting a `withdrawing` entry older than
      seven days is dropped on load.

### Implementation for User Story 2

- [X] T018 [US2] In
      `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Attention.swift`, add
      `var pendingWithdrawals: [PendingWithdrawal]` to `DaemonCore` and populate it in
      `loadAttention()`.
- [X] T019 [US2] In `reconsider()`'s existing first loop — "for every delivery whose need
      is no longer outstanding" — record a `PendingWithdrawal` alongside calling
      `withdraw(_:from:at:)` when the surface is a device. **Do not add a second
      restart-only withdrawal path**: 021's FR-012 says one place decides, and the loaded
      dictionary running through the existing loop is that same place (research §4).
- [X] T020 [US2] Add `drainWithdrawals()`: re-post every pending withdrawal when there is
      somewhere to post to (`mailbox != nil` or the broadcaster is set and
      `connectionCount > 0`), drop each once handed over, drop any whose device is unknown,
      and drop any older than seven days. Call it from `reconsider()`.
- [X] T021 [US2] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/Daemon.swift`, have the
      server's `onConnectionCountChanged` call `reconsider()` when the count rises, so a
      bridge that connects five seconds after start-up drains the withdrawals rather than
      leaving them for the next thing that happens to change.
- [X] T022 [US2] Include `withdrawing` in the records written by `writeAttentionIfMoved()`,
      so a daemon that exits before anything connects hands the retry to the next one.

**What changed while building** (2026-09-24):

- **T015 passed on US1 alone.** With a mailbox of its own, the daemon's existing met-need
  loop already withdraws a restored delivery — research §4's "no new mechanism" held
  exactly. What US2 actually had to fix was the daemon's own case, which has no mailbox.
- **A carrier is said, not guessed — `mailbox/carry`.** The plan had T020/T021 re-post on
  every connection that appeared. The code says why that is wrong: every connection starts
  as the Mac and the bridge never says otherwise, so the daemon cannot tell it from a
  window; and `agentsd mcp` connects and disconnects on *every tool call*, so "a
  connection appeared" is several times a turn per agent. Instead the bridge says
  `mailbox/carry` on connecting (`Bridge/Sources/MailboxTransport.swift`, one call), the
  daemon keeps `carriers` and forgets one on disconnect (`Daemon.swift`), and
  `drainWithdrawals()` runs at the end of every `reconsider()` and hands everything owed
  over only when a carrier is there. A carrier arriving reconsiders, so after a restart
  with no window the bridge connecting is enough to decide and send the withdrawals.
- **Every withdrawal is owed, including moves.** `withdraw(_:from:at:)` now only records
  the debt, so a banner moved off a phone while the bridge was away is taken down too, not
  just one whose need died. A later `post` of the same need to the same device voids a
  waiting withdrawal, or a banner put back while the bridge was away would be taken down
  again for a question still asking.
- **A core that has not read `attention.json` never writes it.** Found by a test that
  connected a carrier before `recover()`: `reconsider()` wrote its empty memory over the
  first daemon's notes. Production cannot reach that order — the socket opens after
  recovery — but nothing should overwrite a file it never read. `lastWrittenAttention ==
  nil` already meant "not loaded"; the write now refuses while it is.

**Checkpoint**: ✅ Reached 2026-09-24. Six cases in `WithdrawalRestartTests`; the four
about the daemon's own case were red before the implementation. Against the real `agentsd`
and its socket, with a dead question and a live stuck report both shown on a paired phone:
a window arriving broadcast **no** withdrawals and left both owed on disk; the bridge
saying `mailbox/carry` heard both and the debt cleared; with the bridge and window gone,
the report fell back to the phone, and archiving its agent left that withdrawal owed and
unbroadcast — which is `forgetCarrier` wired through the real server's disconnect. Full
suite green three runs running (1192 tests); the bridge, Mac and iOS schemes all build.

---

## Phase 5: User Story 3 - A restart does not break a chain of workflows (Priority: P2)

**Goal**: A run in flight survives, so `workflowCompleted` chains still fire and the depth
ceiling still counts.

**Independent Test**: Fire a workflow, restart the daemon while its agent works, let the
agent finish, and confirm the workflow chained on its completion fires.

### Tests for User Story 3

- [X] T023 [P] [US3] Create
      `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WorkflowRunStoreTests.swift`: `runs`
      round-trips through `WorkflowRecords`; a file written without `runs` reads as no runs
      (the leniency this file already has); a run older than seven days is dropped on load.
- [X] T024 [US3] Add to
      `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowFiringTests.swift` a
      case that fires a workflow, builds a second core on the same root, finishes the
      agent, and expects the workflow chained on completion to fire (FR-009).
- [X] T025 [US3] Add a case asserting depth: a chain restarted part-way down stops at the
      same ceiling rather than starting again at zero (FR-010). **This is the test that
      catches the ordering bug in T028** — write it before that task, and watch it fail if
      the runs are loaded in `startWorkflows()` instead.
- [X] T026 [P] [US3] Add cases for the pruning rules: a run whose agent is archived is
      released and fires **nothing** chained on it (FR-012); a run whose workflow file has
      gone is released the same way; a restored run still refuses a second fire of its
      workflow (FR-013); `isRunning` is true on the summary until the run is over (FR-011).

### Implementation for User Story 3

- [X] T027 [US3] Add `var runs: [WorkflowRun] = []` to `WorkflowRecords` in
      `Packages/AgentsKit/Sources/AgentsKit/Workflows/WorkflowStore.swift`, and persist on
      each of the five places `workflowRuns` is mutated in
      `DaemonCore+Workflows.swift` — claimed at `fire`, again once `agentID` is known, and
      the three removals. `WorkflowRun` is already `Codable` and needs no change.
- [X] T028 [US3] Add `loadWorkflowRuns()` to
      `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`, keyed by
      `folder + workflowID` as in memory, and call it from `Daemon.start()` **before
      `recover()`**. Not in `startWorkflows()`: recovery defers its lifecycle events with
      the depth computed at that moment, so loading later records depth zero for every one
      of them and silently loses the ceiling this story exists to save (research §7,
      contracts/stored-files.md).
- [X] T029 [US3] Add `pruneWorkflowRuns()` and call it from `startWorkflows()`, after the
      projects are adopted and the agents are loaded: release any run whose agent is
      missing or archived, whose workflow file has gone, or which is more than seven days
      old — each **without** firing anything chained on its completion, because it did not
      complete.
- [X] T030 [US3] Leave `move`'s `.foundDead` early return exactly as it is. It is why a run
      carried across a restart is not released during recovery, and it is already correct
      (research §8). Read it, confirm it, change nothing.

**What changed while building** (2026-09-24):

- **`WorkflowRecords` needed a decoder of its own before `runs` could exist.** A
  synthesized decoder requires every key, and `WorkflowStore.load()` reads a file it cannot
  decode as empty — so adding the field the obvious way would have read every
  `workflows.json` already on disk as nothing, and quietly un-archived every workflow the
  person had put away. It now decodes key by key, `runs` through `Lossy`, so one run a
  newer build wrote costs that run and not the archive beside it.
- **`loadWorkflowRuns()` is at the top of `recover()`, not in `Daemon.start()`,** for
  US1's reason: every test and any embedder calls `recover()`. The ordering research §7
  warns about is kept — the runs are in memory before anything is moved — though the trap
  is not reachable today: since every agent recovery finds is picked back up, recovery
  raises no lifecycle event at all. Kept because the order should not depend on that.
- **A kept run needs an agent that will carry on, not merely one that exists.** An agent
  can finish and have its record written, and the daemon go before its run is let go;
  restored, that run would wait for a finish that already happened and refuse its workflow
  as "a run is still going" for a week. It is released like the others, without firing:
  whether its completion should have fired a chain is not something the daemon can now
  honestly say.
- **A run is found from its agent two ways.** The run is written the moment its agent is
  known; the agent's record, which names the run back, a moment later by a queued task.
  A daemon killed between the two left a run nothing could find — found by the chain test
  failing 3 in 3 under the full suite. First fix tried: have `fire()` wait for the record
  write before writing the run. Rejected on evidence: it made "Run now" wait on every
  queued record write, and took `WorkflowFiringTests` from 1 failure in 8 runs to 7 in 8.
  What stayed: `runInFlight(for:)` finds the run by the agent's `startedByRun`, and — only
  when the agent carries none — by the run's `agentID`, which is reachable only after a
  restart. `aRunWhoseAgentDoesNotNameItBackIsStillFound` pins it.
- **T030 confirmed, unchanged.** `move` on `.foundDead` does not release a run whose agent
  is about to be picked back up.

**Checkpoint**: ✅ Reached 2026-09-24. Ten cases across `WorkflowRestartTests` and
`WorkflowRunStoreTests`; the five restart cases written first were red against the data
shape alone. Verified in a detached worktree at `5ec63f9` with only US3's files in it —
the shared tree did not compile at the time, mid-edit by the 027 lane: full suite **5 of 5
runs green**, against 3 of 5 on the unmodified base (whose two failures were
`aConnectionBecomesTheDeviceItIdentifiesAs` and `eachNewProcessIsCountedFromNothing`, both
known-flaky and outside this story); `WorkflowFiringTests` 7 of 8 on both. Against the real
`agentsd` built from that worktree, on a seeded root: three restored runs — agent finished,
agent archived, workflow file gone — were each let go with that reason in `daemon.log`, and
the archived workflow in `states` and `lastTickAt` came through the new decoder untouched.
The Mac and iOS schemes build.

---

## Phase 6: User Story 4 - The conversation says the question was never answered (Priority: P3)

**Goal**: All three ways a question can die unanswered leave a line saying so.

**Independent Test**: End an agent holding a question three ways and confirm each
conversation carries the line, after the question and before the ending.

### Tests for User Story 4

- [ ] T031 [US4] Create
      `Packages/AgentsKit/Tests/AgentsKitTests/Integration/UnansweredQuestionTests.swift`
      with three cases — the runtime exits, the person stops the agent, the daemon restarts
      — each expecting a `runtimeNote` with the closing wording, positioned after the
      `permissionAsked` entry and before the `stateChanged` one (FR-014, FR-015).
- [ ] T032 [P] [US4] Add a case for a form rather than a permission, covering all three
      endings (scenario 4).
- [ ] T033 [P] [US4] Add the negative cases: a question that was answered, declined,
      cancelled, or withdrawn by the runtime gets **no** extra line (FR-016). Four
      assertions, because four paths already close themselves.
- [ ] T034 [P] [US4] Add a case asserting the line is still drawn after the ending line
      follows it — that it has not been treated as a passing note.

### Implementation for User Story 4

- [ ] T035 [US4] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`, in the
      `.processExited` arm that clears `pendingPermissions` and `elicitations`, record the
      line once per question before `move(agentID, on: .processDied)`.
- [ ] T036 [US4] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`,
      in `stop`'s two loops over the pending dictionaries, record the line once per
      question before the agent is moved.
- [ ] T037 [US4] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift`,
      in `recover()`, record the line for an agent whose state was `waitingOnUser` —
      before the `stoppedWithDaemon` note and before `move(id, on: .foundDead)`. The
      pending dictionaries are empty by then; the state is how the daemon knows, and
      position in the transcript is how the reader knows which question (research §9).
- [ ] T038 [P] [US4] Check `Remote/Sources/Chat/EntryView.swift` and
      `App/Sources/Chat/Transcript.swift` draw the line as an ordinary runtime note. Both
      already have a `.runtimeNote` arm, so this is a confirmation, not a change.

**Checkpoint**: `grep "Nobody answered" transcript.jsonl` finds it after all three endings,
and the conversation reads in order.

---

## Phase 7: User Story 5 - What you had half-typed is still there (Priority: P3)

**Goal**: Unsent text, attachments and the start-form draft survive a relaunch.

**Independent Test**: Type without sending, attach a file, quit, reopen, and find both.

**Note**: the Mac app only. The iOS app keeps its own prompt text in view state and is out
of scope here (research §12).

### Tests for User Story 5

- [ ] T039 [P] [US5] Create
      `Packages/AgentsKit/Tests/AgentsKitTests/Unit/DraftStoreTests.swift` against an
      injected `UserDefaults(suiteName:)`: a draft round-trips; clearing removes it;
      sweeping removes one whose agent is gone or archived (FR-022); sweeping removes one
      untouched for thirty days; an entry that will not decode is discarded rather than
      throwing.
- [ ] T040 [P] [US5] Add a case for the inline-data cap: a draft carrying more inline
      attachment data than the cap keeps its text and every by-reference attachment, drops
      the inline blocks, and sets `droppedInlineData`.
- [ ] T041 [P] [US5] Add a case for `DraftKey` rendering: `.agent(uuid)` and
      `.newAgent(folder:)` produce stable, distinct defaults keys, and `.newAgent(nil)` is
      distinct from a folder.

### Implementation for User Story 5

- [ ] T042 [P] [US5] Create
      `Packages/AgentsKit/Sources/AgentsKitCore/Model/Draft.swift` with `DraftKey`
      (`.agent(UUID)`, `.newAgent(folder: URL?)`), `Draft` (`text`, `attachments`,
      `mentions`, `start`, `editedAt`, `droppedInlineData`) and `StartDraft` (`cwd`,
      `runtimeID`, `folders`, `servers`, `chosen`). Every `StartDraft` field mirrors one
      `AppModel` already holds.
- [ ] T043 [US5] Create
      `Packages/AgentsKit/Sources/AgentsKitCore/Store/DraftStore.swift`, taking its
      `UserDefaults` as an init parameter the way `SidebarFrame` does: `draft(for:)`,
      `save(_:for:)`, `clear(_:)`, and `sweep(liveAgents:now:)`. It goes in `AgentsKitCore`
      rather than `App/Sources` because the package's suite is the only one the schemes
      run — in the app target this logic is covered by nothing (research §10).
- [ ] T044 [US5] In `App/Sources/Chat/PromptBar.swift`: restore `text`, `attachments` and
      `mentions` from the store when the bar appears for a conversation; save as typing
      settles rather than on every keystroke; and **clear the draft where the prompt is
      sent** — the two places at the end of `send` that already empty `text` and
      `attachments` (FR-021).
- [ ] T045 [US5] In `App/Sources/AppModel.swift`, restore the start-form fields
      (`draftCwd`, `draftRuntimeID`, `draftFolders`, `draftServers`, `draftChosen`) from
      the stored `StartDraft` and write them back when they change. Be careful with
      `refreshDraftOptions`, which clears `draftChosen` on a runtime change — restoring
      must not resurrect choices for options the new runtime does not offer, which the
      existing `offered` filter already handles.
- [ ] T046 [US5] Call `sweep` from `AppModel` when the agent list arrives from the daemon,
      so a draft whose conversation has been archived or deleted goes rather than
      reappearing against nothing (FR-022).
- [ ] T047 [US5] Show in `App/Sources/Chat/AttachmentStrip.swift` that something by value
      was dropped, when `droppedInlineData` is set. One line, in the app's voice — a
      restored draft that quietly lost a pasted screenshot is worse than one that says so.

**Checkpoint**: Type, quit, reopen, and it is there. Send, quit, reopen, and it is not.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [ ] T048 `xcodegen generate`, then build both schemes sequentially with
      `-skipPackagePluginValidation`.
- [ ] T049 Run the whole suite several times: `swift test --package-path Packages/AgentsKit`.
      Compare against `main` before blaming this branch for anything red.
- [ ] T050 [P] Update `README.md`'s list of what the daemon owns to include
      `attention.json`, in the same voice as the lines around it. This is the file people
      read to find out what is on disk.
- [ ] T051 [P] Add a short section to `docs/` — or to the README beside the daemon's
      files — naming what is deliberately **not** persisted and why, from research §13. The
      next person to find `presences` in memory should find the reasoning rather than
      repeat this review.
- [ ] T052 Walk [quickstart.md](./quickstart.md) with the `run-app` skill on a scratch root:
      the restart check for US1, the transcript check for US4, the draft check for US5.
      US2's device half and nothing else needs Alex.
- [ ] T053 Ask Alex to do the one check that needs a phone: a question in front of the
      device, the daemon killed, the banner clearing without the app being opened.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: needs Setup. T003 blocks US1 and US2; T004 blocks US4.
- **US1 (Phase 3)**: needs T003. The MVP.
- **US2 (Phase 4)**: needs US1 — there is nothing to withdraw until the deliveries are on
  disk. The only story-to-story dependency in the feature.
- **US3 (Phase 5)**: needs nothing but Setup. Can be done first if preferred.
- **US4 (Phase 6)**: needs T004 and nothing else.
- **US5 (Phase 7)**: needs nothing. Touches no daemon file.
- **Polish (Phase 8)**: needs whichever stories are being shipped.

### Within each story

- Tests first, and confirm they fail. T025 in particular is worthless written afterwards:
  it is the only thing that catches the ordering trap in T028.
- Store before daemon; daemon before app.

### Parallel Opportunities

- T003 and T004 together.
- US3, US4 and US5 are mutually independent and touch disjoint files — three people could
  take one each once Phase 2 is done.
- Within US5, T039–T042 are all separate files.
- T050 and T051 together.

---

## Parallel Example: Phase 2 and the independent stories

```bash
# Phase 2, both at once:
Task: "Add Codable to Delivery in Packages/.../Attention/Delivery.swift"
Task: "Add the closing-line wording to Packages/.../Model/RuntimeNote.swift"

# Then three stories in parallel:
Task: "US3 — runs in workflows.json, loaded before recover(), pruned after"
Task: "US4 — the closing line on all three paths a question can die"
Task: "US5 — drafts in UserDefaults, restored, swept, cleared on send"
```

---

## Implementation Strategy

### MVP (US1 only)

Phases 1, 2 and 3. That is `attention.json`, the load, and the write-when-moved. It fixes
the failure that happens most often — a rebuild of this app re-notifying the phone — and it
is about eighty lines. Stop there and validate before going on.

### Incremental delivery

1. Setup + Foundational → nothing observable has changed.
2. **US1** → the phone stops repeating itself. Ship.
3. **US2** → stale banners come down. Ship.
4. **US3** → chains survive. Ship.
5. **US4** → the record is honest about unanswered questions. Ship.
6. **US5** → drafts survive. Ship.

Each is a commit that stands on its own and can be reverted without touching the others.

---

## Notes

- Six new source files. `xcodegen generate` after them or Xcode will not see them.
- Three of the four facts here are written from `reconsider()` or from `fire`, both of
  which run often. Neither may gain an unconditional write.
- Nothing in this feature may depend on a tidy shutdown: `agentsd` has no signal handler
  and is killed outright at logout.
- The three ways to get this wrong are in [plan.md](./plan.md) under "The three places this
  is easy to get wrong". Read them before T028, T020 and T004.
