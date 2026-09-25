# Research: What the Agent Changed

The design decisions for 035, each with what was chosen and what was set aside. Nothing in the
Technical Context was left as NEEDS CLARIFICATION. Everything below was settled from the code and
from the transcripts on disk.

## R1. How a runtime's diffs actually arrive

**Checked** on 2026-09-24 against every `transcript.jsonl` under
`~/Library/Application Support/Agents/agents`, grouping diffs by `toolCallID`:

| | Claude |
|-|--------|
| Tool calls carrying a diff | 757 |
| Transcript entries carrying one | 1,169 |
| Calls whose diff is sent more than once, changed | 408 |
| … sent more than once, identical | 4 |
| Calls with more than one diff | 28 |
| Final diff with no old text (a new file) | 335 calls |
| First diff with no old text, final with old text | 53 calls |
| Calls that ended `failed` but carried a diff | 16 |
| Calls that ended `completed` | 741 |

A Claude Write goes through these entries:
1. `Preparing file…` (pending, no diff).
2. An update with the diff built from the tool input: no old text, so it looks like a new file.
3. An update after it ran, with the real old text. For a Write over an existing file, that's the
   whole previous file.
4. `completed`, with no content.

An Edit carries only the replaced passage and its replacement.

**Decision**: A tool call's reported edits are the diffs in the **last** entry for that call that
carried any. They're counted only once the call has ended `completed`. A call that ended `failed`
reports nothing. A call still running shows in the pane as *in progress*, without its diff.

**Rationale**: Taking the first copy would show 53 overwrites as new files. Taking every copy
would count one edit two or three times, which breaks SC-002 ("none duplicated"). A failed or
rejected edit didn't happen.

**Alternatives considered**:
- `TouchedPaths`' approach, every path in every entry. Right for a mark and wrong for a count.
- Folding in the window. The window holds one page of the transcript (`AgentsModel.firstEntryIndex`),
  so the list would be incomplete on any long conversation.

The comment on `ToolCallContent` ("the Claude adapter shells out and sends console text") is out
of date. Correct it while touching the file.

## R2. Where the list is built

**Decision**: In the daemon. It uses a fold per agent (`ReportedChanges`), built from
`transcript.jsonl` the first time anyone asks, then caught up from the store by entry count on
every ask after. That was built in place of being fed by `DaemonCore.record(_:for:)`, which would
leave a gap while the first fold reads across an `await`. It's kept for archived agents too,
whose changes are still worth reading.

**Rationale**:
- The daemon has the whole transcript, and the window doesn't.
- The daemon already runs git (`GitProcess`, 027/030).
- A phone sheet (034) can ask the same question later without a second implementation.
- Holding the fold means a refresh is a git call, not a re-read of megabytes of JSONL.

**Alternatives considered**:
- The window pages the whole transcript in. That's slow for long agents, and it repeats the work
  per window.
- A persisted index file. There's nothing to gain over an in-memory fold rebuilt once per daemon
  run.

## R3. The starting point

The spec measures git's view from "where the agent started". `AgentWorktree.base` is a branch name
for a new worktree, and a branch moves as the agent commits, so it can't be the measure. There's
nothing recorded for a shared folder.

**Decision**: A new optional `startingPoint` on `Agent`: `{ repository: URL, commit: String }`.

It's taken once `cwd` is final, which is after the worktree is made. It's one
`git rev-parse --show-toplevel HEAD`, run with the read-only environment (R4). As built, it runs
in the background just after the agent is registered, not inside `start`: awaiting it inside
`start` made three timing-sensitive start tests fail on every run. A runtime takes seconds to make
its first edit, and git answers in milliseconds. For a new worktree
that's the commit it was made from. For an existing worktree or the project folder, it's what the
folder was on.

A fork copies its parent's value. A folder that isn't in a repository, or has no commits yet,
gets nil. An agent with nil is measured against `HEAD`, and the pane says so.

**Rationale**:
- One rule for every kind of folder, and FR-009 and the "agent commits" edge case both fall out
  of it.
- It costs a few milliseconds, once.

**Alternatives considered**:
- Resolving `worktree.base` later. It's wrong once the branch has moved.
- Using the first entry's time to find a reflog commit. Fragile, and the reflog can be expired.

## R4. Asking git without touching the repository

**Decision**: Every command runs through `GitProcess` with the same safeguards:
- `GIT_OPTIONAL_LOCKS=0`, so `git status`-style index refreshes aren't written.
- `-c core.quotepath=off`.
- `--no-ext-diff --no-textconv --no-color --no-renames`.
- `-z` where there's a path list.

The commands:

| Need | Command |
|------|---------|
| Changed tracked files and counts | `git diff --numstat -z <start> --` (commit against working tree; `-` counts mean binary) |
| Deleted and added tracked files | `git diff --name-status -z <start> --` |
| Untracked files | `git ls-files --others --exclude-standard -z` |
| Start text for replay | one `git cat-file --batch` fed `<start>:<path>` per reported file |
| One file's hunks | `git diff -U3 <start> -- <path>`; untracked → the file read as all added |
| Whole file | `git diff -U<lines-in-file> <start> -- <path>` |

`git diff <commit>` against the working tree doesn't write the index. `ls-files` and `cat-file`
only read.

**Rationale**:
- `status` is the one command that opportunistically rewrites the index, and
  `GIT_OPTIONAL_LOCKS=0` exists for exactly this: IDEs polling a repository an agent is committing
  in.
- The flags make the output the same whatever the person's git config is.

**Alternatives considered**:
- `git status --porcelain=v2`. That's the right list, but it's measured against `HEAD`, not the
  starting point. It would also need the optional-locks guard and a second command for counts.
- libgit2. It's a new dependency for no gain.

The test for SC-005 checks that `.git/index` keeps its modification time and bytes, and that
`git status --porcelain` output is unchanged, across a `changes/list` and a `changes/file`.

## R5. "Changed beyond what was reported"

**Decision**: Replay the file's reported edits, in order, over its text at the starting point:
- The start text is `cat-file` from the start commit. It's empty when the first reported edit
  has no old text.
- An edit whose old text equals the whole current text replaces all of it, which covers a Write.
- Otherwise the first occurrence of the old text is replaced. It's every occurrence when the
  call's `rawInput.replace_all` is true.
- If an old text isn't found, the replay stops.

If the replay finished and equals the file on disk, the file is **accounted for**. Otherwise it's
**beyond reported**, and the pane offers git's view (FR-007).

It's only run where there's a repository and the file is in it. Without git, there's no start
text to replay over.

**Rationale**: It's the only check that works with passages, and it catches every cause equally: a
formatter, another agent, or the person's editor. The shared-folder notice already says that git's
view may include other people's work.

**Alternatives considered**:
- Checking that the last new text appears in the file. It misses earlier edits being undone.
- mtime after the last reported edit. Formatters that don't change content would give false
  alarms, and so would clock skew.

## R6. Whose folder it is

**Decision**: An agent **owns** its folder when `agent.worktree != nil` and no other unarchived
agent's `cwd` is inside the same `worktree.root`. Otherwise the folder is **shared**. Every file
seen only by git is then marked *seen in the folder, may include others' work*, and the pane has
one line saying so (FR-008, SC-006). In an owned folder, git's files are presented as the agent's
(FR-009).

**Rationale**: Two agents can choose the same existing worktree (030 US2), and then it's shared in
all but name.

## R7. Paths

**Decision**:
- Reported paths are standardised the way `TouchedPaths.key` does it, with symlinks resolved.
- A reported path outside `startingPoint.repository`, or outside `cwd` when there's no
  repository, is listed with its full path and never given to git.
- git paths are relative to the repository root and are joined to it before being merged.
- The list is keyed by resolved path, so a file both reported and seen is one row.

## R8. Order and counts

**Decision**:
- Reported files come first, in the order of their first completed edit.
- Files seen only by git follow, sorted by path.
- Counts: for a reported file, the number of edits, plus lines added and removed summed across
  them (DiffView's rule: every old line removed, every new line added). For git, numstat.
- When a row has both, it shows git's counts in the list. They're the net change, and they're
  what matches Whole file.

## R9. The pane in the column

**Decision**:
- `SidebarPane.changes`, titled "Changes", with symbol `plusminus`.
- It lists and details in one column, as the files pane does with folder and file: a list, then a
  file with a back control.
- `AgentPaneState` gains `changesSelection: (path, toolCallID?)`, so leaving an agent and coming
  back returns to the same place.
- In the detail, a segmented control offers **Edits** (reported), **In the folder** (git hunks)
  and **Whole file** (git). Only the ones that exist for the file are shown.
- A file over 2,000 changed lines is listed straight away and shows its count, and its detail is
  fetched and drawn only when chosen, in a `LazyVStack` (FR-015).

The Phase 2 screenshots settle this with Alex. The segmented control in particular may turn out to
be two views, not three, because Whole file is the folder view with all the context.

**Refresh** (FR-004, FR-018): the window asks `changes/list` again when:
- the pane opens,
- an entry arrives for this agent whose tool call just completed with a diff, or
- the agent's turn ends.

Requests are coalesced, with at most one in flight and one queued. Rows are keyed by path, so a
refresh doesn't move what's being read. The open file's detail is fetched again only if its counts
changed.

**Settled with Alex at T021 (2026-09-24)**, from screenshots of the built pane:
- **The list is grouped by folder.** Folders come in the order of their first changed file, and
  files keep first-edit order inside each folder. The row no longer carries its folder.
- **A file has two views: Edits and Whole file.** Git's hunks aren't a view of their own. The
  "changed since" notice links into Whole file. This supersedes the three-view picker above, and
  T034/T038 follow it.

## R10. From the conversation

**Decision**: In `Transcript.swift:573`, the `DiffView` inside a tool call is wrapped in a `.plain`
Button, following the memory note on card taps: the card must be the Button. The button opens the
sidebar if it's closed, and sets `pane = .changes` and `changesSelection = (diff.path,
call.toolCallID)`. The pane scrolls that edit into view once the detail loads.

An edit to a file that has since gone shows the file marked *deleted*, with its edits still
readable. The disk check is in `changes/list`.
