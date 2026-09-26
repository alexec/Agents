# Tasks: An Agent Can Move into a Worktree Mid-Work

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/move.md](contracts/move.md), [quickstart.md](quickstart.md)

**Tests**: Included. This repo tests every daemon behaviour, and the quickstart names each
property. Write each test before the code that makes it pass, and assert the property directly.
Never break source to prove a test fails.
- Integration tests use real temporary git repositories and the fake runtime. Copy the
  `repository(committed:subfolder:)` and `makeCore` helpers from
  `Pkg/Tests/AgentsKitTests/Integration/WorktreeStartTests.swift`.
- `FakeLauncher.launches` records the `cwd` of every launch.
- `FakeACPAgent.continuedSessionParams` and `newSessionParams` record the `cwd` of every resume
  and every new session.
- `FakeACPAgent.Script` can make resume fail.

**Where**: Everything runs in the worktree
`/Users/alexcollins/Agents/.agents/worktrees/053-move-to-worktree` on branch
`agents/053-move-to-worktree`. Never edit the shared checkout. Paths below are relative to the
worktree, and `Pkg/` stands for `Packages/AgentsKit/`.

**Gates**:
- **After T003 (Phase 0)**: the live resume-across-folders results. If any runtime loses its
  session, bring the result to Alex before T027 to T029 (Handover).
- **After Phase 3**: quickstart §3 on all four runtimes. Stop and bring anything that fails to
  Alex.
- **After T036**: screenshots of the capsule on an agent page. Settle the layout with Alex before
  T037 onwards (memory: settle the UX before building depth).

## Phase 1: Setup

- [X] T001 Confirm the baseline. Run `swift test` in `Pkg/` once and write down, in this file under
  T001, which tests fail on this branch's base `5f9b974` before any change (memory: the suite is
  broadly flaky under load, so note every failure by name).
  **Baseline, 2026-09-25, on main `a3895a8` merged in (`db6568b`)**: 2198 tests in 254 suites,
  108 s, 42 failing. Server tests (`ServerLinkTests.agentsd` not built in this worktree: aMacIsRefused,
  aNewServerIsSetUpAndAnswers, connectingStarts…, twoConnectsAtOnceAreOne, the Toolset/Update/Remove
  ones), restart tests (anAgentFoundDeadOnStartUp…, severalInterruptedAgents…, theyAreStartedOneAtATime,
  theRestartWordsGoAhead…, WorkflowRestart chain/depth), ConnectionRole socket tests (aStranger…,
  aHelperReaches…, aDevice…, onlyAWindowsConnection…, theBinderWaits…) and a handful of timing ones.
  The build may have picked up this lane's first additive model edits; T044 compares against a
  clean main run.
- [X] T002 Write `Pkg/Tests/AgentsKitTests/Live/RuntimeMoveLiveTests.swift`:
  - Gate it `.enabled(if: AGENTS_LIVE == "1")`, as in `LiveRuntimeTests.swift`.
  - For each of `claude`, `grok`, `copilot` and `cursor`, with two temporary folders A and B that
    are both git repositories:
    1. Launch in A with `newSession(cwd: A)` and prompt "Remember the word PELICAN. Reply only
       OK."
    2. End the process.
    3. Launch a new process in B and call `continueSession(id:cwd: B)`.
    4. Prompt "What word did I ask you to remember? One word."
  - Record for each runtime: whether the resume was accepted, and whether the answer contains
    PELICAN.
  - Launch with a clean environment except for auth (memory: driving agentsd by hand). Stagger
    the npx starts.
- [X] T003 Run T002 with `AGENTS_LIVE=1`, and run `./scripts/runtime-tools.sh`.
  - Write the results into `specs/053-move-to-worktree/research.md`: fill in R2 for Claude
    through the adapter, and R3 for Grok, Copilot and Cursor.
  - List any worktree-moving tool a runtime other than Claude offers, and check Grok first.
  - If all four keep the word, mark T027 to T029 "not needed" with the reason. Otherwise
    **stop and ask Alex** with the results, then carry on with Phase 2, which doesn't depend on
    the answer.
  **Result**: Claude, Copilot and Cursor carry their conversation into another folder; Grok refuses
  (`Path not found`) and would carry on having forgotten it. No runtime but Claude has a worktree
  tool. Codex and Gemini are not installed here. Handover (T027 to T029) is for Grok alone: asked
  of Alex at the Phase 3 gate.

---

## Phase 2: Foundational (blocks every story)

The record, the wire types and the one function that applies a move. Nothing calls it yet.

- [ ] T004 [P] Write `Pkg/Tests/AgentsKitTests/Unit/AgentMoveRecordTests.swift`:
  - An `Agent` with `pendingMove` round-trips, for each `MoveTarget` case.
  - A record without the key decodes with `pendingMove == nil`.
  - A record from before 053 (take a JSON fixture of one from `AgentWorktreeRecordTests`) still
    decodes.
  - `MoveTarget.newWorktree(name: nil)`, `.newWorktree(name: "x")`, `.existing(url)` and
    `.projectFolder` each round-trip.
- [ ] T005 [P] Create `Pkg/Sources/AgentsKitCore/Model/AgentMove.swift`:
  - `public enum MoveTarget: Codable, Hashable, Sendable { case newWorktree(name: String?); case existing(URL); case projectFolder }`.
  - `public enum MoveAsker: String, Codable, Sendable { case agent, person }`.
  - `public struct PendingMove: Codable, Hashable, Sendable`, with `target: MoveTarget`,
    `removeLeft: Bool` ("Only with `projectFolder`"), `discardChanges: Bool` ("Only with
    `removeLeft`"), `askedBy: MoveAsker` and `askedAt: Date`. Doc comments come from
    data-model.md.
- [ ] T006 In `Pkg/Sources/AgentsKitCore/Model/Agent.swift`:
  - Add `public var pendingMove: PendingMove?` after `worktree`, with the doc comment "A move asked
    for and not yet made (053). Applied when the turn ends, or at once when none is running.
    Cleared when applied, cancelled, archived or deleted."
  - Add it to `CodingKeys`, `init(from:)` using `(try? c.decodeIfPresent(...)) ?? nil` as
    `afterTurn` does, `encode` using `encodeIfPresent`, and the memberwise init (default nil).

  Make T004 pass.
- [ ] T007 [P] In `Pkg/Sources/AgentsKitCore/Model/AppTool.swift`:
  - Add `public static let enterWorktree = "enter_worktree"` and
    `public static let exitWorktree = "exit_worktree"`, with a comment block ("Two for moving
    this agent itself (053). Offered to every agent: moving yourself is not managing anyone.
    Neither name ends with another tool's name.").
  - Add a unit assertion to the existing AppTool or AppService test file that no tool name ends
    with either name, and that neither ends with another.
- [ ] T008 [P] In `Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`:
  - Add the methods `agentsMove = "agents/move"` and `agentsMoveSelf = "agents/moveSelf"`.
  - Add `MoveSelfRequest { token: String; target: MoveTarget; removeLeft: Bool; discardChanges: Bool }`.
  - Add `MoveRequest { agentID: UUID; target: MoveTarget?  // nil cancels; removeLeft: Bool = false; discardChanges: Bool = false }`.
  - Add `MoveAnswer { enum When: String { case now, afterTurn, nothing }; when; message: String; agent: Agent? }`,
    as in contracts/move.md §2.
  - Add no new failure codes.
- [ ] T009 In `Pkg/Sources/AgentsKitCore/Daemon/ConnectionRole.swift`:
  - Classify `agentsMove` with `agentsStop`.
  - Classify `agentsMoveSelf` with the token-bound app-tool methods (`agentsStopHelper`'s group).
  - Extend the existing role test so each is refused to a stranger.
- [ ] T010 Write the first half of `Pkg/Tests/AgentsKitTests/Integration/MoveTests.swift`, which
  calls `applyPendingMove` directly on an idle agent:
  - **Project folder → new worktree.** Afterwards:
    - `cwd` is `<top>/.agents/worktrees/<name>`, and `worktree.madeByApp` is true.
    - The branch is `agents/<name>`, and `worktree.project == projectFolder` as before.
    - `pendingMove` is nil.
    - The project folder's `git status --porcelain` is unchanged.
  - **The next prompt launches in the worktree.** Send one, then check
    `launcher.launches.last.cwd` and `continuedSessionParams["cwd"]`.
  - **Worktree → new worktree.** Commit a file in the first worktree, then move. The second
    worktree is at `<top>/.agents/worktrees/<name2>`, not nested, contains the committed file,
    and its `base` is the first worktree's branch.
  - **Project in a subfolder.** The agent lands in the same subfolder of the new worktree.
  - **Uncommitted changes stay behind.** An uncommitted edit in the old folder is still there
    after the move, and absent from the new one.
  - **Moving to an existing worktree.** `cwd` becomes that worktree, and no worktree is made.
  - **Moving to the project folder.** `cwd` is the project folder, and `worktree` is nil.
  - **A name is given.** `.newWorktree(name: "Fix Login")` gives `fix-login`, and a taken name
    gives `fix-login-2`.
  - **No name.** The agent's title is used, falling back to `agent-MMdd-HHmm` for an agent
    without one.
  - **Failure.** In a repository with no commit, the move fails: `cwd` is unchanged, `pendingMove`
    is cleared, and the transcript has "Could not move: …".
- [ ] T011 In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Worktrees.swift`, generalise the private
  `makeWorktree(in:project:prompt:)` into
  `makeWorktree(in repository:, project:, wanted: String, from: URL? = nil)`:
  - `from ?? project` is the folder where `GitWorktrees.hasCommit`, `GitWorktrees.base` and
    `GitWorktrees.add(branch:path:in:)` run.
  - The repository, `worktreesFolder`, `ensureExcluded` and the reservation still come from
    `project` (research R4).
  - `prepareWorktree(.new, …)` passes `WorktreeName.from(prompt:)` and no `from`.
  - Add `func prepareMoveTarget(_ target: MoveTarget, for agent: Agent) async throws -> (cwd: URL, worktree: AgentWorktree?)`:
    - For `newWorktree`, it resolves the name as in research R10, with
      `from: agent.worktree?.root`.
    - `existing` goes through `existingWorktree`, and a root equal to the repository's top is
      read as `projectFolder`.
    - `projectFolder` gives `(agent.projectFolder, nil)`.
  - 030's `WorktreeStartTests` must still pass.
- [ ] T012 Create `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Moves.swift`, with
  `func applyPendingMove(_ agentID: UUID) async`:
  1. Take and clear `pendingMove`.
  2. `prepareMoveTarget`.
  3. On success, set `cwd` and `worktree`, then call `changed(agent)` and
     `projectChanged(forAgentIn: projectFolder)`.
  4. Record the "Moved …" note from data-model.md, including the uncommitted count left behind,
     from `GitWorktrees.statusCount(in: oldRoot)`.
  5. Store the `moveNotes[agentID]` preface text.
  6. On failure, record "Could not move: <reason>. Still in <old>." and change nothing else.

  Add `var moveNotes: [UUID: String] = [:]` to `DaemonCore.swift` beside `artifactEdits`. Make
  T010 pass.

**Checkpoint**: a move can be applied and the next turn starts in the new folder, with no tool
and no UI yet.

---

## Phase 3: User Story 1: the agent asks to move, and carries on (Priority: P1) 🎯 MVP

**Goal**: an agent calls `enter_worktree` or `exit_worktree`, ends its turn, is moved, and starts
again by itself in the new folder.

**Independent test**: quickstart §3. In MoveTests, the fake agent's turn calls the tool, ends,
and the next launch's cwd is the worktree, with an app prompt sent.

- [ ] T013 [P] [US1] Write `Pkg/Tests/AgentsKitTests/Unit/MoveToolParsingTests.swift`, for
  `AppService.moveCall(named:_:)`:
  - `enter_worktree` with no arguments gives `.newWorktree(name: nil)`.
  - With `name` it gives `.newWorktree(name:)`, and with an absolute `path` it gives
    `.existing(url)`.
  - `name` and `path` together are refused.
  - A relative `path` is refused.
  - `exit_worktree` without `action`, or with an unknown one, is refused.
  - `keep` gives `.projectFolder` with `removeLeft` false.
  - `remove` gives `removeLeft` true.
  - `discard_changes: true` with `keep` is refused.
  - The refusal texts match contracts/move.md §1's local refusals.
- [ ] T014 [US1] In `Pkg/Sources/AgentsKit/ACP/Serve/AppService.swift`:
  - Add `static let enterWorktreeTool` and `exitWorktreeTool`, with the JSON from
    contracts/move.md §1, word for word.
  - Add `public enum MoveCall: Sendable, Equatable { case move(target: MoveTarget, removeLeft: Bool, discardChanges: Bool) }`,
    `public typealias MovesSink = @Sendable (MoveCall) async -> Outcome`, an init parameter
    `moves:` defaulting to `.refused("This app cannot move agents.")`, and
    `static func moveCall(named:_:)`.
  - List both tools in `tools/list` after `eventTools`, for every agent.
  - Route them in `tools/call` before `agentCall`.

  Make T013 pass.
- [ ] T015 [US1] In `Daemon/Sources/main.swift`, add the `moves:` closure. It relays `.move` as
  `DaemonAPI.Method.agentsMoveSelf` with `MoveSelfRequest(token:…)`, following the `events:`
  relay's shape.
- [ ] T016 [US1] Write the second half of `MoveTests.swift`, for asking:
  - A fake turn calls the move with `.newWorktree(name: nil)` in the middle of the turn:
    - The answer is `.afterTurn`, and its message contains "when this turn ends" and the expected
      name.
    - `pendingMove` is set, and `cwd` is unchanged while the turn runs.
    - When the turn ends, `cwd` is the worktree.
    - The next launch is there, and an app prompt (`from: .app`) was sent. Its text names the
      new folder.
  - Asking twice in one turn: only the last request applies, and only one worktree is made.
  - With the turn stopped after asking, the move still applies but no app prompt is sent.
  - With the turn failed after asking, the move still applies (via `turnFailed`).
  - A prompt queued by the person during the turn goes first, with the move preface on it, and no
    app prompt is added.
  - Refusals at ask time store nothing: not a repository; `path` not a worktree of this
    repository; a missing worktree.
  - `exit_worktree` from the project folder answers `.nothing` with "not in a worktree".
- [ ] T017 [US1] In `DaemonCore+Moves.swift`, add
  `func askMove(_ agentID: UUID, _ move: PendingMove) async throws -> DaemonAPI.MoveAnswer`:
  - Validate as in data-model.md "Validation". For `removeLeft`, run the 030 `removalFacts` with
    the mover left out of `blockedBy`, and list what would be lost.
  - Store `pendingMove`, then call `changed`, and record the "Will move … when this turn ends"
    note.
  - If no turn is in flight (`turnTasks[id] == nil`, `!sending.contains(id)` and
    `!state.hasTurnInFlight`), call `applyPendingMove` now and answer `.now`. Otherwise answer
    `.afterTurn`.
  - Build the message from contracts/move.md §1's answers, including the number of uncommitted
    files where the agent is now.
  - Add `public func moveSelf(_ request: DaemonAPI.MoveSelfRequest) async throws -> DaemonAPI.MoveAnswer`,
    which resolves the token (as the other `agents/*` token methods do) and uses
    `askedBy: .agent`.
  - Wire `agentsMoveSelf` in `DaemonCore+Dispatch.swift`.
- [ ] T018 [US1] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`:
  - In `finishTurn`, after `await releaseRuntime(for: agentID)` and **before**
    `guard stops[agentID, default: 0] == stopsBefore`, add
    `let moved = await applyPendingMoveIfAny(agentID)`.
  - After the stop guard and before `resumeIfCleared`, if `moved` was asked by the agent and the
    queue is empty, queue an app prompt ("You have moved to <path> (worktree <name> on <branch>).
    Carry on with what you were doing.") and send it the way `resumeIfCleared` does
    (`queueResume` / `sendResume` pattern, `QueuedPrompt(from: .app)`).
  - In `turnFailed`, apply the pending move the same way, with no app prompt.
  - In `beginTurn`, prepend `moveNotes.removeValue(forKey:)` as a preface block beside
    `artifactEdits`.

  Make T016 pass.
- [ ] T019 [US1] Build both schemes (memory: skip plugin validation, run them one after the
  other), then run `swift test --filter 'Move|WorktreeStart|AppService'`.
- [ ] T020 [US1] **Gate**: quickstart §3 for Claude, Grok, Copilot and Cursor on a run-app scratch
  root.
  - Record each result in `specs/053-move-to-worktree/walk/README.md`.
  - Stop and bring any runtime that doesn't work in the new folder to Alex.

**Checkpoint**: MVP. An agent can move itself and carry on, on all four runtimes.

---

## Phase 4: User Story 2: everything that follows a folder follows the move (Priority: P1)

**Goal**: restart, resume, archive cleanup and the project page all treat the new folder as the
agent's own.

**Independent test**: move, restart the daemon and resume the agent: it's in the worktree.
Commit, archive, and the worktree is removed.

- [ ] T021 [P] [US2] Add to `MoveTests.swift`:
  - A moved agent, with a new `DaemonCore` loaded from the same store, resumes with
    `continuedSessionParams["cwd"]` equal to the worktree.
  - A `pendingMove` stored with no turn running is applied by `recover()`.
  - An agent in the middle of a turn at shutdown applies its move when the resumed turn ends
    (use 025's pick-back-up path).
  - A moved agent, archived with everything committed, has its worktree removed by 030's
    `removeWorktreeIfDone`.
  - `listWorktrees` lists the moved-into worktree with the agent in it, and the old one without
    it.
  - A moved agent whose worktree was deleted by hand gets `worktreeMissing` on its next prompt,
    and never falls back to the project folder.
  - With the fake's resume set to fail, the agent carries on in a new session, the transcript has
    the "no longer has this conversation" note, and the briefing is sent again.
  - Archiving an agent with a `pendingMove` clears it, and nothing is made.
- [ ] T022 [US2] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore.swift` `recover()`, after agents are
  loaded, call `applyPendingMove` for every agent with a `pendingMove` whose state has no turn to
  pick up. Leave agents that 025 will resume mid-turn to T018's turn-end path.
- [ ] T023 [US2] In `DaemonCore+Commands.swift`, make `archive` and delete clear `pendingMove`
  (next to `dropAfterTurnAsk`). Make T021 pass.
- [ ] T024 [US2] Check every daemon reader of `agent.cwd` listed in research R8 (Changes, file
  mentions, Serving, Shells, Runtimes session list) reads it when it is used, not from a copy.
  Fix any that caches it, and add a MoveTests case for each fix.
- [ ] T025 [US2] Add removal on exit to `MoveTests.swift`:
  - `exit_worktree remove` from a worktree the app made, with everything committed: after the turn
    the agent is in the project folder, the worktree is gone, and an unmerged app branch is kept.
    The note says so.
  - With uncommitted files and no `discard_changes`, the request is refused at ask time with the
    files listed, and nothing is stored.
  - With `discard_changes`, the worktree goes.
  - An edit made after asking with `remove` means the move applies but the removal is skipped,
    with the reason in the note.
  - Remove from a worktree the app did not make is refused. So is one another agent works in.
- [ ] T026 [US2] In `applyPendingMove`, after the folder change, when `removeLeft` is set, call
  `removeWorktree(WorktreeRemovalRequest(project:, root: oldRoot, confirmed: discardChanges))`.
  Because the mover has already left, it no longer blocks the removal. Catch its refusal into
  the note. Make T025 pass.

These three are **conditional on T003**. Mark them "not needed" there if every runtime kept its
session:
- [ ] T027 [US2] Write `Pkg/Tests/AgentsKitTests/Unit/HandoverTests.swift`:
  - A transcript of user messages, agent messages and tool calls becomes one text block: the
    person's words, the agent's replies, and one line per tool call with its target.
  - It's shortened from the oldest end to a character budget, and says that it was shortened.
  - An empty transcript gives nil.
- [ ] T028 [US2] Create `Pkg/Sources/AgentsKit/ACP/Serve/Handover.swift` (research R5). Keep its
  interface independent of moves, so 052 can call it. Make T027 pass.
- [ ] T029 [US2] In `DaemonCore+Commands.swift` `connect`, in the branch where `continueSession`
  failed for an agent that had a session, queue the handover as a preface on the next prompt
  (beside the briefing). Extend the note: "… Carrying on in a new one, given the conversation so
  far."
  - Add a MoveTests case with the fake's resume failing: the first prompt of the new session
    contains the earlier user message.

**Checkpoint**: a moved agent is indistinguishable from one started in that worktree.

---

## Phase 5: User Story 3: the person moves an agent from the app (Priority: P2)

**Goal**: the Worktree capsule on an agent's page moves the agent, or queues the move for the end
of the turn, with Cancel.

**Independent test**: quickstart §4 steps 1 to 3.

- [ ] T030 [P] [US3] Add to `MoveTests.swift`, for `agents/move`:
  - On an idle agent, the answer is `.now`, `cwd` changes, and no turn starts: `launcher.launches`
    doesn't grow and no app prompt is sent.
  - During a turn, the answer is `.afterTurn`, and `target: nil` then clears `pendingMove` with a
    "Move cancelled" note.
  - After a person's move, the next person prompt carries the move preface.
  - An archived agent is refused.
- [ ] T031 [US3] In `DaemonCore+Moves.swift`, add
  `public func move(_ request: DaemonAPI.MoveRequest) async throws -> DaemonAPI.MoveAnswer`:
  - It uses `askMove` with `askedBy: .person`, or cancels when `target` is nil.
  - Wire `agentsMove` in `DaemonCore+Dispatch.swift`.

  Make T030 pass.
- [ ] T032 [US3] In `App/Sources/AppModel.swift`:
  - Add `func worktrees(forAgent:)`, which loads `worktrees/list` for the agent's `projectFolder`
    and caches it like `draftWorktrees`.
  - Add `func move(_ agent: Agent, to target: MoveTarget?)`, which sends `agents/move` and shows
    the answer's message on failure the way other agent actions do.
- [ ] T033 [US3] In `App/Sources/Chat/PromptBar.swift`, show the Worktree capsule on an agent's
  page when the agent is on this host and its project is a repository (contracts/move.md §4):
  - The title is `Project folder`, the worktree's name, or `Moving to <name>…` while
    `pendingMove` is set.
  - The choices are Project folder, New worktree, and each existing worktree (Missing disabled),
    with the current one ticked, plus **Cancel move** while one is waiting.
  - Reuse `worktreeChooser`'s rows by factoring them into a shared view. Leave out "New worktree
    on a branch".
  - Keep the ContentView modifier chain in AgentsApp unchanged (memory: scratch app opens no
    window).
- [ ] T034 [US3] In `App/Sources/Sidebar/FilesPane.swift`, add `.onChange(of: agent.cwd)`: unwatch
  the old folder (server or `FolderWatch`), reset `state.folder`, and watch the new one.
- [ ] T035 [US3] Check that the Changes pane (`App/Sources/Sidebar/ChangesPane.swift`) refreshes
  when `agent.cwd` changes. If it doesn't, key its load on `agent.cwd` in the same way.
- [ ] T036 [US3] **Gate**: take run-app screenshots of the capsule idle in the project folder, in
  a worktree, and with a move waiting during a turn.
  - Save them to `specs/053-move-to-worktree/walk/`.
  - Show Alex and settle the layout before T037.
- [ ] T037 [US3] In `App/Sources/Sidebar/TerminalPane.swift`, when the open shell's folder differs
  from `agent.cwd`, show a strip: "This agent now works in <name>." with an **Open a terminal
  there** button, which starts a new shell through the existing path (it opens in `agent.cwd`).
  Never end the old shell.

**Checkpoint**: the person can move an agent from its page.

---

## Phase 6: User Story 4: one way to move (Priority: P2)

**Goal**: agents the app runs have no runtime-owned worktree tool.

**Independent test**: a live Claude agent lists no `EnterWorktree` and names `enter_worktree`.

- [ ] T038 [P] [US4] In `Pkg/Tests/AgentsKitTests/Unit/ToolPolicyTests.swift`:
  - Assert that Claude's `disallowedTools` contains `EnterWorktree` and `ExitWorktree`.
  - Assert that `RemitCategory.workingFolder` is a case and that the table is still total.
- [ ] T039 [US4] In `Pkg/Sources/AgentsKitCore/Runtimes/ToolPolicy.swift`, add
  `case workingFolder`, with the doc comment "Changing the folder the session works in, or making
  a worktree to move into."
  - In `ToolPolicyCatalog.swift`, add
    `RemovedTool(name: "EnterWorktree", category: .workingFolder)` and the same for
    `ExitWorktree` to `claude.removed`.
  - Add any equivalent that T003 found for another runtime, through that runtime's lever.
  - Update every `switch` over `RemitCategory`, including the briefing's grouping.

  Make T038 pass.
- [ ] T040 [US4] In `scripts/runtime-tools.sh`, add the two names to the copy of Claude's removed
  list, then run the script for `claude` and check they're reported as removed.
- [ ] T041 [US4] Run the existing `RuntimeToolScopingLiveTests` with `AGENTS_LIVE=1` for Claude,
  and extend it to assert that `EnterWorktree` isn't offered.

---

## Phase 7: Polish and cross-cutting

- [ ] T042 [P] Docs, per the spec's Docs section:
  - `docs/how-to/start-in-a-worktree.md`: add "Move an agent that is already working".
  - `docs/explanation/projects-hosts-worktrees.md`: an agent's folder can change, and what
    follows it.
  - `docs/reference/agent-tools.md`: add `enter_worktree` and `exit_worktree`.

  Run `python3 scripts/docs-check.py`.
- [ ] T043 [P] Check that the Remote builds, and that `Remote/Sources/Projects/AgentCard.swift`'s
  worktree badge and the chat's runtime notes show a moved agent from the record alone. There's
  no phone UI for moving. Build the Remote for the generic simulator only (memory: no throwaway
  simulators).
- [ ] T044 Run the full suite three times on this branch and three times on `5f9b974`, and compare
  them by test name. Only failures on this branch that the base doesn't have count (memory: the
  suite is broadly flaky under load).
- [ ] T045 Run quickstart §4 in full on a scratch root, with screenshots in
  `specs/053-move-to-worktree/walk/`, and note what's left for Alex: the phone look, quickstart §5.
- [ ] T046 Update the spec-queue memory entry for 053 with the commits, what was walked and
  what's open.

---

## Dependencies and execution order

- **Phase 1**: T001 first. T002 and T003 can run alongside Phase 2, since only T027 to T029
  depend on T003's answer.
- **Phase 2** blocks every story. T004, T005, T007 and T008 are [P]. T006 needs T005. T011 comes
  before T012, and T010 is written before both.
- **US1 (Phase 3)** needs Phase 2. It's the MVP.
- **US2 (Phase 4)** needs US1's turn-end hook (T018) for T021's mid-turn case. The rest only needs
  Phase 2. T027 to T029 need T003.
- **US3 (Phase 5)** needs Phase 2 and `askMove` (T017). The UI work (T032 to T037) waits for the
  T036 gate.
- **US4 (Phase 6)** only needs Phase 1. It can run any time after T003.
- **Polish** comes last.

## Parallel examples

- Phase 2: T004 + T005 + T007 + T008 (four different files).
- US1: T013 alongside T016 (different test files). Then T014 → T015, and T017 → T018.
- US2: T021 + T025, and T027 if needed (tests), before T022/T023/T026/T028.
- US4 alongside US3's UI: T038 to T040 don't touch App/.

## Implementation strategy

1. **MVP**: Phases 1 to 3. An agent moves itself and carries on. Stop at the T020 gate.
2. Then US2, which makes the move stick across restarts and cleanup. Handover only if T003 says
   so.
3. Then US3's capsule. Screenshots and Alex's word come before the terminal strip.
4. Then US4, which can slot in anywhere after T003, and the polish.
5. Commit at each checkpoint on `agents/053-move-to-worktree`. Merge only when Alex says it's this
   lane's turn (memory: main checkout is only main).
