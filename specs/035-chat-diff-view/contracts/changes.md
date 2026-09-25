# Contract: Changes

The daemon socket shapes (JSON-RPC over `daemon.sock`), the pane, and the way in from the
conversation. Types are in [data-model.md](../data-model.md).

## Daemon methods

### `agents/start`, `agents/fork` (behaviour changed, shape unchanged)

- After `cwd` is final, `start` runs `git rev-parse --show-toplevel HEAD` there with the
  read-only environment (research R4), and saves `startingPoint` on the record.
- It saves nothing when that fails: not a repository, no commits, or no git. A start never fails
  because of this.
- `fork` copies the parent's `startingPoint`.
- The `Agent` in the reply carries `startingPoint` when there is one.

### `changes/list` (new)

```json
→ { "agentID": "…uuid…" }
← { "reportsEdits": true,
    "git": { "shared": { "since": "5d8fb8f0…" } },
    "files": [
      { "path": "/Users/a/Agents/App/Sources/Chat/DiffView.swift",
        "relativePath": "App/Sources/Chat/DiffView.swift",
        "source": "reportedAndSeen", "state": "modified",
        "editCount": 2, "added": 14, "removed": 3,
        "beyondReported": false, "inProgress": false, "outsideFolder": false, "firstLine": 12 },
      { "path": "/Users/a/Agents/specs/035/notes.md", "relativePath": "specs/035/notes.md",
        "source": "reported", "state": "added", "editCount": 1, "added": 40, "removed": 0,
        "beyondReported": false, "inProgress": false, "outsideFolder": false, "firstLine": 1 },
      { "path": "/Users/a/Agents/Package.resolved", "relativePath": "Package.resolved",
        "source": "seen", "state": "modified", "editCount": 0, "added": 2, "removed": 2,
        "beyondReported": false, "inProgress": false, "outsideFolder": false, "firstLine": 8 } ] }
```

- **Unknown agent**: the existing `unknownAgent` failure.
- **An archived agent**: this is answered. Reading what an old agent did is a use.
- **Git is unavailable**: `git` is `{ "unavailable": { "notARepository": {} } }`, and `files` holds
  the reported files only. That isn't an error.
- **Nothing to say**: `files: []`, and either `reportsEdits: true` or git available. The pane shows
  "Nothing changed yet".
- **Neither source can say anything** (FR-010): `reportsEdits: false` and `git.unavailable`. The
  pane says both reasons.
- **Cost**: the first call for an agent folds its transcript. After that it's the held fold, plus
  at most three git processes and one `cat-file --batch`.
- **Never polled.** It's asked only on the window's triggers (R9).

### `changes/file` (new)

```json
→ { "agentID": "…uuid…", "path": "/Users/a/Agents/App/Sources/Chat/DiffView.swift", "whole": false }
← { "file": { …ChangedFile… },
    "edits": [ { "path": "…", "oldText": "…", "newText": "…", "toolCallID": "toolu_01…",
                 "index": 0, "entryIndex": 482, "replaceAll": false, "at": "2026-09-24T…Z" } ],
    "hunks": [ { "oldStart": 10, "newStart": 10, "noNewlineAtEnd": false,
                 "lines": [ { "kind": "context", "text": "import SwiftUI", "newLine": 10 },
                            { "kind": "removed", "text": "…" },
                            { "kind": "added", "text": "…", "newLine": 11 } ] } ],
    "whole": null }
```

- `whole: true` also fills `whole` with the current file, every line present, and the removed
  lines placed where they were. That needs git, so it's null without git.
- **A path the agent never changed and git doesn't list**: failure `notChanged`.
- **A path outside the folder**: `edits` only. `hunks` and `whole` are null.
- **Binary**: `edits` as reported, if any. `hunks` and `whole` are null, and `state: "binary"`.

### Failures (new)

| Code | When |
|------|------|
| `notChanged` | `changes/file` for a path that isn't in the list |

git failures don't fail the call. They come back as `git.unavailable.failed(message)`, with the
reported half still there.

### Read-only guarantee (FR-016, FR-017, SC-005)

- Neither method writes anything in the repository or under `.git`.
- Every git command runs with `GIT_OPTIONAL_LOCKS=0`.
- No command in R4's table takes `index.lock`.
- The integration test checks the index bytes and mtime before and after.

## The pane

### Place

The fifth `SidebarPane`, **Changes**, symbol `plusminus`. It sits after Files in the pane picker.

### List

Each row, in R8's order, shows:
- The name in the body style, with the relative folder under it in `.fine`.
- A mark: `new`, `deleted` or `binary`.
- The counts as `+14 −3`, set by weight: plus in primary, minus in tertiary. No colour.
- `2 edits` when it was reported.
- `in the folder` for `seen`.
- `changed since` for `beyondReported`.
- A small progress mark while `inProgress`.

Above the list:
- One line of source, only when it's needed:
  - "Also shows what git sees in the project folder — may include others' work." (shared)
  - "Git has no starting point for this agent; showing uncommitted changes." (sharedFromHead)
  - Nothing when the folder is owned or there's no git.
- A total: "7 files · +120 −31".

The empty and unavailable states replace the list, with the Files pane's `Gone`-style message:
- "Nothing changed yet."
- FR-010's two reasons: "*Grok* doesn't report its edits, and this folder isn't tracked by git,
  so there's nothing to show."

### File

- A back control, then the name, the mark, and **Open in Files** (FR-003: sets the files pane to
  the file at `firstLine`).
- A segmented control, showing only the views that exist:
  - **Edits**: every reported edit in order, each as a `DiffView` with no height cap, headed by
    its time. A chosen edit is scrolled to and outlined once.
  - **In the folder**: git's hunks, drawn with the same marks as `DiffView`, plus the hunk's line
    numbers.
  - **Whole file**: fetched on first choice.
- For `beyondReported`: one line under the header, "This file has changed since the agent's last
  edit, in ways it didn't report." A link on it switches to **In the folder**.
- Detail is drawn in a `LazyVStack`. A file over 2,000 changed lines shows its count and a **Show
  changes** button before drawing (FR-015).

### Updating (FR-004, FR-018)

The window asks `changes/list` when:
- the pane appears for an agent,
- an entry arrives for that agent that completes a tool call carrying a diff, or
- the agent's state leaves `working`.

Requests are coalesced. Rows are identified by `path`. The open file is fetched again only if its
`editCount`, `added` or `removed` changed. The scroll position is kept.

## From the conversation (FR-014)

- An edit in a tool call (`Transcript.swift`, the `DiffView` for `.diff`) is a `.plain` Button.
- Pressing it:
  - opens the sidebar if it's closed,
  - sets `pane = .changes`,
  - sets `changesSelection = { path, toolCallID, view: .edits }`.
- The pane opens that file and scrolls to that edit.
- If the pane can't find the call's edit (still in progress, or failed), it opens the file with
  the first edit in view.
- Hover shows "Show in Changes".
