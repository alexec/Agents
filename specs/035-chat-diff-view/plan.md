# Implementation Plan: What the Agent Changed, Beside the Conversation

**Branch**: `035-chat-diff-view` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/035-chat-diff-view/spec.md`

## Summary

The right sidebar gets a fifth pane, **Changes**. Its list is built by the daemon, not the window,
because the window holds only a page of the transcript and the list has to be complete (SC-002).

The daemon folds each agent's transcript into **reported changes**. It keeps the *last* diff each
tool call carried, and only from calls that completed. A Claude tool call sends its diff two or
three times. An early copy of a Write over an existing file has no old text, so it looks like a
new file. 16 failed calls carry diffs too (research R1).

Where the agent's folder is in a git repository, the daemon also asks git, read-only
(`GIT_OPTIONAL_LOCKS=0`, R4), what differs from the agent's **starting point**. That's a commit
recorded when the agent starts: a new field on the record, R3. Both answers are merged into one
list of changed files, each marked as reported, seen in the folder, or both.

A reported file whose disk text doesn't match its reported edits replayed over the starting point
is marked **changed beyond what was reported** (R5).

Two daemon methods serve it:
- `changes/list` returns the files and their counts.
- `changes/file` returns one file's edits, git's hunks and, on request, the whole file.

The window asks again on opening the pane, on a completed edit arriving, and on the turn ending.
There's no timer (FR-018).

An edit in the conversation becomes a button that opens the pane at that edit.

See [research.md](research.md) for the decisions, [data-model.md](data-model.md) for the types,
and [contracts/changes.md](contracts/changes.md) for the methods and the pane.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), SwiftUI

**Primary Dependencies**:
- AgentsKit / AgentsKitCore (in-repo package)
- The person's own `git` through `GitProcess` (027, 030)
- ACP transcripts already on disk

**Storage**:
- One optional field on agent records, `startingPoint` (repository root and commit).
- Reported changes are folded from `transcript.jsonl` and held in memory. Nothing new is written.

**Testing**:
- swift-testing in `Packages/AgentsKit`: Unit tests for the fold, diff parsing and replay.
  Integration tests with a fake runtime and real temporary git repositories.
- A fixture check against a real Claude transcript of at least 50 edits (SC-002).
- xcodebuild for both schemes.
- The run-app skill for the pane itself.

**Target Platform**: The macOS app and the `agentsd` daemon. The wire types live in AgentsKitCore,
so 034's phone sheet can use them later. No phone UI here.

**Project Type**: Desktop app with a daemon

**Performance Goals**:
- `changes/list` for 200 files in under a second (SC-004). That's one transcript fold (cached)
  and two git processes: one `diff --numstat -z`, one `ls-files --others -z`. Plus one
  `cat-file --batch` for the replay check.
- `changes/file` in under half a second.

**Constraints**:
- git never writes to the repository (FR-017, SC-005).
- Nothing outside the agent's folder is passed to git.
- Change is shown by mark and weight, not colour (FR-013).
- Old agent records still decode, and an agent with no starting point falls back to `HEAD`.

**Scale/Scope**:
- Two methods, one record field, one fold, and a small unified-diff parser.
- One pane, one entry point from the conversation.

## Constitution Check

The constitution (`.specify/memory/constitution.md`) is still the unfilled template, so there are
no gates to check. The plan follows the repo's working rules:

- **Settle the UX before depth**: Phase 2 builds the pane over reported edits only, with no git.
  It's screenshotted with the run-app skill and settled with Alex before git, the replay check
  or Whole file are built.
- **One path, not two**: the pane and a future phone sheet read the same daemon answer. The
  conversation's `DiffView` draws reported edits in both places.
- **Prove it running**: quickstart §3 runs each runtime once for real, which the spec asks for.
  §4 runs the pane on a scratch daemon.

Re-checked after design: still no violations.

## Project Structure

### Documentation (this feature)

```text
specs/035-chat-diff-view/
├── spec.md
├── plan.md              # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── changes.md
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/AgentChanges.swift         # NEW: ChangedFile, ReportedEdit, FolderHunk, ChangeSource, StartingPoint, ChangesUnavailable
├── Model/ReportedChanges.swift      # NEW: the transcript fold (last diff per call, completed only)
├── Model/Agent.swift                # startingPoint field
└── Daemon/DaemonAPI.swift           # changes/list, changes/file; request and reply types

Packages/AgentsKit/Sources/AgentsKit/
├── Projects/GitChanges.swift        # NEW: the read-only commands (R4), numstat/ls-files/cat-file parsing, unified-diff parser
├── Projects/EditReplay.swift        # NEW: replay reported edits over the starting text (R5)
└── Daemon/
    ├── DaemonCore+Changes.swift     # NEW: per-agent fold cache, list, file, ownership (R6)
    ├── DaemonCore+Commands.swift    # record startingPoint at start
    ├── DaemonCore+Runtimes.swift    # fork copies startingPoint
    ├── DaemonCore.swift             # record(_:for:) feeds the fold cache
    └── DaemonCore+Dispatch.swift    # 2 cases

App/Sources/
├── Sidebar/SidebarState.swift       # SidebarPane.changes; AgentPaneState.changesSelection
├── Sidebar/SidebarView.swift        # the fifth pane
├── Sidebar/ChangesPane.swift        # NEW: list, file detail, view picker, empty/unavailable states
├── Sidebar/ChangeFileView.swift     # NEW: edits, folder hunks, whole file
├── Chat/DiffView.swift              # height cap optional; shared line model
├── Chat/Transcript.swift            # an edit is a Button that opens Changes at it (:573)
└── AppModel.swift                   # fetch/refresh triggers (open, completed edit, turn end)

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/ReportedChangesTests.swift  # NEW: last-wins, failed dropped, order, new/edit, multi-diff call
├── Unit/UnifiedDiffTests.swift      # NEW: hunks, no-newline, binary, quoted paths
├── Unit/EditReplayTests.swift       # NEW: matches, beyond-reported, Write replaces whole
├── Unit/StartingPointRecordTests.swift # NEW: round trip; old record decodes
├── Fixtures/claude-edits.jsonl      # NEW: a trimmed real transcript, ≥50 edits (SC-002)
└── Integration/ChangesTests.swift   # NEW: real git + fake runtime: list, shared vs worktree, commits kept, untracked, binary, deleted, outside folder, no git, index untouched
```

**Structure Decision**: The existing layout:
- The model and wire types go in AgentsKitCore, beside `AgentWorktree.swift`.
- The git work goes beside `GitWorktrees.swift`.
- The daemon side is one `DaemonCore+Changes.swift`.
- The pane sits beside `FilesPane.swift`.

## Phases (for /speckit-tasks)

1. **Record and fold**:
   - `StartingPoint` on the record, set at start (`git rev-parse --show-toplevel HEAD` in `cwd`,
     when it's a repository) and copied on fork.
   - `ReportedChanges` with its tests, and the SC-002 fixture.
   - The daemon's fold cache, fed by `record(_:for:)`.
   - `changes/list` and `changes/file` answering from reported edits only.
2. **The pane over reported edits (US1, P1)**:
   - `SidebarPane.changes`, and the list with counts, the *new* mark and the empty state.
   - The file detail drawing each edit with `DiffView`.
   - Refresh on a completed edit and on turn end, without moving the reader.
   - Open in Files at the first changed line.
   - **Run-app screenshots of the list and a file, then settle the layout with Alex before
     Phase 3.**
3. **From the conversation (US2, P2)**: the edit in `Transcript.swift` becomes a Button that opens
   the sidebar on Changes at that call's edit. Deleted-file marking comes in Phase 4, which is
   where the disk is checked.
4. **Git (US3, P2)**:
   - `GitChanges` (numstat, untracked, deletions, binary) with the read-only environment.
   - Merging into the list with the *seen in the folder* mark and the shared-folder notice.
   - Ownership (R6).
   - Replay and *changed beyond what was reported*.
   - The unavailable states (FR-010).
   - The SC-005 check that the index file and `git status` are unchanged.
5. **Whole file (US4, P3)**: `changes/file` with `whole: true`, and the view picker (Edits · In
   the folder · Whole file) showing only what exists.
6. **Proof**:
   - quickstart §3 once per runtime (Claude, Copilot, Cursor, Grok).
   - §4 on a scratch daemon, with a 200-file timing (SC-004).
   - Both schemes built.

## Risks

- **Replay false alarms.** A Claude edit with `replace_all`, or an edit whose old text appears
  twice, may replay differently from what the tool did. The result is a spurious *changed beyond
  what was reported*. R5 replays `replace_all` from `rawInput` where it's there, and otherwise
  takes the first match. If false alarms show up in the fixture, the fix is to limit the claim to
  "differs from what was reported". The spec's wording already allows that.
- **Shared folder noise.** In the project folder, git's view includes everyone's work. The notice
  says so, but a busy folder will list many files the agent didn't touch. Accepted by the
  clarification. Reported files are listed first.
- **Agents started before this feature** have no starting point. Their git view is uncommitted
  changes against `HEAD`, and the pane says so. Their commits don't show.
- **Other runtimes' diff shape.** Copilot is seen once, Cursor never. Phase 6 checks both. If one
  sends whole files instead of passages, the fold is unchanged. Only the replay treats a diff whose
  old text is the whole start text as a Write.
- **Large transcripts.** The first fold of a long-lived agent reads its whole `transcript.jsonl`.
  It's done once per daemon run per agent, off the main path, and only when the pane first asks.
