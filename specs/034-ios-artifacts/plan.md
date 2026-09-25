# Implementation Plan: The Mac's Side Panes on iPhone and iPad

**Branch**: `034-ios-artifacts` | **Date**: 2026-09-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/034-ios-artifacts/spec.md`

## Summary

Of the three panes, the Mac already has the shell in a form the phone can use, and has the
page and the files in a form it cannot.

- **The shell is the daemon's already.** `shell/attach`, `shell/input`, `shell/resize`,
  `shell/restart` and the `shell/output` notification are ordinary daemon requests. The
  phone's connection reaches the daemon through the bridge like any window, so the phone
  can attach to the same shell today. What it lacks is an emulator and a keyboard.
- **The page's writing half is the daemon's already.** `artifact/write` writes the file
  inside the agent's folders and keeps the note for the agent's next turn (022). A phone
  calling it is told of in the same way as a Mac (FR-006, FR-007) with no new mechanism.
- **The page's reading half, and all of Files, is the Mac app's own.** `FilesPane` calls
  `DirectoryReader` and `FileProbe` and runs a `FolderWatch` inside the app process. The
  daemon has no request that lists a folder, reads a file or says one changed. `LivePage`
  reads images off the disk directly. This is the gap the phone falls into, and it is the
  one piece of new machinery here.

So the plan is:

1. **Four daemon requests and one notification for files**: `files/list`, `files/read`,
   `files/watch`, `files/unwatch`, and `files/changed`. They wrap the existing
   `DirectoryReader`, `FileProbe` and `FolderWatch`. They are held to the agent's
   `folderScope`, and refused with the same sentence as `show_file` and `artifact/write`.
   A watch belongs to the connection that asked for it and ends when that connection ends.
   The Mac app keeps reading its own disk. Nothing on the Mac changes.
2. **The page moves to shared code.** The page's logic (the caret's reveal queue, following,
   echo recognition, carrying a draft across an agent's write) comes out of `LivePage` into
   a pure `PageFollower` in `AgentsKitCore`, where it can be tested for the first time. The
   view moves to `Shared/UI/Page/`. The platform differences come in the way 033's
   `ChatActions` does: `PageActions` saves the document and loads a picture, and
   `PassageEditor` is an `NSTextView` on the Mac and a `UITextView` on the phone. The Mac's
   `MarkdownText` becomes the one `MarkdownText`, and the phone's copy goes.
3. **The shell client moves to `AgentsKitCore`**, and the Remote links SwiftTerm, whose
   `TerminalView` has an iOS face. Its stock key bar has a sticky Ctrl, which makes
   Control-C two taps. SC-005 asks for one, so the bar is ours: ^C, Esc, Tab, the four
   arrows, a sticky Ctrl for the rest, and `| ~ / -` (FR-020). `shell/input` gains an
   optional size, so the shell takes the size of whoever typed last (US4 scenario 5).
4. **A pane beside or over the chat.** A pure `PanePlacement` decides column or full screen
   from the width. On an iPad with room, a column sits beside the chat. On an iPhone, a push
   onto the chat's stack. Per agent, the phone remembers which pane was open and where. This
   is the phone's `SidebarState`.
5. **The phone's current read-only views stay as fallbacks.** `FileView` (what the agent
   did, rebuilt from the transcript) becomes the "What the agent did" view, one tap from a
   file. `DocumentView` and the Exchanged list stay for entries that exist only in the
   conversation (FR-027), and for a Mac too old to answer `files/*` (FR-029).

**Order.** Settle the layout first, then build depth (memory: settle the UX before building
depth). Slice A puts the panes on screen on both devices against the new file requests,
read-only. It is built for the generic simulator and screenshotted. The walk is Alex's.
Typing, the shell and the fallbacks follow it.

## Technical Context

**Language/Version**: Swift 6.4 toolchain, Swift 6 language mode (`SWIFT_VERSION: 6.0` in
`project.yml`), strict concurrency complete. Unchanged.

**Primary Dependencies**: SwiftUI. SwiftTerm (already a package of the project, linked by the
Mac app) is now also linked by the Remote, as the emulator and its iOS keyboard accessory.
FSEvents via `FolderWatch`, which is now also run by the daemon. No new package.

**Storage**: None new. Pane places are in memory on the phone for as long as the app runs
(spec assumption). The daemon's watches are in memory and belong to connections. The file is
the artifact.

**Testing**: swift-testing in `Packages/AgentsKit/Tests/AgentsKitTests`.
- Unit: `PageFollower` (the page's logic, lifted from the view: follow, reveal queue, echo,
  merge carry, reconnect replay), `PanePlacement`, `FilesReadResponse` encoding (text, image,
  binary, truncated, unchanged).
- Integration against `DaemonCore`: `files/list` and `files/read` scope and refusals, gone
  and not readable, the 5,000-entry cap, image size cap, `files/watch` delivering
  `files/changed` only to the connection that watches, and ending with it. `shell/input`
  with a size resizes first. A device's connection hears `shell/output` only for shells it
  attached.
- `ConsistencyTests`: the Remote defines no `MarkdownText`, `LivePage` or `PassageMerge` of
  its own.
- Both schemes are built with `xcodebuild -skipPackagePluginValidation`, one after the other.
  The Mac page is walked with the run-app skill on a scratch root, to prove the move changed
  nothing. The phone is built for the generic simulator only. The phone and iPad walks are
  Alex's (memory: no throwaway simulators, no Simulator GUI).

**Target Platform**: iOS 27 and iPadOS 27 (the Remote). macOS 27 (the daemon's new requests,
and the Mac app's page after the move, which must look and behave the same).

**Project Type**: The existing targets. The daemon and `AgentsKitCore` gain requests and
types, `Shared/UI` gains the page, the Remote gains three panes, and the Mac app loses code
to `Shared/UI`. The bridge is not touched: it carries lines and parses none of them.

**Performance Goals**:
- An agent's write is on the phone's page within 2 s (SC-001). The budget is `FolderWatch`'s
  0.2 s coalescing, then `files/changed` over the relay, then `files/read` of at most 128 KB
  of text.
- A phone paragraph is on disk within 2 s of a pause (SC-002). That is the page's existing
  1 s debounce plus one round trip.
- A 10,000-entry folder (SC-006) is answered with `DirectoryReader`'s first 5,000 and a count
  of the rest, as on the Mac. About 5,000 × ~120 bytes of JSON is under 1 MB, drawn lazily
  by a `List`.

**Constraints**:
- The phone reads only through the daemon, and only inside `agent.folderScope`.
- Only the daemon writes, and only through `artifact/write`.
- The Remote links `AgentsKitCore` and SwiftTerm, never `AgentsKit`. SwiftTerm's
  `LocalProcess` is compiled out on iOS, so no PTY reaches the phone.
- The bridge is unchanged. Everything new is JSON-RPC lines through it.
- The Mac's page, files pane and terminal behave as before.
- No browser pane on the phone, and no disabled entry for one (FR-030).

**Scale/Scope**: one pane open per agent per device. Documents up to 128 KB, as on the Mac.
Images up to 4 MB over the connection (larger ones are described instead). Folders up to
5,000 listed entries. A handful of devices watching at once.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled template, as 021's and 022's plans
found. The gates below are the project's standing rules, from the README and the code's own
comments, as 022 used them.

| Gate | Where it is stated | This feature |
|---|---|---|
| The daemon is the only writer | README, "The daemon" | **Passes.** The phone writes nothing itself. Its typing goes through `artifact/write`, the same request the Mac's page uses. `files/*` only read. |
| Nothing stored outside the root | README | **Passes.** Watches and pane places are in memory. No new file is written anywhere. |
| The phone links Core only; no `Process` or PTY on iOS | `project.yml` Remote note, `Package.swift` | **Passes.** The Remote gains SwiftTerm, which is an emulator and a view. Its process-spawning half is `#if os(macOS)` in SwiftTerm itself. What moves to Core (`ShellClient`, `PageFollower`, file value types) holds no `Process`. |
| The daemon parses no terminal bytes | `Package.swift`, ShellHost | **Passes.** Unchanged. The size on `shell/input` is two integers beside the bytes. |
| One rule, one place | `FolderScope`, `AgentGroup` | **Passes.** One scope check and one refusal sentence for `show_file`, `artifact/write` and every `files/*`. One page (`PageFollower` + shared `LivePage`) on both devices. One `MarkdownText`. One `ShellClient`. |
| No code asks which runtime it is | README | **Passes.** Nothing here touches runtimes. |
| A remote is a view, never a copy | `RemoteModel` doc comment | **Passes, and more so.** The phone's reconstructed file stops being the file. It stays only as "what the agent did". |
| Notifications go to every window | `ShellHost` broadcaster, `DaemonServer.broadcast` | **Narrowed, deliberately, for devices.** `files/changed` goes only to the connections watching. `shell/output` goes to a device only for a shell it attached. Windows on the Mac hear everything as before. Listed in Complexity Tracking. |
| Read-only files pane (004 FR-017, amended by 022) | `FilesPane` doc comment | **Passes.** As amended by 022: read-only apart from typing on a live page, now on the phone too (FR-016). |
| The bridge carries lines and parses none | `Bridge/Sources/main.swift` | **Passes.** Untouched. |

**Post-design re-check**: still passes. The design adds no persistence and no new writer. The
only deviation is the one in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/034-ios-artifacts/
├── plan.md              # This file
├── research.md          # Phase 0: the decisions and what they were checked against
├── data-model.md        # Phase 1: the new wire types, PageFollower, pane state
├── quickstart.md        # Phase 1: how each slice is run and seen to work
├── contracts/
│   ├── daemon-api.md    # files/*, files/changed, shell/input's size, device routing
│   └── panes-ui.md      # what the phone and iPad show, where, and in how many taps
├── checklists/          # from /speckit-specify
└── tasks.md             # /speckit-tasks output, not made here
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Daemon/DaemonAPI.swift            # + files/list, files/read, files/watch, files/unwatch,
│                                     #   files/changed; ShellInputRequest gains rows/cols
├── Model/FileListing.swift           # MOVED from AgentsKit/Files: DirectoryEntry,
│                                     #   DirectoryListing (values only; readers stay)
├── Model/FileReading.swift           # NEW: what files/read answers (text, image, other, gone)
├── Model/TouchedPaths.swift          # MOVED from AgentsKit/Files, unchanged
├── Model/PageFollower.swift          # NEW: LivePage's logic, pure and tested
├── UI/PageMetrics.swift              # MOVED from AgentsKit/Files, unchanged
├── UI/PanePlacement.swift            # NEW: column or full screen, from widths
└── Client/ShellClient.swift          # MOVED from App/Sources/Sidebar, over DaemonClient

Packages/AgentsKit/Sources/AgentsKit/
├── Files/DirectoryReader.swift       # stays (reads the disk); returns the moved types
├── Files/FileProbe.swift             # stays; + FileReading(from:) for the wire
├── Daemon/DaemonCore+Files.swift     # NEW: list, read, watch, unwatch; watches per connection
├── Daemon/DaemonCore+Shells.swift    # input resizes first when a size comes with it;
│                                     #   remembers which device connections attached
├── Daemon/DaemonCore+Dispatch.swift  # the five new cases
└── Daemon/DaemonServer.swift         # + notify(connections:) beside broadcast

Shared/UI/Page/
├── LivePage.swift                    # MOVED from App/Sources/Sidebar; logic → PageFollower
├── PageActions.swift                 # NEW: save(document) and image(at:) per app, as ChatActions
├── PassageEditor.swift               # MOVED; NSTextView on macOS, UITextView on iOS
├── MarkdownText.swift                # MOVED from App/Sources/Chat; images via PageActions
├── CursorFlag.swift                  # MOVED from App/Sources/Sidebar
└── FileLines.swift                   # MOVED from App/Sources/Sidebar (numbered text)

App/Sources/Sidebar/
├── FilesPane.swift                   # hands LivePage its PageActions (disk + writeArtifact)
├── ImageStamps.swift                 # stays Mac-side (it stats the disk)
├── ShellClient.swift                 # DELETED (moved to Core)
└── TerminalPane.swift                # uses the Core ShellClient

Remote/Sources/Panes/                 # NEW
├── PaneHost.swift                    # column beside the chat, or pushed over it
├── PaneState.swift                   # per agent: which pane, folder, file, line, scroll
├── PagePane.swift                    # the live page over files/read + files/changed
├── FilesPane.swift                   # listing, reader, image, "What the agent did"
├── TerminalPane.swift                # SwiftTerm's iOS TerminalView + ShellClient
├── ShellKeys.swift                   # the key row: ^C, Esc, Tab, arrows, Ctrl, symbols
└── RemoteFiles.swift                 # the phone's end of files/*: watch, read, re-read

Remote/Sources/Chat/
├── RemoteChatView.swift              # pane button; show_file opens or offers
├── FileView.swift                    # becomes ChangesView: "What the agent did"
├── DocumentView.swift                # Exchanged: file entries open the live file
└── MarkdownText.swift                # DELETED (the shared one)

Remote/Sources/RemoteModel.swift      # panes, shell clients, files, the older-Mac flag
project.yml                           # Remote depends on SwiftTerm

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/PageFollowerTests.swift       # NEW
├── Unit/PanePlacementTests.swift      # NEW
├── Unit/FileReadingTests.swift        # NEW
├── Unit/ConsistencyTests.swift        # + no second page or MarkdownText in Remote
├── Integration/FilesRequestTests.swift # NEW: scope, gone, caps, watch routing
└── Integration/ShellSizeTests.swift   # NEW: last typer's size; device routing
```

**Structure Decision**: The pattern is 033's. Pure logic goes to `AgentsKitCore`, where the
one test target reaches it. Views both apps draw go to `Shared/UI`. What differs by platform
comes in through one value (`PageActions`, as `ChatActions`). The daemon gains an extension
file, `DaemonCore+Files`, beside `DaemonCore+Artifacts` and `DaemonCore+Shells`. There is no
new target, package or process.

## Slices

Each slice is run and seen before the next begins. A is the gate.

**Slice A — the panes on screen, read-only.**
- The daemon: `files/list`, `files/read`, `files/watch` and `files/changed`.
- The phone: `PaneHost`, `PaneState`, the Files pane (listing, text reader, image) and the
  Page pane (the shared `LivePage`, read-only).
- The Mac: `LivePage` moved to `Shared/UI` with `PageFollower`. The Mac page is walked
  unchanged on a scratch root.
- The phone is built for the generic simulator. Its screens are Alex's to see.
- *Seen*: an agent writes a document in steps, and the phone's page follows. An iPad with
  room shows a column; an iPhone pushes the pane.

**Slice B — attention.** `show_file` on the phone opens the pane when the chat is in front
and Alex is not typing. Otherwise it is offered in the chat. A touched file in a tool call
opens the current file at its line, with "What the agent did" one tap away. Exchanged
entries that name a file in scope open the live file.

**Slice C — typing on the page.** `PassageEditor` on iOS, and `PageActions.save` over
`artifact/write`. The draft survives staleness: typing is disabled, the draft is kept, and on
reconnect the file is re-read, the draft is carried across by `PageFollower`, and it is
saved or said not to be (FR-009, SC-008). *Seen*: type on the phone, `cat` the file on the
Mac, and the Mac's page shows it. The agent's next turn is told.

**Slice D — the shell.** `ShellClient` moved to Core, SwiftTerm on iOS with its accessory
bar, the last typer's size, device routing of `shell/output`, and the exited, failed and
released states with Start again. *Seen*: the same session on the Mac and the phone, and
Ctrl-C from the accessory bar.

**Slice E — the edges and the fallback.** Gone folders and files, a removed worktree,
binary and very large files, archived agents, and an older Mac answering `methodNotFound`
(the phone falls back to today's views and says the Mac needs updating).

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Some notifications go to some connections, not all | `files/changed` belongs to whoever is watching. And a phone on WiFi should not carry every agent's build output because a Mac window has a shell open | Broadcasting everything is the existing rule, and it is kept for windows. For a device it means every shell's bytes and every watched folder's events cross the network to a phone showing neither. A per-connection filter is a set of UUIDs beside the existing per-connection queue. |
| The Mac's `LivePage` and `MarkdownText` are moved, touching a walked Mac surface | FR-001 asks for the same page on both, and a second page would drift the way the two chats did before 033 | Porting a copy to the phone is faster today and is how the two `MarkdownText`s came to disagree. The move is covered by `PageFollower`'s new tests, which the page never had, and by a Mac walk. |
| The daemon runs `FolderWatch` | The phone has no disk to watch, and polling `files/read` would be the descriptor-exhausting tight loop the daemon has already been burnt by | Polling costs the same whether anything changed or not, and at 2 s it misses SC-001's budget. |
