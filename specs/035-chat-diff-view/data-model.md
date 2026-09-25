# Data Model: What the Agent Changed

The types behind the Changes pane. All of them live in AgentsKitCore, so the Mac app and a later
phone sheet share them.

## On the agent record

### `Agent.startingPoint: StartingPoint?` (new, optional)

| Field | Type | Meaning |
|-------|------|---------|
| `repository` | URL | The repository's top folder (`--show-toplevel`) when the agent started |
| `commit` | String | The full SHA `HEAD` was on at that moment |

- It's set once in `start` (R3) and copied by `fork`. It never changes after that.
- It's nil when the folder isn't in a repository, the repository has no commits, or the agent
  started before 035.
- It's encoded only when present, so old records decode unchanged and older readers keep it in
  `unknownFields`.

## Folded from the transcript

### `ReportedEdit`

| Field | Type | Meaning |
|-------|------|---------|
| `path` | String | Resolved absolute path (R7) |
| `oldText` | String? | Absent for a new file |
| `newText` | String | |
| `toolCallID` | String | The call it came from, and how the conversation finds it |
| `index` | Int | Position among that call's diffs (a call may carry several) |
| `entryIndex` | Int | Transcript position of the entry holding the final copy |
| `replaceAll` | Bool | From `rawInput.replace_all`, for replay (R5) |
| `at` | Date | The entry's time |

### `ReportedChanges` (the fold)

It holds, per tool call:
- the call's latest diffs,
- its status (`pending`, `completed` or `failed`),
- and the order in which the call first carried a diff.

| Operation | Rule |
|-----------|------|
| `absorb(entry)` | A `toolCall` or `toolCallUpdate` with diffs replaces the call's diffs. A status is recorded. Every other kind is ignored. |
| `edits` | The diffs of `completed` calls, in first-diff order, then by `index` |
| `inProgress` | Paths of calls holding diffs that haven't completed |
| `byFile` | `edits` grouped by path, with files in the order of their first edit |

The same fold fed the same entries gives the same answer whether they arrive at once or one at a
time. That's tested.

## On the wire

### `ChangeSource` (enum)

- `reported`: the runtime reported it, and git has nothing to add or there's no git.
- `reportedAndSeen`: reported, and git sees it changed too.
- `seen`: only git sees it.

### `ChangeState` (enum)

`modified` · `added` · `deleted` · `binary`

- `added` means a reported edit with no old text at its first edit, or git `A`, or untracked.
- `deleted` means the file isn't on disk now, or git `D`.

### `ChangedFile`

| Field | Type | Meaning |
|-------|------|---------|
| `path` | String | Absolute |
| `relativePath` | String? | Relative to the agent's folder or repository, for display |
| `source` | ChangeSource | |
| `state` | ChangeState | |
| `editCount` | Int | Reported edits; 0 for `seen` |
| `added` / `removed` | Int? | Lines. Nil for binary. From git where there is git, otherwise summed from edits (R8) |
| `beyondReported` | Bool | R5. Only ever true for `reportedAndSeen` |
| `inProgress` | Bool | A call touching it hasn't finished |
| `outsideFolder` | Bool | Never given to git (R7) |
| `firstLine` | Int? | First changed line in the current file, for "Open in Files" (FR-003) |

### `ChangesList` (reply to `changes/list`)

| Field | Type | Meaning |
|-------|------|---------|
| `files` | [ChangedFile] | In R8's order |
| `git` | GitView | See below |
| `reportsEdits` | Bool | Whether this runtime has reported any diff in this agent. Used for FR-010's wording |

### `GitView` (enum)

- `owned(since: String)`: an agent's own worktree, measured from the starting commit.
- `shared(since: String)`: a shared folder, measured from the starting commit. The pane shows the
  "may include others' work" line.
- `sharedFromHead`: no starting point was recorded, so it's uncommitted changes against `HEAD`.
- `unavailable(ChangesUnavailable)`

### `ChangesUnavailable` (enum)

- `notARepository`
- `gitNotInstalled`
- `folderGone`
- `failed(String)`: git's own message

### `FolderHunk`

| Field | Type | Meaning |
|-------|------|---------|
| `oldStart`, `newStart` | Int | From the `@@` header |
| `lines` | [DiffLine] | |

### `DiffLine`

| Field | Type | Meaning |
|-------|------|---------|
| `kind` | `.context` / `.added` / `.removed` | |
| `text` | String | |
| `newLine` | Int? | The line number in the current file, for context and added lines |

The `\ No newline at end of file` marker isn't a line. It sets a flag on the hunk.

### `ChangedFileDetail` (reply to `changes/file`)

| Field | Type | Meaning |
|-------|------|---------|
| `file` | ChangedFile | Fresh |
| `edits` | [ReportedEdit] | Empty for `seen` |
| `hunks` | [FolderHunk]? | Nil without git or for binary |
| `whole` | [DiffLine]? | Only when asked for, and only with git: the whole current file with removed lines in place |

## State the window keeps

`AgentPaneState.changesSelection: ChangesSelection?`, where
`ChangesSelection = { path: String, toolCallID: String?, view: .edits | .folder | .whole }`.

It isn't persisted, the same as the files pane's `openFile`.
