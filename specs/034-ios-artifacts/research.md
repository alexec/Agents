# Research: The Mac's Side Panes on iPhone and iPad

Phase 0 for [plan.md](./plan.md). There were no NEEDS CLARIFICATION markers left in the
technical context. Each section is one decision, checked against the code on `main` at
`b44bb70` (033 merged).

## 1. How the phone reaches files

**Decision**: Four new daemon requests, `files/list`, `files/read`, `files/watch` and
`files/unwatch`, and one notification, `files/changed`. They wrap the existing
`DirectoryReader`, `FileProbe` and `FolderWatch`, which the daemon already links.

**Rationale**:
- The phone's connection is a JSON-RPC line stream to the daemon, carried byte for byte by
  the bridge's `Relay` (`Bridge/Sources/main.swift`). So any daemon request is a phone
  request, with no bridge change. 033's `files/mention` set the pattern.
- The Mac app reads the disk in its own process (`FilesPane` → `DirectoryReader.read`,
  `FileProbe.read`, `FolderWatch`). There is no daemon path at all today, which is why
  `FileView` on the phone had to rebuild files from diffs.

**Alternatives considered**:
- *Move the Mac's files pane onto the new requests too.* One path for both, but it puts a
  round trip where the Mac has none, and rewrites a walked pane for no user-visible gain. It
  is rejected for this feature. The daemon's code is the same reader, so the two cannot
  disagree about what a file is.
- *One `files/open` that streams a file and its changes.* Tidier on the wire, but it is a
  subscription and a read in one call, with no way to re-read a picture on its own. Watch
  and read stay separate.
- *Carry files in the transcript.* It is what the phone does now, and it is the thing the
  spec replaces.

## 2. Where the reading boundary is

**Decision**: Every `files/*` request names an `agentID`, and the path is checked with
`agent.folderScope.allows(_:)`, refused with `scope.refusal(for:)`. Paths are resolved with
symlinks before the check, and the resolved path is what is read.

**Rationale**: FR-015 names the boundary as the one `show_file` uses. `artifact/write`
(`DaemonCore+Artifacts.swift`) already makes exactly this check with that sentence: "one
rule, said one way, whichever door it is met at." `folderScope` is `[cwd] +
additionalDirectories`, and `cwd` is the worktree when the agent has one (030), which is what
FR-010 asks the listing to start at.

**Resolving symlinks first** closes one gap the Mac pane never had to think about: a link
inside the folder pointing out of it. The Mac pane runs as the person, who can read the
target anyway. The phone is a remote door, so a link out of scope is listed but refused when
opened, with the same sentence.

**Alternatives considered**: a device-wide allow list of project folders. It is broader than
the agent's scope and a second rule. Rejected.

## 3. What `files/read` answers

**Decision**: One response type, `FileReading`, with four cases:
- **text**: the 128 KB prefix, whether it was cut, the size, and the stamp.
- **image**: the bytes, base64 on the wire as every `Data` already is, if at most 4 MB.
  Otherwise it is described.
- **other**: `FileProbe`'s description, for a binary.
- **unchanged**: sent when the request carried the stamp the file still has.

"Gone" and "not readable" are errors with their own codes, as `DirectoryReader.Failure` and
`FileProbe.Failure` are today.

**Rationale**:
- `FileProbe` already decides text, image or binary, and already caps text at
  `prefixLimit` (128 KB), which is FR-013's "shown in part, saying so".
- The stamp (size plus modification date) is what lets the page re-read a picture on every
  folder event without re-sending it. It replaces `ImageStamps`' `stat` on the phone.
- JSON-RPC lines are all-or-nothing, so a half-received file never looks whole (the "very
  slow connection" edge case).

**The 4 MB cap** is for pictures only. A photo from a camera is the case it catches. It keeps
a single line from holding the connection's other notifications for seconds on a slow link.

## 4. Watches belong to connections

**Decision**:
- `files/watch {agentID, folder}` starts one `FolderWatch` per watched root folder, shared by
  every connection watching under it. The root is the scope folder holding `folder`.
- The daemon keeps `[connection: Set<(agentID, folder)>]`.
- `files/changed {agentID, folders}` goes only to connections watching that agent, through a
  new `DaemonServer.notify(_:_:to:)` beside `broadcast`.
- `files/unwatch`, or the connection ending (`onDisconnected`, which already exists for
  presence), removes the interest. The last interest in a root stops its `FolderWatch`.

**Rationale**:
- A phone that goes away without saying so (the ordinary way on iOS) must not leave FSEvents
  streams running in the daemon. `DaemonServer` already calls `onDisconnected(identity.id)`,
  so the cleanup has a hook.
- The event names directories, not files, exactly as `FolderWatch` hands them over. The phone
  re-reads the listing it shows if that directory is named, and the file it has open if its
  parent is.

**Alternatives considered**: broadcast `files/changed` to everyone, as every other
notification is. It is harmless on the Mac socket, but every device would be told about
every watched folder over WiFi, for panes it is not showing. Rejected (plan, Complexity
Tracking).

## 5. Which files the agent changed

**Decision**: As on the Mac, from the transcript the client holds, with `TouchedPaths` moved
to `AgentsKitCore` unchanged. The phone folds the entries it has loaded. When the Files pane
opens it asks for the transcript from the start, once, if the loaded page does not reach
back to it. That is the same request "load earlier" makes.

**Rationale**:
- FR-011 says "as the Mac's does". The Mac folds `model.entries`.
- Asking the daemon to compute it would be a second definition of "touched" that could drift
  from the first.
- Fetching the whole transcript on opening Files costs one request per agent. It is the
  honest way to make the mark true for a long conversation. It is done lazily, not on every
  chat open.

**Alternative considered**: marking only from the loaded page. That is cheaper, but a file
edited an hour ago would lose its mark on the phone and keep it on the Mac. Rejected.

## 6. One page on both devices

**Decision**:
- `LivePage` is split in two. `PageFollower` is a value type in `AgentsKitCore` holding the
  passages, the marks, the caret's reveal queue, the editing passage, `lastLoaded` and
  `lastWritten`. Its methods are `load`, `follow(new:)`, `begin`, `commit`, `close`, `tick`
  and `reconnected(fresh:)`, and each returns what the view should do (scroll to, write this
  document, show this collision).
- The SwiftUI view moves to `Shared/UI/Page/LivePage.swift` and drives it.
- Per-platform needs come through `PageActions` in the environment:
  `save(document) async -> String?` and `image(at:) async -> PlatformImage?`.
- `PassageEditor` is `#if os(macOS)` `NSTextView`, else `UITextView`. The pause-to-save
  (`pauseBeforeSaving`, 1 s), the height fitting and the caret report are the same on both.
- The Mac's `MarkdownText` (with `base` and `caret`) becomes the one `MarkdownText` in
  `Shared/UI/Page/`. Its image cache goes behind `PageActions.image`. The Remote's
  `MarkdownText` is deleted, and the phone's chat and document views use the shared one.

**Rationale**:
- FR-001 says "the same page". Two copies of a page is how two `MarkdownText`s came to draw
  different sizes (Shared/UI README).
- The page's logic has never been under test because it is `@State` inside a view.
  Lifting it gives 022's scenarios (follow, one caret, echo, merge carry) unit tests before
  the phone depends on them.
- The phone adds one case the Mac never had, a reconnect with a draft open. It is one more
  method on the same follower: `reconnected(fresh:)` treats the fresh read as a `follow` with
  the draft still open, so `PassageMerge` carries it across and the result is written.
  Nothing new decides a collision (FR-008, FR-009).

**Alternatives considered**:
- *A phone page drawing the file read-only, with a separate editor sheet.* Simpler, but it
  is not "the same page", and US2 scenario 1 asks for the passage to open in place.
- *A web view with the Markdown rendered as HTML.* 022 ruled out a web view on the page.

## 7. The terminal on iOS

**Decision**:
- SwiftTerm's `TerminalView` (UIKit) in a `UIViewRepresentable`, fed by a `ShellClient` that
  moves from `App/Sources/Sidebar` to `AgentsKitCore/Client`, over `DaemonClient` instead of
  `AppModel`. The Mac's `TerminalPane` uses the moved one.
- The key row is our own `inputAccessoryView`: **^C, Esc, Tab, ←, ↑, ↓, →**, a sticky
  **Ctrl** for any other control key, and `| ~ / -`. On an iPad with a hardware keyboard,
  SwiftTerm's `pressesBegan` handles the keys directly.

**Rationale**:
- SwiftTerm is already the Mac's emulator, and the replay property (`shell/attach` gives
  scrollback bytes, and feeding them gives the same screen) is proven by the kit's test with
  SwiftTerm.
- Checked in the SwiftTerm checkout: `Sources/SwiftTerm/iOS/iOSAccessoryView.swift` has
  `TerminalAccessory` with Esc, a *sticky* Ctrl, Tab and arrows. SC-005 asks for Control-C in
  **one** tap, and the stock bar makes it two. It is also a `UIInputView` we cannot add a key
  to without subclassing its private layout. Our own row is about 60 lines, and it calls
  `TerminalView.send(_:)`.
- SwiftTerm's `LocalProcess` and `LocalProcessTerminalView` are `#if os(macOS)`, so linking
  it into the Remote brings no process-spawning code. The Remote's "no `Process`, no PTY"
  rule holds.

**Alternative considered**: SwiftTerm's `SwiftUITerminalView`. It wraps its own process
handling. Rejected, as the Mac's `TerminalHostView` rejected `LocalProcessTerminalView`.

## 8. Whose size the shell has

**Decision**: `ShellInputRequest` gains optional `rows` and `cols`. When present and
different from the shell's size, the daemon resizes before writing. Each client sends its own
size with every keystroke batch. `shell/resize` stays for layout changes.

**Rationale**:
- US4 scenario 5: "the size the shell uses is the size of whichever device typed last." The
  daemon is the only place that knows the order of two devices' keystrokes.
- A resize that is the same size is a no-op in `ShellSession`.
- Optional fields keep older clients working, and an older daemon ignores them. A phone on
  an older Mac still resizes by `shell/resize` on layout.

**Alternative considered**: resize on focus. Focus is not reported across devices, and a
phone that took focus without typing would squeeze the Mac's pane for nothing.

## 9. Shell output to devices

**Decision**:
- The daemon records which *device* connections (`surface == .device`) have attached which
  agents' shells.
- `shell/output` and `shell/stateChanged` go to every window (unchanged) and to those
  devices only.
- `shell/detach` from a device, or its disconnect, removes it. Detaching still never stops
  the shell (FR-023).

**Rationale**: Today every connection hears every shell's bytes (`ShellHost`'s one
broadcaster). A phone joining that would carry an unrelated agent's `npm install` over WiFi
while it shows the page.

**Alternative considered**: filtering on the phone. The bytes would still cross the network.

## 10. Where a pane sits

**Decision**: `PanePlacement.decide(width:)` in `AgentsKitCore`:
- **column** when `width ≥ ChatMetrics.comfortablePane + minimumPaneWidth + divider` (660 + 360 + 1 pt)
- **fullScreen** otherwise

`minimumPaneWidth` is 360 pt, the narrowest a page holds 60 characters at the phone's
reading step (`PageMetrics`' floor). The iPad column is resizable between that and half the
screen. Full screen is a push on the chat's `NavigationStack`, so the chat is one back tap
away and keeps its scroll position (FR-025).

**Rationale**:
- A pure function of widths is testable and has no size-class guesswork. An iPad in a narrow
  Split View gets full screen, as the spec asks.
- A push, not a sheet: the sheet is today's look-aside, and a sheet over a pane that follows
  the agent hides the chat's place.

**Where it is opened from**: one button in the chat's top bar. It opens the last pane used
for that agent (Page if there is a page, else Files), and a segmented switcher at the pane's
top gives Page, Files, Terminal and Exchanged. That is one tap to a pane and two to any
(FR-024, SC-003's four taps with two folders down). The chat's menu keeps Exchanged for
familiarity.

## 11. "Look at this" on the phone

**Decision**: When `agent/showFile` arrives for the conversation in front, and no text field
is focused (prompt bar, page passage, terminal), the pane opens:
- a Markdown file as the Page
- any other file in Files at the line

Otherwise the file is offered in that chat as a strip under the top bar ("Wants you to see
plan.md — Open"), for as long as `AgentsModel.filesToShow` holds it.

**Rationale**:
- FR-004 and FR-005, and 013's rule that the phone never takes the screen for an agent that
  is not in front.
- `filesToShow` already keeps the request per agent. Today `openFileTheAgentWants` takes it
  whenever the chat is selected. The one new condition is "not typing". Focus is known to
  SwiftUI through `@FocusState`, and the three fields report it to `RemoteModel.isTyping`.

## 12. An older Mac

**Decision**: The first `files/list` or `files/read` that fails with `methodNotFound`
(`JSONRPCError.isMethodNotFound`) sets `RemoteModel.macLacksPanes` for the connection. The
pane button then opens today's views: `DocumentView`, `FileView` rebuilt from diffs and the
Exchanged list. A note says "Update Agents on your Mac to read files and use the terminal
here." The terminal is hidden, never shown empty (FR-029).

**Rationale**: It is what 033 did for `files/mention`, and it needs no version handshake. The
shell requests have existed since 002, so an older Mac can attach. But a phone that can use a
shell and cannot read files is a stranger half-state than the old one, and the spec asks for
the old behaviour. The terminal waits for `files/*`.

## 13. Staleness and a draft in flight

**Decision**:
- While `RemoteModel.isStale` is true, the page, listing, reader and terminal keep what they
  show under the existing `StaleBanner`.
- Passage editors and the terminal's input are disabled. An open passage keeps its draft,
  read-only and selectable, so it can be copied.
- On reconnect the phone re-sends `files/watch` for what is open (a new connection has none),
  re-reads the file and hands it to `PageFollower.reconnected(fresh:)`.
- If the save that follows fails, the passage says "Not saved: <reason>" under the draft,
  with the draft still there (SC-008).

**Rationale**: FR-009 and FR-028. Watches die with the old connection by design (§4), so
re-watching is part of reconnecting, like `attention/pending` is today.
