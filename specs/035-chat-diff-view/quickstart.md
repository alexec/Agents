# Quickstart: Checking That 035 Works

Everything runs in the worktree `.agents/worktrees/035-chat-diff-view`, against scratch
repositories under `/tmp/cd-035`. Nothing touches the shared checkout or the real daemon. Methods
and shapes are in [contracts/changes.md](contracts/changes.md).

## 1. Package tests

```sh
cd Packages/AgentsKit && swift test
```

The new tests should pass, and they cover:

- **The fold (research R1)**:
  - A call that sends a no-old-text diff, then the same path with old text, then `completed` is
    one edit to a modified file.
  - A call ending `failed` gives no edit.
  - A call with no status yet gives `inProgress` and no edit.
  - A call with two diffs gives two edits, in order.
  - Absorbing entries one at a time equals absorbing them at once.
- **SC-002**: run the fold over `Fixtures/claude-edits.jsonl` (≥50 edits, trimmed from a real
  transcript) and check its edits against the expected list stored beside it (path, call,
  index): same count, same order, no duplicates.
- **Unified diff parsing**: hunk headers, `\ No newline at end of file`, an empty file, a binary
  `-\t-` numstat line, a path with spaces and non-ASCII under `-z`.
- **Replay (R5)**:
  - Two edits over a start text reproduce the disk: accounted for.
  - A third change made on disk: beyond reported.
  - A Write over an existing file replaces the whole text.
  - `replace_all` replaces every occurrence.
  - An old text that can't be found: beyond reported.
- **Records**: `startingPoint` round-trips, and an agent JSON without it decodes.

## 2. Integration (real git, fake runtime)

These are in the same `swift test` run, each in a fresh `git init` under a temp folder with one
commit.

| Case | Expected |
|------|----------|
| Fake runtime reports edits to `a.swift` ×2 and creates `b.md` | `changes/list`: `a.swift` (2 edits, `reportedAndSeen`), then `b.md` (`added`) |
| Then a shell-style write to `c.swift` and a rewrite of `a.swift` | `c.swift` is `seen`, and `a.swift` has `beyondReported: true` |
| Agent commits `a.swift` | Still listed: measured from `startingPoint`, not `HEAD` |
| Project folder (not a worktree) | `git` is `shared` |
| App-made worktree, sole agent | `git` is `owned` |
| Two agents in one worktree | `shared` |
| No `startingPoint` on the record | `sharedFromHead` |
| Not a repository | `unavailable.notARepository`, reported files still listed |
| Runtime reporting nothing, not a repository | `files: []`, `reportsEdits: false`, `unavailable` |
| Binary file changed | `state: binary`, no counts, `hunks: null` |
| Reported file deleted afterwards | `state: deleted`, `edits` still returned |
| Reported path outside the repository | `outsideFolder: true`, and git never sees it (checked with a `GIT_TRACE` log) |
| **SC-005** | `.git/index` bytes and mtime, and `git status --porcelain`, are the same before and after list + file + whole |
| `changes/file` with `whole: true` | Every current line present, changed ones marked, removed ones in place |

## 3. Each runtime once, for real

This one is the spec's own ask. Start a real agent of each runtime (Claude, Copilot, Cursor, Grok)
on a scratch daemon, in `/tmp/cd-035/repo`. Ask each to edit one file, create one, and run
`sed -i '' s/a/b/ other.txt` in its shell. For each, read `changes/list` off the scratch
`daemon.sock` and note:
- whether the runtime's diffs are passages or whole files,
- whether they repeat across updates the way Claude's do, and
- whether the list matches the conversation.

Write the findings into research.md R1's table. If a runtime's shape breaks the fold, stop and
bring it to Alex.

## 4. The pane, on a scratch daemon

Use the **run-app** skill (scratch root, driven by pid over AX, screenshots by window id). Don't
use the real app.

1. Open an agent that has made several edits. Choose **Changes**. Screenshot the list: order,
   marks, counts, and the source line.
2. Choose a file. Screenshot **Edits**, then **In the folder**, then **Whole file**.
3. While the pane is open, send the agent a prompt that edits a file. The row appears or updates
   without the scroll moving. Screenshot before and after.
4. In the conversation, press an edit. The sidebar opens on Changes at that edit. Screenshot it.
5. Press **Open in Files**. The files pane opens at `firstLine`.
6. An agent with no edits shows "Nothing changed yet". A Grok agent in a non-git folder shows both
   reasons.
7. **SC-004**: in a scratch repository, have a fake-runtime agent touch 200 files. Time
   `changes/list` over the socket (under 1s) and `changes/file` on the largest (under 0.5s).

Phase 2's gate is steps 1–2 with reported edits only. Hand those screenshots to Alex to settle the
layout before git is built.

## 5. Builds

Build `Agents`, then `Remote`, one after the other, with plugin validation skipped (see memory).
The Remote scheme only has to still compile, because no phone UI changes.
