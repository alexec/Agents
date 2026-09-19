# Data Model: The right sidebar

**Date**: 2026-09-18 | **Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

Three entities come from the spec. The rest are what those three need to exist. Nothing here is
written to disk except the sidebar's frame: a shell is a live thing, and an artifact is read back out
of the transcript that is already written.

---

## Sidebar state

The spec's entity, split in two because the halves have different lifetimes.

### `SidebarFrame`: belongs to the window, persisted

| Field | Type | Notes |
|---|---|---|
| `isOpen` | `Bool` | FR-004. Default false: 001 is what you get until you ask for more |
| `width` | `Double` | FR-003. Clamped to a minimum and to a maximum that leaves the conversation usable |
| `pane` | `Pane` | `.files`, `.terminal`, `.browser`, `.artifacts`. FR-004 |

Persisted in `UserDefaults`, because it is one person's preference about a window and is the same
whichever agent is selected. Survives quitting (FR-004).

**Rule**: `width` is clamped on read as well as on write. A value from a previous screen size that
would leave no room for the conversation is brought back into range rather than honoured.

### `AgentPaneState`: belongs to a window and an agent, in memory

| Field | Type | Notes |
|---|---|---|
| `agentID` | `UUID` | Which agent this is the state of |
| `folder` | `URL?` | Where the files pane had got to. Nil means the agent's own folder |
| `openFile` | `URL?` | What was being read |
| `browserURL` | `URL?` | FR-031. Nil means the pane has never been pointed anywhere |
| `attachedShell` | `Bool` | Whether this window is subscribed to this agent's shell |

Held for the window's life, keyed by agent, so switching away and back returns to the same place
(FR-005, SC-005). Not persisted: it is where you were looking, not what you decided.

**Rule**: there is no `AgentPaneState` when no agent is selected, and the sidebar draws its empty
state rather than four blank panes (FR-007).

---

## Shell session

The spec's "Terminal session". Owned by the daemon, one per agent (FR-023).

| Field | Type | Notes |
|---|---|---|
| `agentID` | `UUID` | The key. One shell per agent, addressed by the agent |
| `pty` | `PTY` | The master descriptor, the child pid, the current size |
| `scrollback` | `Scrollback` | A ring buffer of raw pty bytes with a byte cap. The daemon parses nothing |
| `state` | `ShellState` | Below |
| `startedAt` | `Date` | |
| `lastInputAt` | `Date` | One of the three inputs to the idle rule |
| `title` | `String?` | From OSC 0 or 2. The pane shows it when a program sets one |

### `ShellState`

```
live
exited(status: Int32)
failed(reason: String)      // the shell would not start (FR-024)
released(reason: String)    // reaped for being idle (FR-028), or died with the daemon (FR-029)
```

**Rules**:

- A shell is started by the first `shell/attach` for an agent, not by the agent starting. A user who
  never opens the pane never has a shell.
- Its working folder is the agent's folder, and its executable is the user's login shell (FR-020).
  A folder that no longer exists is a `failed`, with the folder named.
- `isBusy` is true when a child of the shell is running. The daemon counts a busy shell as work it is
  holding and will not shut down under it (FR-027).
- `isIdle` is a pure function of `isBusy`, `lastInputAt` and the clock. Tested as one.
- Every terminal state but `live` keeps the scrollback readable (FR-029). The screen is drawn as it
  was, with a line saying what happened and an offer to start a new one (FR-024).
- Nothing about a shell is written to disk. A daemon restart loses every shell, and each becomes
  `released` with the reason so the pane can say so rather than showing a dead one as live.

### The screen is not an entity here

There is no `Screen` type in this project. The screen is SwiftTerm's `Terminal`, held by the app, and
it is derived rather than stored: bytes are the truth, and the screen is what the emulator made of
them.

This rests on a property proved in research section 3: feeding the same bytes one at a time gives the
same screen as feeding them in one chunk. So the daemon can store bytes and the app can rebuild the
screen from them on attach, and there is exactly one emulator in the system.

`Scrollback` is therefore the only terminal state the kit defines: a ring buffer of raw bytes with a
byte cap, which drops from the front and reports that it has done so. Its capping and its tail are
what `swift test` covers.

---

## Artifact

The spec's entity, narrowed by FR-046 to what a runtime marks.

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | The transcript entry it was found in, plus its index within the blocks |
| `uri` | `String` | Where to find it. A `file:` uri opens in the files pane; `http(s)` in the browser |
| `name` | `String` | What the agent called it, or the last path component if it did not |
| `mimeType` | `String?` | What it is (FR-040) |
| `size` | `Int?` | |
| `arrivedAt` | `Date` | The entry's timestamp. The list is newest first (FR-040) |
| `entryID` | `UUID` | The message it came from, so the pane can jump to it (FR-042) |
| `embedded` | `Bool` | True for a `resource` block, which carries its own text or bytes |

**Rules**:

- An artifact is a `resource_link` block, or an embedded `resource` block, and nothing else
  (FR-046). A file a tool call merely touched is not one, and belongs to the files pane's marks
  instead.
- When a block carries `annotations` with an `audience`, one that does not include `user` is not
  listed. When there are no annotations, it is listed: an agent that sent a resource link meant it.
- Artifacts are derived from the transcript on read and are never stored separately. That is what
  makes FR-044 free: they last as long as the history does, across restarts, and for a stopped or
  archived agent, because the transcript does.
- The list updates when a transcript entry arrives, over the existing `agent/entry` notification
  (FR-041). No new push is needed.
- An artifact whose `uri` no longer resolves is listed and marked as gone when opened, rather than
  hidden (FR-045). The record that it arrived is still true.

---

## What the files pane reads

Not persisted, computed per directory.

### `DirectoryEntry`

| Field | Type | Notes |
|---|---|---|
| `url` | `URL` | |
| `name` | `String` | |
| `isDirectory` | `Bool` | |
| `size` | `Int?` | Nil for a directory |
| `modifiedAt` | `Date?` | |
| `touchedByAgent` | `Bool` | FR-013. From the transcript, not from the disk |

**Rules**:

- One level at a time. The pane never walks the tree, which is what keeps FR-015 true in a folder
  with thousands of entries.
- Directories first, then files, each sorted by name, case-insensitively.
- A directory with more entries than the cap shows the cap and says how many more there are.
- `touchedByAgent` is the union of every `ToolCallLocation.path` and every `ToolCallContent.Diff.path`
  in the agent's transcript. It is computed once per agent and updated as entries arrive.

### `FileProbe`

What the pane learns from the first chunk of a file, before showing anything.

| Field | Type | Notes |
|---|---|---|
| `kind` | `.text(encoding:)` or `.binary(describedAs: String)` | FR-014 |
| `prefix` | `Data` | The first chunk, capped. FR-015 says not to read the whole file |
| `isTruncated` | `Bool` | Whether there is more than the prefix |
| `size` | `Int` | The whole file's size, from its attributes, not from reading it |

**Rules**:

- A NUL byte in the first chunk means binary. Invalid UTF-8 means binary. Everything else is text.
- A binary file is described by its extension and size, and its bytes are never shown (FR-014).
- The probe is a pure function over a chunk and a filename, tested with UTF-16 with a BOM, a PNG, an
  empty file, and a file that is valid UTF-8 for the whole prefix and rubbish after it.

---

## Relationships

```text
Window
 ├── SidebarFrame            (1, persisted in UserDefaults)
 └── AgentPaneState          (0..n, one per agent visited, in memory)
                                   │
                                   │ addresses by agentID
                                   ▼
Daemon                                      App
 └── ShellHost                               └── TerminalPane
      └── ShellSession  (0..1 per agent)          └── SwiftTerm.Terminal
           ├── PTY                                     (the screen, rebuilt
           └── Scrollback  (raw bytes, capped)          by replaying the bytes)
                      │                                        ▲
                      └────── shell.attach / shell.output ─────┘

Agent
 ├── folder on disk  ──────▶ DirectoryEntry, FileProbe   (read, never stored)
 └── transcript.jsonl ─────▶ Artifact                    (filtered, never stored)
                       └───▶ touchedByAgent paths        (folded, never stored)
```

Two windows on one agent hold two `AgentPaneState`s and address one `ShellSession`. That is the whole
of the spec's two-window edge case.

## What this feature does not add to disk

No new file, and no new field on `agent.json`. The transcript gains nothing: artifacts are read out
of the blocks that 003 already writes. This is worth stating because it is what makes the feature
cheap to take back out, and what makes FR-044 true without any work.
