# Data Model: The Mac's Side Panes on iPhone and iPad

Phase 1 for [plan.md](./plan.md). Nothing here is persisted. Every entity lives in memory on
the daemon or on a device, and the file on disk is the only record. Wire shapes are in
[contracts/daemon-api.md](./contracts/daemon-api.md).

## Moved, unchanged

These move from `AgentsKit/Files` to `AgentsKitCore/Model` (or `UI`) so the phone can hold
them. Their fields and behaviour do not change, and `AgentsKit` re-exports Core, so no Mac
file changes its imports.

| Type | From | To | Why the phone needs it |
|---|---|---|---|
| `DirectoryEntry`, `DirectoryListing` | `Files/DirectoryReader.swift` | `Model/FileListing.swift` | `files/list` answers with them. They become `Codable`. |
| `TouchedPaths` | `Files/TouchedPaths.swift` | `Model/TouchedPaths.swift` | The phone marks changed files from its transcript, as the Mac does. |
| `PageMetrics` | `Files/PageMetrics.swift` | `UI/PageMetrics.swift` | The shared page measures with it. |
| `ShellClient` | `App/Sources/Sidebar` | `Client/ShellClient.swift` | Both apps attach to shells. It takes a `DaemonClient`, not `AppModel`. |

`DirectoryReader` and `FileProbe` (the code that reads the disk) stay in `AgentsKit`.

## FileStamp

What a file was when it was read, so that a re-read can be answered "unchanged".

| Field | Type | Notes |
|---|---|---|
| `size` | `Int` | bytes |
| `modifiedAt` | `Date` | content modification date |

Two stamps are equal when both fields are. This is coarse, and it is enough: a write that
keeps both the size and the mtime at the same second is re-read on the next event.

## FileReading

What `files/read` answers. One of:

| Case | Carries | Shown as |
|---|---|---|
| `text` | `text: String` (≤ 128 KB prefix, UTF-8 decoded as `FileProbe.text`), `isTruncated`, `size`, `stamp` | Numbered lines. For `.md`, the live page. When truncated, "Showing the first 128 KB of 3.2 MB." |
| `image` | `bytes: Data` (≤ 4 MB), `describedAs`, `stamp` | A picture. On the page, inline at its reference. |
| `other` | `describedAs: String`, `size`, `stamp` | "A 2.1 MB SQLite database. It can't be shown here." |
| `unchanged` | `stamp` | Nothing new. The client keeps what it has. |

An image over 4 MB is `other`, described with its kind and size.

**Validation** (daemon side): the path is absolute, inside `agent.folderScope` after
resolving symlinks, and a regular file. A directory is refused with "That is a folder." Gone
and not-readable are errors (`fileGone`, `fileNotReadable`), not cases, so a client cannot
mistake them for content.

## FolderWatchInterest (daemon)

Who is watching what, so events go only to them and watches end with them.

| Field | Type | Notes |
|---|---|---|
| `connection` | `UUID` | `ConnectionContext.id` |
| `agentID` | `UUID` | |
| `root` | `URL` | The scope folder holding the watched folder: one `FolderWatch` per root |

- `watches: [URL: FolderWatch]`, one stream per root, shared.
- `interests: [UUID: Set<Interest>]`, keyed by connection.

**Lifecycle**:

```text
files/watch ─► interest added ─► (first for root) FolderWatch started
FolderWatch event ─► files/changed {agentID, folders} to connections with an interest in (agentID, root)
files/unwatch ─► interest removed ─► (last for root) FolderWatch stopped
connection ends (onDisconnected) ─► all its interests removed ─► same as above
agent archived ─► unchanged: an archived agent's files can still be read (spec edge case)
agent deleted / folder gone ─► FolderWatch reports the root; files/list then answers fileGone
```

## ShellInterest (daemon)

Which device connections hear which shells.

| Field | Type | Notes |
|---|---|---|
| `connection` | `UUID` | only connections whose surface is `.device` |
| `agentID` | `UUID` | |

- Added on `shell/attach` and `shell/restart` from a device.
- Removed on `shell/detach` from that device, or when it disconnects.
- Windows are not recorded. They hear every shell, as today.

## ShellInputRequest (changed)

| Field | Type | Notes |
|---|---|---|
| `agentID` | `UUID` | unchanged |
| `bytes` | `Data` | unchanged |
| `rows` | `Int?` | NEW. The typist's size. |
| `cols` | `Int?` | NEW |

When both are present, positive and different from the session's size, the daemon resizes the
PTY and then writes. When they are absent, it only writes, as before.

## PageFollower (AgentsKitCore)

The live page's state and rules, lifted out of `LivePage`'s `@State`. It is a value type,
with no SwiftUI and no clock: time comes in as `tick()`.

| Field | Type | Notes |
|---|---|---|
| `passages` | `[Passage]` | `Passage.split` of the current document |
| `lastLoaded` | `String` | the base for the next diff |
| `lastWritten` | `String?` | the document as last handed to `save`, so its echo is recognised |
| `editing` | `Editing?` | `index`, `base`, `draft`: the one open passage |
| `revealing` | `Reveal?` | the caret's block: `index`, `from`, `shown`, `before` |
| `pending` | `[Reveal]` | blocks waiting their turn, in document order |
| `marked` | `[Int: Date]` | a named line's passage, and when it was marked |
| `collision` | `String?` | the agent's version of the passage being typed |
| `saveProblem` | `String?` | why the last save failed. The draft is kept. |

**Operations** (each returns `[PageEffect]`):

| Operation | When | Effects it can return |
|---|---|---|
| `load(text)` | first read | none |
| `follow(new)` | a re-read gave new text | `.scroll(to:)`, `.save(document)` (a carried draft), `.collided` |
| `begin(index)` | a passage is tapped | none (the reveal moves on if it was in that block) |
| `edit(draft)` | typing | none |
| `commit()` | the pause, or leaving the passage | `.save(document)` |
| `close()` | focus leaves | `.save(document)` if changed |
| `saved(problem:)` | the save answered | none. Sets or clears `saveProblem`, and moves `base` on success. |
| `tick()` | every 40 ms while revealing | `.scroll(to:)` when the caret moves block |
| `go(toLine:)` | a line is named | `.scroll(to:)`, then it marks |
| `reconnected(fresh)` | the phone is back and re-read the file | same as `follow`. A draft is carried by `PassageMerge` and saved. |

**Rules carried over from 022, now under test**:
1. Exactly one caret. A new write completes what is still being typed before queueing its own
   blocks.
2. The document's own echo (`new == lastWritten`) is not news: no mark, no reveal, no scroll.
3. While a passage is open, other blocks redraw and the view never moves.
4. A write to the open passage keeps the person's text, writes it, and sets `collision` to
   theirs. Nothing is lost silently.
5. A re-split that no longer maps the editing index to the draft's passage closes the editor
   rather than guess.

**New for the phone**:
6. `reconnected(fresh)` with a draft open follows rule 4 against the fresh text, and the
   result goes to `.save`. If `saved(problem:)` then reports a problem, the draft stays open
   with `saveProblem` set. It is never cleared by a later `follow`.

## PageActions (Shared/UI)

Per-app services the page calls, carried in the environment as `ChatActions` is.

| Member | Mac | Phone |
|---|---|---|
| `save(path, document) async -> String?` | `AppModel.writeArtifact` → `artifact/write` | `RemoteModel.writeArtifact` → `artifact/write` |
| `image(at: URL) async -> PlatformImage?` | read the disk, cached (today's `MarkdownText` cache) | `files/read` for the image, cached by stamp |
| `imagesChanged` | `ImageStamps.refreshed()` on a folder event | stamps compared on `files/changed` for the image's folder |
| `canEdit: Bool` | always true | false while stale |

## PanePlacement (AgentsKitCore)

| Input | Output |
|---|---|
| `width: Double` | `.column(paneWidth:)` or `.fullScreen` |

- `.column` when `width ≥ ChatMetrics.comfortablePane + minimumPaneWidth + 1`, which is
  660 + 360 + 1 = 1,021 pt.
- `paneWidth` is clamped to `minimumPaneWidth…width/2`.
- An 11-inch iPad in landscape (1,180 pt) gets a column. In portrait (820 pt) it gets full
  screen, as does any iPhone.

## PaneState (Remote, per agent)

The phone's `AgentPaneState`. In memory, keyed by agent, and forgotten on relaunch
(FR-026).

| Field | Type | Notes |
|---|---|---|
| `pane` | `Pane?` | `.page`, `.files`, `.terminal`, `.exchanged`. `nil` means closed. |
| `pagePath` | `String?` | the Markdown file on the Page |
| `folder` | `URL?` | the Files pane's folder. `nil` means the agent's `cwd`. |
| `openFile` | `URL?` | the file open in Files |
| `openLine` | `Int?` | spent once used, as on the Mac |
| `scrollAnchor` | `[String: Int]` | the passage or line index per path, to return to |
| `showingChanges` | `Bool` | "What the agent did" is open over the file |

**Transitions**:
- `show_file` (in front, not typing) sets `pane`, `pagePath` or `openFile` and `openLine`.
- Tapping a touched file sets `pane = .files`, `openFile` and `openLine`.
- Moving to another agent and back reads this back unchanged (US5 scenario 3).

## RemoteModel additions

| Field | Notes |
|---|---|
| `panes: [UUID: PaneState]` | above |
| `shells: [UUID: ShellClient]` | one per agent attached from this device |
| `macLacksPanes: Bool` | set by the first `methodNotFound` on `files/*`, and cleared on reconnect |
| `isTyping: Bool` | reported by the prompt, the passage editor and the terminal. It gates `show_file`. |
| `offeredFile: ShownFile?` | the "Wants you to see" strip for the chat in front |
