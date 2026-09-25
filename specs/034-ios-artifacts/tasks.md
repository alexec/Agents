---
description: "Task list for 034: the Mac's side panes on iPhone and iPad"
---

# Tasks: The Mac's Side Panes on iPhone and iPad

**Input**: Design documents from `specs/034-ios-artifacts/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: The plan asks for them. Under test:
- the new daemon requests and their routing
- `PageFollower` (the page's logic, lifted out of the view)
- `PanePlacement`
- `FileReading`
- the consistency scan

Views are checked by building both schemes. The Mac is also checked with the run-app skill on a
scratch root. The phone and iPad walks are Alex's.

All paths are relative to `.agents/worktrees/034-ios-artifacts`. Build the schemes one after
the other, with `-skipPackagePluginValidation`.

## Phase 1: Setup

- [X] T001 Record a baseline on the untouched branch, saved to `/tmp/w-034-baseline.log`: `swift test` in `Packages/AgentsKit` (pass and fail counts), then `xcodebuild -scheme Agents -destination 'platform=macOS'`, then `xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator'`
- [X] T002 In `project.yml`, add `- package: SwiftTerm` to the Remote target's dependencies (with a comment: its `LocalProcess` is macOS-only, so no PTY reaches the phone). Create `Shared/UI/Page/` and `Remote/Sources/Panes/`, then run `xcodegen generate`

---

## Phase 2: Foundational (blocks every story)

**Purpose**: The daemon can list, read and watch files for a device. The phone has somewhere to
put a pane.

- [X] T003 Move `DirectoryEntry` and `DirectoryListing` out of `Packages/AgentsKit/Sources/AgentsKit/Files/DirectoryReader.swift` into `Packages/AgentsKit/Sources/AgentsKitCore/Model/FileListing.swift`, public and `Codable`. `touchedByAgent` is not encoded. `DirectoryReader` stays where it is.
- [X] T004 [P] Move `Packages/AgentsKit/Sources/AgentsKit/Files/TouchedPaths.swift` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/TouchedPaths.swift` unchanged, and `.../Files/PageMetrics.swift` to `.../AgentsKitCore/UI/PageMetrics.swift` unchanged.
- [X] T005 Create `Packages/AgentsKit/Sources/AgentsKitCore/Model/FileReading.swift`:
  - `FileStamp { size: Int, modifiedAt: Date }`, equal when both fields are equal
  - `FileReading`, tagged by `kind`: `text(text, isTruncated, size, stamp)`, `image(bytes, describedAs, stamp)`, `other(describedAs, size, stamp)`, `unchanged(stamp)`
  - `static let imageLimit = 4 * 1024 * 1024`
  - a `truncationNote` sentence: "Showing the first 128 KB of 3.2 MB."
- [X] T006 In `Packages/AgentsKit/Sources/AgentsKit/Files/FileProbe.swift`, add `FileReading.read(_ url:, known: FileStamp?)`:
  - `unchanged` when the stamp matches
  - otherwise `FileProbe.read`, mapped as text → `text`, image ≤ `imageLimit` → `image` with the whole file's bytes, image over it → `other`, binary → `other`
- [X] T007 [P] Write `Packages/AgentsKit/Tests/AgentsKitTests/Unit/FileReadingTests.swift`. It covers text, a text file over 128 KB (`isTruncated`), PNG, SVG, a 5 MB image (becomes `other`), binary, a matching stamp (`unchanged`) and the JSON round-trip of every case.
- [X] T008 In `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, add:
  - `Method.filesList = "files/list"`, `filesRead = "files/read"`, `filesWatch = "files/watch"`, `filesUnwatch = "files/unwatch"`, and `Notification.filesChanged = "files/changed"`
  - `FilesListRequest {agentID, folder}`, `FilesReadRequest {agentID, path, knownStamp?}`, `FilesWatchRequest {agentID, folder}` and `FilesChangedNotification {agentID, folders: [String]}`
  - `Failure.fileGone` and `Failure.fileNotReadable`: the next two free codes (-32032 and -32033 at planning time)
  - `ShellInputRequest` gains optional `rows` and `cols`, decoded with `decodeIfPresent`
- [X] T009 In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonServer.swift`, add `notify(_ method:, _ params:, to ids: Set<UUID>)`. It sends on the same per-connection queues as `broadcast`, and only to connections whose `ConnectionIdentity.id` is in `ids`. Keep the ids beside `ConnectionSet`, and expose `surface(of:)` for T047. Wire a `targetedBroadcaster` into `DaemonCore` the way `broadcaster` is wired (look at `Daemon.swift` for where the broadcaster is set).
- [X] T010 Create `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Files.swift` with `listFiles`, `readFile` and a shared `resolveInScope(agentID:path:)`:
  - Every path is standardised and has its symlinks resolved, then checked with `agent.folderScope.allows`. A path out of scope is refused with `scope.refusal(for:)` as `invalidParams`, the same as `artifactWrite`.
  - `DirectoryReader.Failure.gone` and `FileProbe.Failure.gone` become `fileGone`. `notReadable` becomes `fileNotReadable`.
  - A folder sent to `readFile` gets "That is a folder." A file sent to `listFiles` gets "That is a file."
- [X] T011 In the same file, add `watchFiles(_:connection:)`, `unwatchFiles(_:connection:)` and `connectionEnded(_:)`, following data-model.md "FolderWatchInterest":
  - Keep one `FolderWatch` per root, where the root is the scope folder holding the requested folder.
  - Keep `interests: [UUID: Set<Interest>]`.
  - An event sends `files/changed {agentID, folders}` through the targeted broadcaster, only to connections with an interest in (agentID, root).
  - The last interest in a root stops its watch.
  - Call `connectionEnded` from wherever `onDisconnected` reaches `DaemonCore` today (grep `onDisconnected` in `Daemon.swift` and `DaemonCore+Attention.swift`).
- [X] T012 Add the four `files/*` cases to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, passing `connection` to watch and unwatch.
- [X] T013 [P] Write `Packages/AgentsKit/Tests/AgentsKitTests/Integration/FilesRequestTests.swift`, modelled on `ArtifactWriteTests` and `BroadcastIsolationTests`. It checks:
  - the refusal text equals `show_file`'s, and a symlink out of scope is refused
  - folders come first, and the listing is capped with `omitted`
  - `files/read`: text, image, unchanged, gone, and a folder
  - `files/changed` reaches the watching connection id and not another
  - after unwatch, or `connectionEnded`, there are no more events and the watch is released (assert on a `watchCount` testing hook)
- [X] T014 [P] Create `Packages/AgentsKit/Sources/AgentsKitCore/UI/PanePlacement.swift` with `enum PanePlacement { case column(paneWidth: Double), fullScreen }`, `static let minimumPaneWidth = 360.0` and `static func decide(width:, preferredPaneWidth:)`. The rule: a column when `width >= ChatMetrics.comfortablePane + minimumPaneWidth + 1`, with the pane clamped to `minimumPaneWidth...width/2`.
- [X] T015 [P] Write `Packages/AgentsKit/Tests/AgentsKitTests/Unit/PanePlacementTests.swift`. It checks 1,180 and 1,366 → column, 820 and 390 → fullScreen, the 1,021 boundary, and that a preferred width is clamped.
- [X] T016 Create `Remote/Sources/Panes/PaneState.swift`:
  - an `@Observable` `PaneState` per agent, following data-model.md "PaneState": `pane: Pane?` (`.page`, `.files`, `.terminal`, `.exchanged`), `pagePath`, `folder`, `openFile`, `openLine`, `scrollAnchor: [String: Int]` and `showingChanges`
  - `RemotePanes`, holding `[UUID: PaneState]` with `state(for:)`
- [X] T017 Create `Remote/Sources/Panes/RemoteFiles.swift`, the phone's end of `files/*`, owned by `RemoteModel`:
  - `list(agentID:folder:)` and `read(agentID:path:known:)`
  - `watch` and `unwatch` with a local set of what is watched, re-sent after every reconnect
  - `changed`, an `AsyncStream`, or an observed counter keyed by folder, fed from `files/changed`
  - The first `isMethodNotFound` from any `files/*` call sets `RemoteModel.macLacksPanes`, which is cleared on reconnect.
  - Hook the notification into `RemoteModel`'s notification switch (grep `DaemonAPI.Notification` in `Remote/Sources/RemoteModel.swift`).
- [X] T018 Create `Remote/Sources/Panes/PaneHost.swift`:
  - It reads the width with `onGeometryChange`, then asks `PanePlacement`.
  - A column is the chat plus a divider plus the pane, with a close button on the pane.
  - Full screen is a `navigationDestination` push from the chat.
  - The pane's top is a segmented picker of Page, Files, Terminal and Exchanged. Page shows only when `pagePath != nil`, and Terminal is hidden when `macLacksPanes`. There is no Browser segment (FR-030).
  - The bodies are placeholders until their stories land. Exchanged uses the existing `ArtifactsList`.
- [X] T019 In `Remote/Sources/Chat/RemoteChatView.swift`, add a Panes button to the top bar (`sidebar.right` on iPad, `doc.text` on iPhone). It opens the agent's last pane, or Page when `pagePath` is set, or Files. Wrap the chat in `PaneHost`. The chat menu's Exchanged sets `pane = .exchanged` instead of the sheet.
- [X] T020 Run the suite, then build both schemes.

**Checkpoint**:
- The suite is green, apart from the flakes baselined in T001.
- The Mac is untouched in behaviour.
- The phone opens an empty pane beside or over the chat.

---

## Phase 3: User Story 1 - Watch the agent write, from the phone (P1) 🎯 MVP

**Goal**: The Mac's live page, on the phone, following the file on disk.

**Independent Test**: Ask an agent from the phone to write a Markdown document in steps, showing
it first. The page opens and follows each step with no tap.

- [X] T021 [US1] Create `Packages/AgentsKit/Sources/AgentsKitCore/Model/PageFollower.swift` by lifting the logic out of `App/Sources/Sidebar/LivePage.swift`:
  - state: `passages`, `lastLoaded`, `lastWritten`, `editing`, `revealing`, `pending`, `marked`, `collision` and `saveProblem`
  - operations: `load`, `follow(_:)`, `begin`, `edit`, `commit`, `close`, `saved(problem:)`, `tick` and `line(_:)`, each returning `[PageEffect]` (`.scroll(to:)`, `.save(document:)`)
  - `typingStep = 2` and `typingTick = 40 ms` move here as constants
  - the behaviour, and every comment that explains it, stays exactly as in `LivePage` today
- [X] T022 [P] [US1] Write `Packages/AgentsKit/Tests/AgentsKitTests/Unit/PageFollowerTests.swift`. It checks:
  - loading splits
  - a write queues its changed blocks in document order, with one caret
  - a second write completes the first reveal before queueing
  - the echo of `lastWritten` is not news: no reveal and no scroll
  - a delete, which has nothing to type, scrolls to its first change
  - `line(n)` scrolls to and marks the passage holding n
  - opening a passage that is being revealed moves the caret on
- [X] T023 [US1] Create `Shared/UI/Page/PageActions.swift`, an environment value following data-model.md "PageActions":
  - `save(path, document) async -> String?`
  - `image(at: URL) async -> PlatformImage?`, where `PlatformImage` is `NSImage` or `UIImage` under `#if os(macOS)`
  - `imagesChanged: Int`, bumped per folder event
  - `canEdit: Bool`
  - no-op defaults
- [X] T024 [US1] Move `App/Sources/Chat/MarkdownText.swift` to `Shared/UI/Page/MarkdownText.swift`, and `App/Sources/Sidebar/CursorFlag.swift` to `Shared/UI/Page/CursorFlag.swift`:
  - Replace the `NSImage` cache with `PageActions.image`, loaded in a `.task(id:)` per image with a placeholder while it loads.
  - Put AppKit-only modifiers under `#if os(macOS)`.
  - Delete `Remote/Sources/Chat/MarkdownText.swift`, and fix the phone's callers (`DocumentView`, `PlanView` and any in `Shared/UI/Chat`) to the shared signature.
- [X] T025 [US1] Move `App/Sources/Sidebar/LivePage.swift` to `Shared/UI/Page/LivePage.swift`:
  - It drives a `@State var follower: PageFollower`, runs the tick task and performs `.scroll` effects with its `ScrollViewProxy`.
  - It performs `.save` through `PageActions.save`, and replaces `@Environment(AppModel.self)` with `PageActions`.
  - The image-change mark reads `PageActions.imagesChanged` and a per-platform "which passage's picture changed" answer. On the Mac, `ImageStamps` stays in `App/Sources/Sidebar` and feeds it.
  - Typing (`PassageEditor`) stays Mac-only under `#if os(macOS)` until T034.
- [X] T026 [US1] In `App/Sources/Sidebar/FilesPane.swift`, inject `PageActions` for the Mac:
  - save → `model.writeArtifact`
  - image → the disk, with the old cache
  - imagesChanged → `folderEvents` and `ImageStamps`
  - canEdit → true
- [ ] T027 (deferred to the end, 2026-09-24: Alex chose "build on, walk later" while at the keyboard) [US1] Build the Mac. Run the run-app skill on a scratch root and walk quickstart "The Mac page, unchanged after the move". Screenshot four steps, compare with `specs/022-live-artifacts/walk/`, and put the shots in `specs/034-ios-artifacts/walk/`.
- [X] T028 [US1] Create `Remote/Sources/Panes/PagePane.swift`:
  - It reads `pagePath` through `RemoteFiles.read` and watches its folder.
  - On `files/changed` naming the page's folder, it re-reads with the stamp and hands new text to `LivePage`.
  - Its `PageActions`: image through `files/read`, cached by path and stamp. `imagesChanged` is bumped when an image's folder is named.
  - A missing file shows an empty page with the file's name (US1 scenario 1).
  - "\<name\> is gone." keeps the last text, dimmed.
  - The stale banner is on top.
- [X] T029 [US1] Add attention to `Remote/Sources/RemoteModel.swift`:
  - `isTyping: Bool`, set by the prompt bar's focus (`Remote/Sources/Chat/PromptBar.swift`), and later by the passage editor and the terminal.
  - `openFileTheAgentWants()`, when the chat is in front and `!isTyping`, sets the agent's `PaneState`: `.page` with `pagePath` for `.md`, otherwise `.files` with `openFile` and `openLine`. When `macLacksPanes`, it keeps today's `fileOnScreen`.
  - Otherwise it sets `offeredFile`.
- [X] T030 [US1] In `Remote/Sources/Chat/RemoteChatView.swift`, add the "Wants you to see **name**" strip under the top bar, with Open and ✕, from `offeredFile`. Keep `.onChange(of: model.fileTheAgentWants)`, and re-check when `isTyping` becomes false.
- [X] T031 [US1] Build Remote. Build the Mac and walk once more with run-app, to show `show_file` still opens the Mac page.

**Checkpoint**: The page follows on both devices. Slice A's layout (Phase 2 plus this) is ready
for Alex to see on an iPad and an iPhone. **Stop here and ask Alex to look before Phase 4**
(memory: settle the UX before building depth).

---

## Phase 4: User Story 2 - Type on the page from the phone (P1)

**Goal**: A passage opened in place on the phone, saved through `artifact/write`, and never lost
to a dropped connection.

**Independent Test**: Edit a paragraph on the phone, then check `cat` on the Mac and the Mac's
page. Prompt "carry on", and the agent keeps the edit.

- [X] T032 [US2] Add `reconnected(_ fresh:)` to `PageFollower`. With a draft open, it runs `follow` against `fresh` with the same `PassageMerge` carry, and returns `.save`. `saved(problem:)` keeps the draft and sets `saveProblem` on failure. A later `follow` never clears a `saveProblem` while the draft differs from what is on disk.
- [X] T033 [P] [US2] Extend `PageFollowerTests`:
  - an agent's write elsewhere while a passage is open leaves the draft and produces no scroll
  - a write to the same passage gives a collision, keeps mine and saves
  - the echo after a save closes nothing
  - a reconnect with a draft carries it and saves
  - a failed save keeps the draft and the problem
- [X] T034 [US2] Move `App/Sources/Sidebar/PassageEditor.swift` to `Shared/UI/Page/PassageEditor.swift`:
  - macOS keeps the `NSTextView`. iOS gets a `UIViewRepresentable` `UITextView` with the same `draft` binding, `onCommit` after `pauseBeforeSaving` (1 s), `onClose` on end-editing, height fitting to its content, and the paper colours.
  - `LivePage` uses it on both platforms, and opens passages only when `PageActions.canEdit`.
- [X] T035 [US2] Add `writeArtifact(agentID:path:text:) async -> String?` to `Remote/Sources/RemoteModel.swift`, over `artifact/write`, with the Mac's wording for failures (copy `AppModel.writeArtifact`). `PagePane`'s `PageActions.save` calls it, and `canEdit = !model.isStale`. The editor reports focus to `isTyping`.
- [X] T036 [US2] Handle reconnect in `PagePane`. When `isStale` goes false with a draft open, re-watch, re-read, and call `follower.reconnected(fresh)`. While stale, the open editor is read-only with its draft selectable, and a failed save shows "Not saved: \<reason\>" under it.
- [X] T037 [US2] Build Remote. Run the suite. Show `ArtifactWriteTests` still passes with a device surface as the caller (add one case with a `FakeSurface` device connection).

---

## Phase 5: User Story 3 - Browse and read the agent's folder (P2)

**Goal**: The agent's folder as it is on disk, readable from the phone.

**Independent Test**: Walk two folders down and open a file the agent never touched. Open one it
changed: it is marked, and it is current.

- [X] T038 [US3] Move `App/Sources/Sidebar/FileLines.swift` to `Shared/UI/Page/FileLines.swift` (numbered lines, with the named line tinted), keeping the Mac's call sites working.
- [X] T039 [US3] Create `Remote/Sources/Panes/FilesPane.swift`, following contracts/panes-ui.md "Files":
  - **Bar**: Back or Up, and the name truncated at the head.
  - **Listing**: a lazy `List`, folders first, with the Mac's touched dot from `TouchedPaths` and the "N more, not shown" row.
  - **Text**: `FileLines` at `openLine`, with `truncationNote`.
  - **Markdown**: sets `pagePath` and switches to Page.
  - **Image**: `Image(uiImage:)` fitted, with pinch to zoom.
  - **Other**: its sentence.
  - **Refusal, gone, and folder gone**: sentences, as in the contract.
  - It watches the agent's `cwd`. On `files/changed` it re-lists the shown folder when it is named, and re-reads the open file when its parent is named.
- [X] T040 [US3] Keep touched marks true for a long conversation. In `RemoteModel`, add `touchedPaths(for:)`, which folds `work.entries`. On the Files pane's first open for an agent whose loaded page does not reach its first entry, fetch the whole transcript once through the same `agents/transcript` request `loadEarlier` uses, and fold that into a per-agent `TouchedPaths` cache.
- [X] T041 [US3] Rename `Remote/Sources/Chat/FileView.swift` to `Remote/Sources/Chat/ChangesView.swift` (`struct ChangesView`, "What the agent did"). In `FilesPane`, a bar button opens it when the transcript has diffs for the open file.
- [X] T042 [US3] In `RemoteChatView`'s `ChatActions.open`, set `pane = .files` with `openFile` and `openLine` from the `ToolCallLocation`. When `macLacksPanes`, keep `fileOnScreen` and the `ChangesView` sheet.
- [X] T043 [US3] In `Remote/Sources/Chat/DocumentView.swift`'s `ArtifactsList`, an entry whose path is inside the agent's `folderScope` opens the live file (Page for `.md`, otherwise Files). Other entries open as today.
- [X] T044 [US3] Build Remote.

---

## Phase 6: User Story 4 - A shell in the agent's folder, from the phone (P2)

**Goal**: The Mac's shell for this agent, on the phone, with one-tap control keys.

**Independent Test**: Run a command on the Mac, then open the phone's terminal: the same
scrollback is there. Tap ^C once on the phone to interrupt, and the Mac shows the same.

- [X] T045 [US4] Move `App/Sources/Sidebar/ShellClient.swift` to `Packages/AgentsKit/Sources/AgentsKitCore/Client/ShellClient.swift`:
  - It takes a `DaemonClient` and a `describe: (Error) -> String` instead of `AppModel`.
  - `send` includes the client's last known `rows` and `cols`.
  - Keep the behaviour and the comments.
  - Update `App/Sources/Sidebar/TerminalPane.swift` and `App/Sources/AppModel.swift` (`shellClients`, `attachShell` and the rest) to build and feed it.
- [X] T046 [US4] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Shells.swift`, `writeToShell` resizes first when `rows` and `cols` are present, positive and different from the session's size (add `ShellHost.size(agentID:)` if needed), then writes.
- [X] T047 [US4] Route shell notifications to devices (research §9):
  - `DaemonCore` keeps `shellWatchers: [UUID: Set<UUID>]`, from agent to device connections. Attach and restart from a `.device` surface add to it. Detach from it, and `connectionEnded`, remove from it.
  - `forward(_:_:)` sends through a new `broadcast(except devices not watching)`: every `.mac` connection, plus the watching devices. Implement it in `DaemonServer` next to `notify(to:)`.
- [X] T048 [P] [US4] Write `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ShellSizeTests.swift`. It checks:
  - input with a size resizes before writing (read the PTY size back with `stty size` output)
  - input without a size does not resize
  - a device connection hears no `shell/output` until it attaches, and none after it detaches
  - a window hears every shell
- [X] T049 [US4] Create `Remote/Sources/Panes/ShellKeys.swift`, the key row as a `UIInputView`:
  - **^C** (0x03), **Esc** (0x1b), **Tab** (0x09), **← ↑ ↓ →** (`ESC [ D/A/B/C`, or the application-cursor forms when the terminal says so, read from SwiftTerm's `terminal.applicationCursor`)
  - a sticky **Ctrl**, which masks the next typed letter to its control code
  - `| ~ / -`
  - Each key calls `TerminalView.send(_:)`. It follows the paper colours.
- [X] T050 [US4] Create `Remote/Sources/Panes/TerminalPane.swift`:
  - a `UIViewRepresentable` over SwiftTerm's iOS `TerminalView`, painted like `App/Sources/Sidebar/TerminalHostView.swift`, with `inputAccessoryView = ShellKeys`
  - the delegate's `send` goes to `ShellClient.send`, and `sizeChanged` to `ShellClient.resize`
  - it attaches on appear and detaches on disappear
  - it shows "Earlier output was dropped." when `dropped > 0`
  - exited, failed or released states show the daemon's sentence with **Start again** (`restart`)
  - stale: input is disabled and the keyboard dismissed, and on reconnect it re-attaches and replays
  - focus reports to `isTyping`
- [X] T051 [US4] In `Remote/Sources/RemoteModel.swift`, add `shells: [UUID: ShellClient]`, and route `shell/output` and `shell/stateChanged` to them in the notification switch.
- [ ] T052 (builds done 2026-09-24; the Mac terminal walk is deferred to the end with T027) [US4] Build Remote (SwiftTerm on iOS for the first time), then the Mac. On the Mac, walk the terminal pane with run-app: attach, `ls`, resize, then Start again after `exit`.

---

## Phase 7: User Story 5 - The panes sit where the screen has room (P3)

**Goal**: A column on an iPad with room, full screen elsewhere, and each agent's pane where it
was left.

**Independent Test**: On an iPad in landscape, a column beside a running chat. Rotate: it moves
to full screen and keeps its place. Switching agents and back keeps each pane.

- [X] T053 [US5] In `PaneHost`, add a drag handle between the chat and the column. It sets `preferredPaneWidth` on `RemotePanes` (in memory), clamped by `PanePlacement`.
- [X] T054 [US5] Keep each pane's place:
  - `LivePage` and `FileLines` report their top visible index into `PaneState.scrollAnchor[path]` and restore it on appear.
  - Moving between column and full screen, or between agents, re-reads nothing that is current (stamps).
  - The terminal keeps its `ShellClient` across placement changes.
- [X] T055 [US5] Build Remote. Write the iPad and iPhone walk for Alex into `specs/034-ios-artifacts/walk/README.md`, from quickstart.md slices A–E.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T056 Handle the older Mac (FR-029). When `macLacksPanes`:
  - `PaneHost` shows only Exchanged, with the line "Update Agents on your Mac to read files and use the terminal here."
  - Tool-call files open `ChangesView` in a sheet as before.
  - "Look at this" uses `fileOnScreen`.
- [X] T057 [P] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ConsistencyTests.swift`, fail if `Remote/Sources` declares `struct MarkdownText`, `struct LivePage`, `struct PassageEditor`, `PassageMerge` or `final class ShellClient`, or if `App/Sources` does.
- [X] T058 [P] Update `Shared/UI/README.md` for `Shared/UI/Page/` and `PageActions`. Update the `FilesPane` doc comment (read-only apart from the page, now on both devices). Update the `RemoteModel` and `FileView`/`ChangesView` doc comments that say the phone cannot read the Mac's disk.
- [X] T059 Run the full suite six times on this branch and on `main`, and compare the failure sets (memory: the suite is broadly flaky under load). Then build both schemes one after the other.
- [ ] T060 (deferred with T027 and T052: Alex at the keyboard, 2026-09-24; see walk/README.md) Walk the Mac once more with run-app, covering the page, files and terminal, then stop the scratch app. Record what was seen, and what is Alex's, in `specs/034-ios-artifacts/walk/README.md`.

---

## Dependencies & Execution Order

- **Setup (T001–T002)** comes first.
- **Foundational (T003–T020)** blocks every story:
  - T003 and T004 come before T005–T013.
  - T008 comes before T010–T012.
  - T009 comes before T011.
  - T014 comes before T018.
  - T016 and T017 come before T018 and T019.
- **US1 (T021–T031)**: T021 → T022. T023 → T024 → T025 → T026 → T027. T025 and T017 come before T028. T029 → T030.
- **US2 (T032–T037)** needs US1 (the shared page and `PagePane`).
- **US3 (T038–T044)** needs Foundational only. It can go beside US1 after T017.
- **US4 (T045–T052)** needs Foundational only (T008, T009). It can go beside US1 and US3.
- **US5 (T053–T055)** needs the panes it arranges: US1, US3 and US4.
- **Polish (T056–T060)** comes last.

The Phase 3 checkpoint is a stop. Alex looks at the layout on devices before typing, files depth
and the terminal are built.

## Parallel Opportunities

- T004, T007, T013, T014 and T015 touch separate files within Foundational.
- T022 (tests) can be written beside T023–T024.
- After T020, US3's T038–T041 and US4's T045–T048 touch disjoint files from US1's.
- T057 and T058 in Polish.

## Implementation Strategy

1. **MVP**: Setup, Foundational and US1 give a live page on the phone that follows the agent.
   Stop for Alex's look.
2. Add US2 (typing), which makes the page shared, not watched.
3. Add US3 (files) and US4 (terminal), in either order.
4. Add US5 (layout depth), then Polish.

Commit at each checkpoint on `034-ios-artifacts`. Nothing is merged to `main` until Alex says it
is this lane's turn.
