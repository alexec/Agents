# Tasks: An Agent Can Work in a Worktree of Its Own

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/worktrees.md](contracts/worktrees.md), [quickstart.md](quickstart.md)

**Tests**: Included. The quickstart names each property to be tested, and this repo tests every
daemon behaviour. Write each test before the code that makes it pass. Integration tests use real
temporary git repositories (`git init` in a temp folder, one commit) and the fake runtime.
Model them on `Pkg/Tests/AgentsKitTests/Integration/HelperAgentTests.swift`.

**Where**: Everything runs in the worktree `/tmp/w-030` on branch `030-agent-worktrees`. Never
edit the shared checkout at `/Users/alexcollins/Agents`. Paths are relative to `/tmp/w-030`.
`Pkg/` stands for `Packages/AgentsKit/`.

**Gates**:
- **After Phase 3**: a live run of all four runtimes. Stop and bring anything that fails to Alex.
- **After Phase 4**: screenshots of the start bar and the row. Settle the layout with Alex before
  going on (see memory: settle the UX before building depth).

## Phase 1: Setup

- [X] T001 Confirm the baseline in `/tmp/w-030`: run `swift test` in `Packages/AgentsKit` once, and write down which tests fail on main before any change. **Baseline at `9a9c7d9`: 1310 tests in 145 suites, all passing, 42s.**

---

## Phase 2: Foundational (blocks every story)

The record, the name, the filing. Nothing behaves differently yet for an agent without a worktree.

- [X] T002 [P] Write `Pkg/Tests/AgentsKitTests/Unit/WorktreeNameTests.swift`:
  - "Fix the login redirect on Safari" gives `fix-login-redirect-safari`.
  - "Please can you add tests for the parser?" gives `add-tests-parser`.
  - An emoji-only or empty prompt gives `agent-MMdd-HHmm` (inject the date).
  - A long prompt gives at most 32 characters, cut at a hyphen, never ending in `-`.
  - `WorktreeName.next(after: "x", taken: ["x", "x-2"])` gives `x-3`.
- [X] T003 [P] Write `Pkg/Tests/AgentsKitTests/Unit/AgentWorktreeRecordTests.swift`:
  - An `Agent` with a `worktree` round-trips.
  - A record without the key decodes with `worktree == nil` and `projectFolder == Project.standardize(cwd)`.
  - With a worktree, `projectFolder == Project.standardize(worktree.project)`.
  - `WorktreeChoice.new` and `.existing(url)` round-trip.
- [X] T004 Create `Pkg/Sources/AgentsKitCore/Model/AgentWorktree.swift` with three types:
  - `public struct AgentWorktree: Codable, Hashable, Sendable`, with fields `name: String`,
    `root: URL`, `branch: String?`, `project: URL`, `base: String?` and `madeByApp: Bool`, as in
    data-model.md.
  - `public enum WorktreeChoice: Codable, Hashable, Sendable { case new; case existing(URL) }`.
  - `public enum WorktreeName`, with:
    - `static let branchPrefix = "agents/"`, `static let folder = ".agents/worktrees"` and
      `static let maxLength = 32`.
    - `static func from(prompt: String, now: Date = Date()) -> String`, per research R3, with its
      filler-word list.
    - `static func next(after: String, taken: Set<String>) -> String`.

  Make T002 pass.
- [X] T005 In `Pkg/Sources/AgentsKitCore/Model/Agent.swift`:
  - Add `public var worktree: AgentWorktree?` after `chainDepth`, with a doc comment ("The worktree
    this agent was started in. Its project is the worktree's project, not its cwd.").
  - Add it to `CodingKeys`, `init(from:)` (`decodeIfPresent`), `encode` (`encodeIfPresent`) and
    the memberwise init (default nil).
  - Add `public var projectFolder: URL { Project.standardize(worktree?.project ?? cwd) }`.

  Make T003 pass.
- [X] T006 Switch every use that means *the agent's project* from `cwd` to `projectFolder`, per research R5:
  - `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift` (grouping, and archiving a project
    with live agents).
  - `DaemonCore.swift` (`projectChanged(forAgentIn:)`).
  - `DaemonCore+Attention.swift` (both).
  - `DaemonCore+Workflows.swift`.
  - `DaemonCore+AppTools.swift`.
  - `DaemonCore+Helpers.swift` (three).
  - `Pkg/Sources/AgentsKitCore/Model/HelperLimit.swift`.
  - `Pkg/Sources/AgentsKitCore/Client/AgentsModel.swift` (`projectFolder(of:)`).
  - `App/Sources/AppModel.swift` (selecting the project), `App/Sources/Projects/WorkflowPage.swift`
    and `App/Sources/AgentList/AgentRow.swift`.
  - `Remote/Sources/RemoteModel.swift`.

  Don't touch launch, `continueSession`, `FilesPane`, `folderScope`, shells or session lists: they
  mean *where it works*. Grep afterwards for `standardize($0.cwd)` and `standardize(agent.cwd)`,
  and justify any that are left.
- [X] T007 [P] Add a filing test to `Pkg/Tests/AgentsKitTests/Unit/HelperLimitTests.swift` and `AgentsModelTests.swift`:
  - A helper whose `worktree.project` is the project, but whose `cwd` is elsewhere, counts
    toward the project's places.
  - `AgentsModel.agents(in: project, …)` returns it.
- [X] T008 [P] In `Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`:
  - Add `worktree: WorktreeChoice?` to `StartRequest` and `StartHelperRequest`
    (`decodeIfPresent`, init default nil).
  - Add `Failure.worktreeFailed`, `.worktreeMissing`, `.notAWorktree` and `.worktreeInUse`, with
    the next free codes.
  - Add `Method.worktreesList = "worktrees/list"`, `worktreesCheck = "worktrees/check"` and
    `worktreesRemove = "worktrees/remove"`.
  - Add `WorktreesListRequest { folder }`, `WorktreesListResponse { isRepository, canMakeNew,
    whyNot, worktrees }`, `WorktreeSummary`, `WorktreeRemovalRequest { project, root, confirmed }`,
    `RemovalCheck` and `WorktreeRemoved { removedBranch }`, per data-model.md, all with lenient
    decoding.
- [X] T009 [P] Create `Pkg/Sources/AgentsKit/Projects/GitWorktrees.swift`: an `enum GitWorktrees` of async functions over `GitProcess`, one for each row of research R10:
  - `repository(of:) -> (toplevel: URL, prefix: String, commonDir: URL)?`
  - `hasCommit(in:)`
  - `base(in:) -> String?`
  - `add(branch:path:in:)`
  - `list(in:) -> [Entry]`
  - `statusCount(in:)`
  - `isAncestor(_:of:in:)`
  - `remove(_:force:in:)`
  - `deleteBranch(_:force:in:)`
  - `ensureExcluded(commonDir:)`, which appends `/.agents/worktrees/` to `info/exclude` if absent
    and creates `info/` if needed.

  Each throws `GitWorktrees.Failure(message:)` carrying git's stderr. `Entry` is parsed from
  `--porcelain` by a pure `static func parse(_ porcelain: String) -> [Entry]`.
- [X] T010 [P] Write `Pkg/Tests/AgentsKitTests/Unit/GitWorktreesTests.swift`: `parse` on porcelain covering the main worktree, a branch, a detached entry, a `locked` entry and a `prunable` entry.

**Checkpoint**: `swift test` matches T001 plus the new passing tests, and both schemes build.

---

## Phase 3: User Story 1 — Start an agent in a new worktree (P1, daemon) 🎯 MVP

**Goal**: `agents/start` with `worktree: new` makes a worktree and starts the agent in it, filed under the project.

**Independent Test**: Over the socket, start with `worktree: new`. Then check four things: the
worktree and branch exist, the runtime's cwd is the worktree, the agent is filed under the
project, and the project's git status is clean.

- [X] T011 [US1] Write `Pkg/Tests/AgentsKitTests/Integration/WorktreeStartTests.swift`, for the US1 part. Each test uses a real temp repo with one commit and the fake runtime:
  - `new` makes `<repo>/.agents/worktrees/<name>` on `agents/<name>`.
  - The fake launcher and `session/new` both got that folder.
  - `agent.worktree` is filled in, with `madeByApp`, and `base` equal to the repo's branch.
  - `allProjects()` has one project, and it counts the agent.
  - `info/exclude` holds the line, and `git status --porcelain` in the repo is empty.
  - The first chat line is `Working in worktree <name> on agents/<name>, from <base>.`
- [X] T012 [US1] Add these to `WorktreeStartTests.swift`:
  - **Subfolder project**: with project `repo/app`, the cwd is `<wt>/app`.
  - **No commit**: the start is refused with `worktreeFailed`, and no agent is saved.
  - **Failing `post-checkout` hook**: `worktreeFailed` with git's message, no agent, and no live
    runtime.
  - **Concurrency**: two `new` starts from the same prompt, whose fake handshakes wait, give two
    distinct names and branches.
  - **Resume**: with the worktree folder deleted, picking the agent up throws `worktreeMissing`,
    and the launcher is never called.
- [X] T013 [US1] Create `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Worktrees.swift` with `func prepareWorktree(_ choice: WorktreeChoice, from project: URL, prompt: String) async throws -> (cwd: URL, worktree: AgentWorktree)`. For `.new`:
  1. Resolve the repository.
  2. Refuse if it has no commit.
  3. Pick a name with `WorktreeName.from`, then `next`, against existing folders, `refs/heads/agents/*` and `reservedWorktreeNames`.
  4. Reserve the name before the first `await`.
  5. `ensureExcluded`.
  6. `add`, retrying the next name up to 20 times if git reports the branch exists.
  7. Release the reservation in `defer`.
  8. Return cwd = `root` + `prefix`.

  Map every git failure to `JSONRPCError(code: .worktreeFailed, message: git's words)`. `.existing`
  isn't handled yet; it throws `notAWorktree` until US2. Add
  `var reservedWorktreeNames: Set<String> = []` to `DaemonCore.swift`.
- [X] T014 [US1] In `DaemonCore+Commands.swift` `start(_:)`:
  - When `request.worktree != nil`, call `prepareWorktree` before the draft check, and use its
    `cwd` everywhere below in place of `request.cwd`, so the draft is discarded and `freshSession`
    launches in the worktree.
  - Pass `worktree` into the `Agent` initialiser.
  - After saving, record the first chat line as a runtime note.
  - In `liveSession(for:)`, before launching: if `agent.worktree != nil` and `cwd` isn't a
    directory, throw `worktreeMissing` with "The worktree ‹name› is gone, so this agent cannot be
    picked up where it was."
  - Make T011 and T012 pass.
- [X] T015 [US1] **Gate: live run (quickstart §3).**
  1. Build `agentsd` from the worktree and run it on a scratch root.
  2. For each of Claude, Grok, Copilot and Cursor, start with `worktree: new` in
     `/tmp/wt-030/repo`, with the prompt "Create a file called proof-<runtime>.txt containing your
     working directory."
  3. Record the results in this task.

  If any runtime writes outside its worktree, stop and bring it to Alex.

  **Result, 2026-09-24 (scratch root `/tmp/run-w030`, repo `/tmp/wt-030/repo`): passed for all four.**

  | Runtime | Worktree | File written | Contents |
  |---|---|---|---|
  | Claude | `create-file-called-proof` | in the worktree | the worktree's path |
  | Grok | `create-file-called-proof-2` | in the worktree | the worktree's path |
  | Copilot | `create-file-called-proof-3` | in the worktree | the worktree's path |
  | Cursor | `create-file-called-proof-4` | in the worktree | the worktree's path |

  - Nothing was written in the project folder, and its `git status` was clean.
  - `projects/list` showed one project with four agents.
  - The four starts, 10 s apart and all from the same words, got four distinct names.
  - Side note, not caused by worktrees: Claude Code writes `.claude/settings.local.json`
    (allowing `mcp__agents__finish_turn`) at the project root. A control run in a plain repo
    with no worktree wrote the same file. For a worktree it goes to the main checkout's root,
    which Claude Code treats as the project. It's ignored here by the global git ignore.

**Checkpoint**: The MVP daemon works for all four runtimes.

---

## Phase 4: User Story 1 — Start an agent in a new worktree (P1, Mac UI)

- [X] T016 [US1] In `Pkg/Sources/AgentsKitCore/Model/Draft.swift`, add `worktree: WorktreeChoice?` to `StartDraft` (default nil). In `App/Sources/AppModel.swift`:
  - Add a `draftWorktree` accessor.
  - Send it as `StartRequest.worktree` in `startDraft`.
  - Reset it to nil after a successful start (FR-004).
  - Fetch and keep a `WorktreesListResponse` for the draft folder whenever `draftCwd` changes,
    once per change, never polled. `worktrees/list` isn't there until T021, so until then derive
    only `isRepository` by trying the call and treating failure as not-a-repository.
  *Done differently:* the choice lives on `AppModel.draftWorktree` only, not in `StartDraft`. `StartDraft` is the form kept across launches, and a worktree is decided per agent (FR-004). `worktrees/list` (T021's daemon half) was built here, because the chooser needs `isRepository`. Also fixed: `PromptBar.prepare()` defaulted the folder to an agent's `cwd`; it now uses the agent's project. And `fork` now carries the worktree, with a test, so a branch isn't filed as a project of its own.
- [X] T017 [US1] In `App/Sources/Chat/PromptBar.swift`, add the **Worktree** `SelectCapsule` right after the folder button, per contracts/worktrees.md:
  - Shown only when the folder is a repository, including on a project page (FR-005).
  - Choices are Project folder and New worktree, with the descriptions from the contract.
  - New worktree is disabled with `whyNot` when it can't be made.
- [X] T018 [P] [US1] In `App/Sources/AgentList/AgentRow.swift`, add the badge after the title: `arrow.triangle.branch` plus `worktree.name`, `.appText(.fine)`, secondary colour, with the tooltip `branch — path`. Nothing shows when `worktree` is nil.
- [X] T019 [US1] **Gate: see it (quickstart §4 steps 1–2).**
  1. Build the Agents scheme and launch it on a scratch root with the run-app skill.
  2. Start an agent in a new worktree.
  3. Screenshot the start bar with the Worktree capsule open, the agent's row with its badge, and
     the start bar after the start, reading Project folder again.
  4. Show the screenshots to Alex and settle the layout before Phase 5.

  **Result, 2026-09-24:** the capsule was seen closed, open, and set to New worktree
  (`/tmp/run-w030-1.png` to `-3.png`). The screen locked before the row badge and the reset
  could be captured; those go into T030. Alex settled the layout from the capsule: "Layout is
  fine, carry on."

**Checkpoint**: US1 is done end to end on the Mac.

---

## Phase 5: User Story 2 — Start in a worktree that already exists (P2)

**Independent Test**: A worktree made with `git worktree add` in a terminal is listed. Choosing it starts an agent there, filed under the project.

- [X] T020 [US2] Add these to `WorktreeStartTests.swift`:
  - `worktrees/list` on a plain folder gives `isRepository: false`.
  - On a repo with a terminal-made worktree, a missing one and an app-made one, it gives the
    right `exists`, `madeByApp` and `agents` for each.
  - A start with `existing` works, reusing a draft made with that cwd.
  - `existing` with another repo's folder gives `notAWorktree`.
  - `existing` with a missing folder gives `worktreeMissing`.
- [X] T021 [US2] In `DaemonCore+Worktrees.swift`:
  - Add `listWorktrees(for folder:) -> WorktreesListResponse`, per data-model.md and research R6.
    `agents` is the IDs of agents that aren't archived and whose `cwd` is inside `root`.
  - Handle `.existing(url)` in `prepareWorktree`: find it in the list, refuse if it isn't there
    or is missing, and set `madeByApp` by R6 and `base` to nil.
  - Add the `worktrees/list` case in `DaemonCore+Dispatch.swift`.
  - Make T020 pass.
- [X] T022 [US2] In `AppModel.swift`, use `worktrees/list` for the draft folder. In the `PromptBar.swift` capsule:
  - After a divider, list each worktree that isn't the project folder, with its name and
    `branch · N agents working` (or `detached`). A missing one is disabled and says "Missing".
  - Choosing one sets `.existing(root)`, and the options request is sent with that root as
    `cwd`, so the draft is reused (research R2).

---

## Phase 6: User Story 3 — Cleaned up by choice, never by accident (P2)

**Independent Test**: Archiving leaves the worktree. Remove from the project page removes it, after confirmation when there's work to lose.

- [X] T023 [US3] Add these to `WorktreeStartTests.swift`:
  - Archiving an agent leaves its worktree and branch.
  - `worktrees/check` reports `blockedBy`, `uncommitted` and `unmerged` correctly.
  - `worktrees/remove` is refused with `worktreeInUse` while an agent that isn't archived is
    there, refused with `notAWorktree` for a terminal-made worktree, and refused when
    `confirmed: false` and there's something to lose.
  - A clean, merged worktree is removed with its branch.
  - A confirmed, dirty one is removed with `--force` and `-D`.
- [X] T024 [US3] In `DaemonCore+Worktrees.swift`, add `checkWorktreeRemoval` and `removeWorktree` per contracts/worktrees.md and research R7, with the base from any agent record naming the worktree, else the project folder's current branch. Send `projectChanged` after removing. Add the dispatch cases, and make T023 pass.
- [X] T025 [US3] Create `App/Sources/Projects/WorktreeRow.swift` (name, branch, agents, **Remove…**), and add a **Worktrees** section to `App/Sources/Projects/ProjectAgentsView.swift`. It lists only `madeByApp` worktrees, and is hidden when there are none. Remove… does the following:
  1. Calls check.
  2. If blocked, shows the agents with no confirm button.
  3. If there's something to lose, confirms, naming what.
  4. Removes, then refreshes the list.

---

## Phase 7: User Story 4 — An agent can start its helpers in worktrees (P3)

- [X] T026 [US4] Add these to `Pkg/Tests/AgentsKitTests/Integration/HelperAgentTests.swift`:
  - `startHelper` with `worktree: .new` gives a helper in a new worktree, counted in the caller's
    project.
  - An unknown worktree name is refused with the daemon's message.
- [X] T027 [US4] Wire the choice through:
  - Add the `worktree` string property to the `start_agent` schema in
    `Pkg/Sources/AgentsKit/ACP/Serve/AppService.swift`, with the contract's description text.
  - Relay it in `Daemon/Sources/main.swift` into `StartHelperRequest.worktree`: `"new"` becomes
    `.new`, and any other name is resolved by the daemon.
  - In `DaemonCore+Helpers.swift`, resolve a name against `listWorktrees`, then call the same
    `prepareWorktree`. Its result text adds "It is working in worktree ‹name› on ‹branch›."
  - Make T026 pass.

---

## Phase 8: Polish, phone and proof

- [X] T028 [P] In `Remote/Sources/Projects/AgentCard.swift`, add the same badge as T018.
- [X] T029 Run the full `swift test` and compare with T001. Build both schemes, one after the other, with plugin validation skipped.
- [X] T030 Run quickstart §4 steps 3–6 with the run-app skill, with screenshots: an existing worktree, a plain folder with no chooser, cleanup before and after, and a restart.
  **Result, 2026-09-24**, on scratch root `/tmp/run-w030` with repo `/tmp/wt-030/repo`:
  - **Start from the window**: an agent was started from the window in a new worktree
    (`use-manage-workflows-tool`). Its row shows the badge, and the capsule went back to
    Project folder (`/tmp/run-w030-7.png`).
  - **Chooser**: it lists existing worktrees, with "· 1 agent working" on the one in use
    (`-8.png`).
  - **Remove with work to lose**: Remove… asked first, naming "1 uncommitted change" and the
    branch (`-9.png`). Confirmed, the worktree and its branch were removed, and the section went
    from 5 to 4 (`-10.png`).
  - **Remove while in use**: refused, naming the agent (`-11.png`).
  - **No git**: a folder with no git gives `isRepository: false` over the socket. The sidebar row
    can't be pressed over AX, so this wasn't seen in the window.
  - **Restart**: after quitting and relaunching, the agent was still under `repo`. Prompting it
    again wrote `resumed.txt` inside its worktree.
  - *Harness notes*:
    - `ui.swift set` shows text in the prompt field but doesn't reach its binding, so Send did
      nothing. The workflows example link was used to fill the prompt instead.
    - `ui.swift press "Send"` hits the "Send to Claude" Services menu item; `"Send | Send"` hits
      the button.

- [ ] T031 Boot the Remote app against the scratch root, and screenshot a project with a worktree agent (quickstart §5).
  **Not done.** The phone app would have to be connected to the scratch daemon and the Simulator
  screenshotted. That's left for Alex, alongside 028's phone shot, which is open for the same
  reason. The phone badge compiles, and the Remote scheme builds.


---

## Dependencies

- Phase 2 blocks everything.
- Phase 3 (US1 daemon) blocks Phase 4, and it has the live gate.
- Phase 4 has the UX gate, which blocks Phases 5 and 6.
- US2 (Phase 5) blocks US3's "agents in it" check and US4's name resolution, because both use
  `listWorktrees`.
- US3 and US4 are independent of each other.
- Phase 8 comes last.

## Parallel opportunities

- Phase 2: T002, T003, T008, T009 and T010 are in different files. T007 follows T005.
- Phase 4: T018 alongside T016 and T017.
- Phase 8: T028 alongside T029.

## Implementation strategy

The MVP is Phases 1 to 4: an agent can be started in a new worktree from the Mac, filed under
its project, on all four runtimes. Stop at each gate. US2 and US3 come next, as the two P2s. US4
comes last.
