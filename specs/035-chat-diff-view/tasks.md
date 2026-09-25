# Tasks: What the Agent Changed, Beside the Conversation

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/changes.md](contracts/changes.md), [quickstart.md](quickstart.md)

**Tests**: Included. The quickstart names each property to be tested, and this repo tests every
daemon behaviour. Write each test before the code that makes it pass.
- Integration tests use real temporary git repositories: `git init` in a temp folder, one
  commit, with `user.name`/`user.email` set locally.
- They also use the fake runtime (`Pkg/Tests/AgentsKitTests/Fake/FakeACPAgent.swift`, driven
  through `emit(_:)`).
- Model them on `Pkg/Tests/AgentsKitTests/Integration/ShowFileTests.swift`.

**Where**: Everything runs in the worktree `.agents/worktrees/035-chat-diff-view` on branch
`035-chat-diff-view`. Never edit the shared checkout at `/Users/alexcollins/Agents`. Paths are
relative to the worktree. `Pkg/` stands for `Packages/AgentsKit/`.

**Gates**:
- **After Phase 3 (US1)**: run-app screenshots of the list and a file with reported edits only.
  Settle the layout with Alex before Phase 4 (see memory: settle the UX before building depth). In
  particular, settle whether a file has two views or three.
- **In Phase 7**: one live run per runtime (quickstart §3). If a runtime's diff shape breaks the
  fold, stop and bring it to Alex.

**Rules that apply everywhere**:
- Change is shown by mark and weight, never red and green (FR-013).
- Every git command runs through `GitChanges`' read-only environment (research R4).
- The window never polls `daemon.sock` (see memory: daemon socket polling exhausts descriptors).

## Phase 1: Setup

- [X] T001 Confirm the baseline: run `swift test` in `Pkg/` once and write the count and any failures on main into this task. Build the `Agents` scheme once with plugin validation skipped (see memory), so a later build failure isn't blamed on this branch. **Baseline at `ca4be76` (branch fast-forwarded to main first): 1413 tests in 158 suites, all passing; six further runs on a clean main checkout all green. Agents scheme builds.**
- [X] T002 [P] Add test helpers to `Pkg/Tests/AgentsKitTests/Fake/FakeACPAgent.swift`, beside `chunk(_:messageID:)`:
  - `static func toolCall(id: String, title: String, status: String = "pending") -> JSONValue` sends `sessionUpdate: "tool_call"`.
  - `static func diffUpdate(id: String, path: String, oldText: String?, newText: String, status: String? = nil, rawInput: JSONValue? = nil) -> JSONValue` sends `sessionUpdate: "tool_call_update"` with `content: [{type: "diff", …}]`.
  - `static func status(id: String, _ status: String) -> JSONValue` sends an update carrying only the status.

  These reproduce the Claude sequence in research R1.
- [X] T003 [P] Build the SC-002 fixture `Pkg/Tests/AgentsKitTests/Fixtures/claude-edits.jsonl`:
  - Take one real Claude transcript from `~/Library/Application Support/Agents/agents/*/transcript.jsonl` with at least 50 completed diff calls. It must include a Write over an existing file (first diff with no old text, final with old text), a call carrying two diffs, and a `failed` call carrying a diff.
  - Keep only `toolCall`/`toolCallUpdate` entries, and replace every `oldText`/`newText` with a short stand-in that keeps presence or absence and a line count. Paths are rewritten under `/fixture/`.
  - Write `claude-edits.expected.json` beside it: the ordered list of `{path, toolCallID, index, isNew}` the fold must produce. Compute it with a throwaway script that applies R1's rule (last diff per call, `completed` only), not with the Swift code under test.
  - Add a line about both files to `Pkg/Tests/AgentsKitTests/Fixtures/README.md`.

---

## Phase 2: Foundational (blocks every story)

The record field, the fold, the wire types and the daemon's reported-only answer. After this
phase `changes/list` works with no git at all.

- [X] T004 [P] Write `Pkg/Tests/AgentsKitTests/Unit/StartingPointRecordTests.swift`:
  - An `Agent` with `startingPoint` round-trips.
  - A record without the key decodes with `startingPoint == nil`.
  - The encoded JSON of an agent with nil has no `startingPoint` key.
- [X] T005 [P] Write `Pkg/Tests/AgentsKitTests/Unit/ReportedChangesTests.swift`, with one test per rule in research R1 and data-model "ReportedChanges":
  - `toolCall` then a `diffUpdate` with no old text, then the same path with old text, then `status completed` is **one** edit, not new (`oldText != nil`).
  - A call ending `failed` gives no edit.
  - A call with a diff and no final status is in `inProgress` and not in `edits`.
  - One update with two diffs gives two edits, `index` 0 and 1.
  - Edits are ordered by each call's first diff, not by completion.
  - `byFile` orders files by first edit.
  - Folding entries one at a time equals folding them all at once.
  - `rawInput.replace_all == true` sets `replaceAll`.
  - Paths are keyed like `TouchedPaths.key`: `/tmp/x` and `/private/tmp/x` are one file.
  - Folding the T003 fixture gives exactly `claude-edits.expected.json` (SC-002).
- [X] T006 Create `Pkg/Sources/AgentsKitCore/Model/AgentChanges.swift` with the wire types in data-model.md, all `Codable, Hashable, Sendable`:
  - `StartingPoint { repository: URL, commit: String }`
  - `ReportedEdit`, with fields `path`, `oldText: String?`, `newText`, `toolCallID`, `index`, `entryIndex`, `replaceAll`, `at`
  - `ChangeSource` (`reported`, `reportedAndSeen`, `seen`)
  - `ChangeState` (`modified`, `added`, `deleted`, `binary`)
  - `ChangedFile`, with the fields in data-model.md. `added`/`removed` are `Int?`, and are "Nil for binary".
  - `GitView` (`owned(since:)`, `shared(since:)`, `sharedFromHead`, `unavailable(ChangesUnavailable)`)
  - `ChangesUnavailable` (`notARepository`, `gitNotInstalled`, `folderGone`, `failed(String)`)
  - `DiffLine { kind: .context | .added | .removed, text, newLine: Int? }`
  - `FolderHunk { oldStart, newStart, noNewlineAtEnd, lines }`
  - `ChangesList { files, git, reportsEdits }`
  - `ChangedFileDetail { file, edits, hunks: [FolderHunk]?, whole: [DiffLine]? }`

  Enums with payloads encode as in contracts/changes.md (`{ "shared": { "since": … } }`).
- [X] T007 In `Pkg/Sources/AgentsKitCore/Model/Agent.swift`:
  - Add `public var startingPoint: StartingPoint?` after `worktree`, with a doc comment ("Where git's view of this agent's changes is measured from: the commit its folder was on when it started (035). Nil outside a repository, and for agents started before 035.").
  - Add it to `CodingKeys`, `init(from:)` (`decodeIfPresent`), `encode` (`encodeIfPresent`) and the memberwise init (default nil).

  Make T004 pass.
- [X] T008 Create `Pkg/Sources/AgentsKitCore/Model/ReportedChanges.swift`: `public struct ReportedChanges: Sendable, Equatable`.
  - `init()` and `init(entries:startIndex:)`.
  - `mutating func absorb(_ entry: TranscriptEntry, at index: Int)`, handling `.toolCall` and `.toolCallUpdate`. A call with no `toolCallID` is keyed by entry id.
  - `edits`, `inProgress: Set<String>`, `byFile: [(path: String, edits: [ReportedEdit])]` and `reportsEdits: Bool` (true once any diff has been seen). **Done. The `Transcript.swift` comment had already gone on main; only `ToolCallContent`'s was corrected.**

  Make T005 pass. While there, correct the out-of-date doc comments on `ToolCallContent` (`Pkg/Sources/AgentsKitCore/ACP/ToolCallContent.swift`) and on `view(for:)` in `App/Sources/Chat/Transcript.swift`: Claude does send structured diffs (research R1).
- [X] T009 In `Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`:
  - Add `Method.changesList = "changes/list"` and `Method.changesFile = "changes/file"`, each with a doc comment in the file's style ("Never polled; asked on the pane's triggers.").
  - Add `ChangesListRequest { agentID }` and `ChangesFileRequest { agentID, path, whole: Bool }`.
  - Add `Failure.notChanged`, with the next free code.
- [X] T010 Write `Pkg/Tests/AgentsKitTests/Integration/ChangesTests.swift`, first case only. A fake agent in a temp folder that isn't a repository emits the R1 sequence for `a.swift` twice and creates `b.md`. Expect:
  - `changes/list` gives `[a.swift (editCount 2, source reported, modified), b.md (added)]`, with `git == .unavailable(.notARepository)` and `reportsEdits == true`.
  - `changes/file` on `a.swift` gives two edits, in order.
  - `changes/file` on an unlisted path fails `notChanged`.
  - An agent that emitted nothing gives `files: []` and `reportsEdits: false`.
- [X] T011 Create `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Changes.swift`:
  - `var reportedChanges: [UUID: (fold: ReportedChanges, through: Int)]` on `DaemonCore`, declared in `DaemonCore.swift`.
  - `func reported(for agentID:) async throws -> ReportedChanges` builds the fold from `store` on first ask, paging through `store.transcript(for:before:limit:)` from the start, then caches it.
  - `func changesList(_:)` and `func changesFile(_:)`, answering from the fold only for now:
    - counts are summed per R8,
    - `state` is `added` when the first edit has no old text,
    - `deleted` when the file isn't on disk,
    - `outsideFolder` per R7,
    - `firstLine` is the first line of the current file that contains the last edit's first new line, or 1 for an added file.
  - `git` is `.unavailable(.notARepository)` until Phase 5. **Done, with one change: `reported(for:)` catches the fold up from the store by entry count on every ask, so T012's feed from `record(_:for:)` isn't needed (it would leave a gap while the first fold reads across an `await`). The held fold isn't dropped on archive: an archived agent's changes are still readable, and the fold is small.**
- [X] T012 Feed the fold as entries are written: in `DaemonCore.record(_:for:)` (`Pkg/Sources/AgentsKit/Daemon/DaemonCore.swift:434`), after `store.append`, absorb the entry into `reportedChanges[agentID]` **only if a fold is already held**. Drop the held fold in archive and delete. Add two cases to `DaemonCore+Dispatch.swift`. Make T010 pass. **Superseded by T011's catch-up: `record(_:for:)` is unchanged. Two dispatch cases added.**
- [X] T013 Record the starting point:
  - Add to `Pkg/Sources/AgentsKit/Projects/GitChanges.swift` (new file) `static func startingPoint(of folder: URL) async -> StartingPoint?`. It runs `git rev-parse --show-toplevel HEAD` with the read-only environment (T028 fills that environment in; for now `GIT_OPTIONAL_LOCKS=0`) and returns nil on any failure.
  - In `DaemonCore+Commands.swift`, set `agent.startingPoint` where the `Agent` is built (~:266), once `cwd` is final. A failure never fails the start.
  - In `DaemonCore+Runtimes.swift` `fork` (~:171), copy `agent.startingPoint`.
  - Extend T010 with two checks: a start in a git temp folder records `HEAD`'s SHA and the repository root; a start outside a repository records nil. **Done, but taken in the background right after the agent is registered (`takeStartingPoint`), not inside `start`. Awaiting git inside `start` (10–90 ms) made three timing-sensitive start tests fail every run (StartIdempotency `launchCount == 2`, two HelperAgent tests), where main passed six of six. `GitProcess` gained an `environment:` parameter.**

**Checkpoint**: `swift test` green. `changes/list` answers from reported edits for any agent, old
or new.

---

## Phase 3: User Story 1 — See every file the agent changed (P1) 🎯 MVP

**Goal**: A Changes pane listing the agent's reported files in order, with counts, and each file's
edits.

**Independent test**: A Claude agent edits two files and creates a third. Changes lists all three
in first-edit order, each with the edits the conversation shows, and the new file marked new.

- [X] T014 [US1] In `App/Sources/Sidebar/SidebarState.swift`:
  - Add `case changes` to `SidebarPane`, after `files`, with title "Changes" and symbol `plusminus`.
  - Add `ChangesSelection { path: String, toolCallID: String?, view: ChangesView }`, where `enum ChangesView { case edits, folder, whole }`.
  - Add `var changesSelection: ChangesSelection?` to `AgentPaneState`.
  - Update the "four panes" doc comments.
- [X] T015 [US1] In `App/Sources/AppModel.swift`:
  - Add `changes(for agentID:) async throws -> ChangesList` and `changeDetail(for:path:whole:) async throws -> ChangedFileDetail`, calling the two methods.
  - Add a coalescer, `ChangesRefresh`: at most one request in flight and one queued, per agent.
  - Add a published `changesRevision[agentID]`. It's bumped when an `agentEntry` for that agent carries a `toolCallUpdate` whose status is `completed` or `failed` and whose call carried a diff, and when the agent's state leaves `working` (FR-004, FR-018). **Done differently: AppModel has only the two calls. The triggers live in `ChangesPane` — it asks when shown (hidden panes stay alive in the ZStack, so it must not ask while hidden), when a tool call that carried a diff ends, and when the agent's state changes. Asking is `.task(id:)` on a revision, so a burst collapses into one request.**
- [X] T016 [P] [US1] In `App/Sources/Chat/DiffView.swift`, give `DiffView` a `maxHeight: CGFloat? = 280` parameter (nil means no cap) and a `showsPath: Bool = true`. Move the old/new line split into a `static func lines(for:)`, so the pane and the conversation draw the same lines. **`DiffView` has moved to `Shared/UI/Chat/ChatBlocks.swift` on main (033); the two parameters were added there. No `lines(for:)` split was needed.**
- [X] T017 [US1] Create `App/Sources/Sidebar/ChangesPane.swift`, `struct ChangesPane: View`, with `agent` and `state`. The list follows contracts/changes.md "List":
  - Rows keyed by `path`.
  - Name in body style, with the relative folder in `.fine`.
  - Marks `new`/`deleted`/`binary`.
  - Counts as `+n −m`, the minus in `.tertiary`.
  - `n edits`, and a progress mark while `inProgress`.
  - A total line above.
  - The empty state, "Nothing changed yet.", in the Files pane's `Gone` style (FR-010's wording comes in Phase 5).
  - Each row is a `.plain` Button that sets `state.changesSelection` (see memory: the card must be the Button).
  - It fetches on appear and on `changesRevision` changing, and keeps the scroll position: no `.id` reset, rows diffed by path.
- [X] T018 [US1] Create `App/Sources/Sidebar/ChangeFileView.swift`, the file detail:
  - A back control that clears `changesSelection`, the name and mark, and **Open in Files**. That sets `state.openFile`/`state.openLine` from `firstLine` and `frame.pane = .files` (FR-003).
  - Below that, a `LazyVStack` of the edits, each a `DiffView(diff:maxHeight: nil, showsPath: false)` headed by its time.
  - A file over 2,000 changed lines shows its count and a **Show changes** button first (FR-015).
  - It fetches `changes/file` on selection, and again only when that row's `editCount`/`added`/`removed` changed.
- [X] T019 [US1] In `App/Sources/Sidebar/SidebarView.swift` `pane(for:)`, add `ChangesPane` to the ZStack in the same opacity/hit-testing pattern, and make sure the pane picker shows five.
- [X] T020 [US1] Build `Agents`. With the **run-app** skill, on a scratch root copied from the live one, open an agent with many Claude edits and choose Changes. Take screenshots of the list, of a file, and of an agent with no edits. Check the order against the conversation by hand for one agent. **Done on a scratch root seeded with two copied agents: `changes/list` on a 6,305-line transcript answered in 0.8 s cold (27 files); screenshots in `screens/` (list, file, empty).**
- [X] T021 [US1] **Gate**: hand the T020 screenshots to Alex with `AskUserQuestion`, covering the list layout, the file layout, and whether a file should have two views or three (research R9). Record the answers in research.md R9 before Phase 4. **Answered 2026-09-24: group the list by folder; two views (Edits · Whole file). Recorded in research R9.**

**Checkpoint**: US1 works for every Claude agent, with no git involved.

---

## Phase 4: User Story 2 — From an edit in the conversation to the pane (P2)

**Goal**: Pressing an edit in the conversation opens Changes at that edit.

**Independent test**: In a conversation with edits to three files, press the second edit to the
middle file. The sidebar opens on Changes, with that file chosen and that edit in view.

- [ ] T022 [US2] In `App/Sources/Chat/Transcript.swift` `view(for:)` (~:573), wrap `DiffView` for `.diff` in a `.plain` Button, with the tool call's id passed down from the enclosing call view. Pressing it:
  - opens the sidebar if it's closed,
  - sets `frame.pane = .changes`,
  - sets `states.state(for: agent.id).changesSelection = .init(path: diff.path, toolCallID: call.toolCallID, view: .edits)`.

  Add `.help("Show in Changes")`. Check that text selection inside the diff still works; if the Button swallows it, move the press to a header row.
- [ ] T023 [US2] In `ChangeFileView.swift`, when `changesSelection.toolCallID` is set, give each edit `.id("\(toolCallID)#\(index)")`, scroll to the first match once the detail loads, and outline it once, by weight, not colour. If the call isn't among the edits (in progress or failed), show the first edit.
- [ ] T024 [US2] Extend `ChangesTests.swift`: a reported file deleted from disk afterwards has `state == .deleted`, and `changes/file` still returns its edits (US2 scenario 2).
- [ ] T025 [US2] With run-app, press an edit in a scratch conversation with the sidebar closed. Screenshot the result.

---

## Phase 5: User Story 3 — Changes the runtime did not report (P2)

**Goal**: In a git repository, git's view fills in what ACP didn't say. It's marked, and never
claimed as the agent's in a shared folder.

**Independent test**: A Grok agent edits a file in a git project, and the file is listed with git's
view. A Claude agent runs a formatter; the formatted files appear marked *in the folder*, and a
reported file changed by it says so.

- [ ] T026 [P] [US3] Write `Pkg/Tests/AgentsKitTests/Unit/UnifiedDiffTests.swift` for the parsers in `GitChanges`:
  - Hunk headers with and without counts (`@@ -1 +1 @@`).
  - `\ No newline at end of file`, which sets `noNewlineAtEnd` and isn't a line.
  - `newLine` numbering.
  - An empty diff.
  - `--numstat -z` with `-\t-` (binary).
  - `--name-status -z` with `A`/`D`/`M`.
  - A path with spaces and a non-ASCII path under `-z`.
- [ ] T027 [P] [US3] Write `Pkg/Tests/AgentsKitTests/Unit/EditReplayTests.swift`, one test per R5 rule:
  - Two edits over the start text reproduce the disk: accounted for.
  - Extra disk change: beyond reported.
  - An edit whose old text equals the whole current text (a Write) replaces all of it.
  - `replaceAll` replaces every occurrence, and without it only the first.
  - An old text that isn't found stops the replay: beyond reported.
  - A first edit with no old text starts from empty.
- [ ] T028 [US3] Complete `Pkg/Sources/AgentsKit/Projects/GitChanges.swift`:
  - The read-only environment: `GIT_OPTIONAL_LOCKS=0`, plus `-c core.quotepath=off` and `--no-ext-diff --no-textconv --no-color --no-renames` on every diff.
  - Functions for each row of R4's table: `numstat(since:in:)`, `nameStatus(since:in:)`, `untracked(in:)`, `blobs(_ specs: [String], in:)` (one `cat-file --batch`, parsing `<sha> <type> <size>\n<bytes>\n` and `missing`), `hunks(since:path:in:)` and `whole(since:path:in:)` (`-U` set to the file's line count + 1).
  - The parsers.

  It runs through `GitProcess`. Nothing in it writes. Make T026 pass.
- [ ] T029 [US3] Create `Pkg/Sources/AgentsKit/Projects/EditReplay.swift`: `enum EditReplay { static func accounts(for edits: [ReportedEdit], start: String, now: String) -> Bool }`, per R5. Make T027 pass.
- [ ] T030 [US3] Extend `ChangesTests.swift` with the git rows of quickstart §2:
  - reported and seen, with `c.swift` seen and `a.swift` beyond reported after a rewrite;
  - a commit keeps a file listed;
  - `shared` in the project folder; `owned` in an app-made worktree with one agent; `shared` with two agents in one worktree;
  - `sharedFromHead` with no `startingPoint`;
  - binary;
  - outside the folder, never given to git (checked with `GIT_TRACE=<file>` set on the daemon's git environment for the test);
  - the runtime reporting nothing outside a repository: `files: []`, `reportsEdits: false`, `unavailable`.
- [ ] T031 [US3] Write the SC-005 test in `ChangesTests.swift`: record `.git/index` bytes and mtime and `git status --porcelain` output, call `changes/list`, `changes/file`, and `changes/file whole: true` three times each, and check that all three are unchanged. Also check that `.git/index.lock` never appears (watch it with a `DispatchSource` during the calls).
- [ ] T032 [US3] In `DaemonCore+Changes.swift`, merge git into `changesList`:
  - Resolve the measure: `startingPoint` if `repository` still exists, else `HEAD` (`sharedFromHead`).
  - Ownership per R6: `worktree != nil` and no other unarchived agent's `cwd` under `worktree.root`.
  - Run numstat, name-status and untracked, each once. Join paths to the repository root, and merge by resolved path (R7): `reported` → `reportedAndSeen`, and add `seen` rows sorted by path after the reported ones (R8).
  - Take counts from git where present.
  - Run the replay for every `reportedAndSeen` row using one `blobs` call, setting `beyondReported`.
  - Handle no git or git failing: `unavailable(…)`, with the reported rows kept.

  In `changesFile`, fill `hunks` from git for rows in the repository. For untracked files, read the file and produce all-added lines. Make T030 and T031 pass.
- [ ] T033 [US3] In `ChangesPane.swift`:
  - The source line above the list (contracts "List": shared / sharedFromHead / nothing).
  - The `in the folder` and `changed since` row marks.
  - FR-010's combined message when `files` is empty, `reportsEdits` is false and git is unavailable. Name the runtime from `agent.runtimeID`, and give the reason from `ChangesUnavailable`.
- [ ] T034 [US3] In `ChangeFileView.swift`:
  - The **In the folder** view: hunks drawn with `DiffView`'s marks, plus line numbers in `.tertiary`.
  - For `beyondReported`, the one-line notice with a link that switches to it.
  - A `seen` file opens straight on **In the folder**.
- [ ] T035 [US3] With run-app, in a scratch git repository, take screenshots of a shared-folder agent with a formatter's changes and of a non-git, no-diffs case.

---

## Phase 6: User Story 4 — The whole file, as it now stands (P3)

**Goal**: In a git repository, the whole current file with changed lines marked and removed lines
in place.

**Independent test**: Three reported edits to one file in a git repository. Whole file marks every
changed line and nothing else.

- [ ] T036 [US4] Extend `ChangesTests.swift`: after three edits, `changes/file whole: true` returns every current line once, the changed lines as `added`, the old lines as `removed` in place, and no other marks. Outside a repository, `whole` is nil.
- [ ] T037 [US4] In `DaemonCore+Changes.swift` `changesFile`, fill `whole` when asked, using `GitChanges.whole`. For an untracked file it's all `added`. Make T036 pass.
- [ ] T038 [US4] In `ChangeFileView.swift`:
  - Add the view picker from R9, as settled at T021. Show only the views that exist: Edits if there are reported edits, In the folder and Whole file if there's git.
  - Fetch `whole` on first choice.
  - Draw it in a `LazyVStack`, keeping the 2,000-line **Show changes** guard.
- [ ] T039 [US4] With run-app, screenshot Whole file on a file with three edits. In a non-git folder, confirm the picker doesn't offer it.

---

## Phase 7: Polish and proof

- [ ] T040 Quickstart §3: one live agent each for Claude, Copilot, Cursor and Grok on a scratch daemon in `/tmp/cd-035/repo`.
  - Read `changes/list` off the scratch `daemon.sock`.
  - Record in research.md R1: each runtime's diff shape, and whether it repeats diffs.
  - **Stop and ask Alex** if a runtime's shape breaks the fold.
- [ ] T041 SC-004 measurement:
  - Set up a scratch repository with a fake-runtime agent that reports edits to 200 files.
  - Time `changes/list` (under 1s) and `changes/file` on the largest (under 0.5s) over the socket, three runs each.
  - Write the numbers into quickstart §4.
  - If the numbers miss, profile the first fold before touching git.
- [ ] T042 [P] Build `Agents`, then `Remote`, one after the other, with plugin validation skipped. `Remote` only has to compile.
- [ ] T043 Run the full `swift test` against T001's baseline. If anything new fails, compare six runs on both commits before blaming the branch (see memory: the suite is broadly flaky).
- [ ] T044 Quickstart §4 end to end with run-app, steps 1–7, with screenshots saved under `/tmp/cd-035/shots/` and listed in the handover.

---

## Dependencies

- **Setup (T001–T003)** comes first. T002 and T003 can run in parallel.
- **Foundational (T004–T013)** blocks every story.
  - T004 and T005 can run in parallel.
  - T006 comes before T007 and T008, and T009 before T011.
  - T010 comes before T011 and T012.
  - T013 can run after T007, alongside T011/T012.
- **US1 (T014–T021)** depends on Foundational. T016 can run in parallel with T014/T015. **T021 is a
  gate**: nothing in Phases 4–6 starts before Alex has seen the screenshots.
- **US2 (T022–T025)** depends on US1's pane (T017, T018). It doesn't need US3.
- **US3 (T026–T035)** depends on Foundational and on US1's pane for T033/T034.
  - T026 and T027 can run in parallel, then T028/T029, then T030–T032.
  - It's independent of US2.
- **US4 (T036–T039)** depends on T028 (`GitChanges`) and T032.
- **Polish (T040–T044)** comes after all stories. T042 can run alongside T040/T041.

Story order: US1 → (US2 ∥ US3) → US4.

## Parallel examples

- **Setup**: T002 (fake helpers) ∥ T003 (fixture).
- **Foundational**: T004 (record tests) ∥ T005 (fold tests), then T006 → T007 ∥ T008.
- **US1**: T016 (DiffView) ∥ T014/T015 (state and model).
- **US3**: T026 (diff parsing tests) ∥ T027 (replay tests), then T028 ∥ T029.
- **After T021**: US2 (T022–T025) ∥ US3 (T026–T032). They touch different files, except that
  `ChangeFileView.swift` is shared by T023 and T034, so do those one after the other.

## Implementation strategy

1. **MVP = Phases 1–3**: reported edits only, in a pane, for every Claude agent. It's useful on
   its own, it answers the spec's P1 story, and it's the thing to settle with Alex at T021 before
   any depth.
2. **Then US3** for correctness, because a list that's sometimes incomplete can't be trusted.
   **US2** can go alongside it.
3. **Then US4**, which is small once `GitChanges` exists.
4. **Phase 7** proves it running: live runtimes, timings, both builds, and the full walk.
