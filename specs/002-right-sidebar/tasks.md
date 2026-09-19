---

description: "Task list for The right sidebar"
---

# Tasks: The right sidebar

**Input**: Design documents from `specs/002-right-sidebar/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included. The plan puts every piece that decides anything in `AgentsKit` precisely so
`swift test` can reach it, and three of them (the binary probe, the idle rule, the artifact filter)
have awkward cases that are unreasonable to check by hand. Emulation itself is not tested here: it is
SwiftTerm's and SwiftTerm tests it.

**Organization**: By user story, in the priority order the spec sets. Each story is shippable on its
own.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on unfinished work)
- Paths are exact

**One deviation from the spec, deliberately**: the spec folds the sidebar frame into User Story 1,
because opening and sizing the column is what you do first to read a file. Here the frame is Phase 2
instead. All four panes need it, and putting it in US1 would make the other three stories depend on
US1 rather than stand alone. US1 is still the MVP and still delivers the spec's value on its own.

---

## Phase 1: Setup

- [X] T001 Leave `Packages/AgentsKit/Package.swift` without SwiftTerm: AgentsKit is linked by `agentsd` as well as the app, so a dependency there would reach the daemon, which parses nothing and MUST NOT link it (plan decision 2). Record the reason in a comment beside the empty `dependencies:` array
- [X] T002 Add SwiftTerm to `project.yml` at the repository root: a `packages:` entry (`url: https://github.com/migueldeicaza/SwiftTerm`, `from: 1.2.0`) and a `dependencies: - package: SwiftTerm` on the `Agents` target only, leaving `agentsd` untouched, then run `xcodegen generate`
- [X] T003 [P] Confirm `project.yml` picks up the new source folders (`App/Sources/Sidebar/`, `Packages/AgentsKit/Sources/AgentsKit/Terminal/`, `Packages/AgentsKit/Sources/AgentsKit/Files/`) without an XcodeGen change, and regenerate if it does not
- [X] T004 [P] Capture byte streams from real `vim`, `htop` and `less` sessions into `Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/terminal/` (use `script -q` against a pty), for the replay tests
- [X] T005 [P] Write `Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/terminal/README.md` saying which program and which terminal size produced each capture, so a failing replay test can be read

---

## Phase 2: Foundational (blocks every story)

**Purpose**: the column itself, and the state that says where it is. No pane has content yet.

**⚠️ CRITICAL**: no user story work can begin until this phase is complete

- [X] T006 Create `SidebarFrame` (`isOpen: Bool` defaulting to false, `width: Double`, `pane: Pane` with cases `.files`, `.terminal`, `.browser`, `.artifacts`) persisted in `UserDefaults`, in `App/Sources/Sidebar/SidebarState.swift`
- [X] T007 Clamp `width` in `App/Sources/Sidebar/SidebarState.swift` on read as well as on write, so a value stored on a larger screen that would leave no room for the conversation is brought back into range rather than honoured (FR-003, FR-004)
- [X] T008 Create `AgentPaneState` (`agentID: UUID`, `folder: URL?`, `openFile: URL?`, `browserURL: URL?`, `attachedShell: Bool`) held in memory for the window's life and keyed by agent, in `App/Sources/Sidebar/SidebarState.swift` (FR-005)
- [X] T009 Build the column in `App/Sources/Sidebar/SidebarView.swift`: one pane visible at a time, a picker for the four, a draggable width, and a close control (FR-001, FR-003)
- [X] T010 Place the sidebar as a sibling of the conversation in `App/Sources/ContentView.swift`, so the conversation keeps the rest of the window (FR-003)
- [X] T011 Enforce the minimum conversation width in `App/Sources/Sidebar/SidebarView.swift`: below it the sidebar cannot be opened and the control says why, rather than doing nothing (spec edge case: the narrow window)
- [X] T012 Draw the no-agent empty state in `App/Sources/Sidebar/SidebarView.swift`, naming why there is nothing to show, rather than four blank panes (FR-007)
- [X] T013 Make the closed sidebar cost nothing in `App/Sources/Sidebar/SidebarView.swift`: no folder watch, no web view, no shell attach is created while `isOpen` is false (FR-006, SC-009)
- [X] T014 Rebuild per-agent pane state on agent switch in `App/Sources/Sidebar/SidebarView.swift`, keeping hidden panes alive rather than tearing them down on a pane switch; what the sidebar shows MUST follow the selected agent (FR-002, FR-005)

**Checkpoint**: the column opens, closes, resizes and remembers itself across a restart. Every pane is a placeholder. 001 is untouched with it closed.

---

## Phase 3: User Story 1 - See what the agent is doing to the folder (P1) 🎯 MVP

**Goal**: read the file the agent said it changed, without leaving the window.

**Independent Test**: start an agent on a task that edits a file, open the sidebar, find the file it named, read the new contents.

### Tests for User Story 1

- [ ] T015 [P] [US1] Test `FileProbe` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/FileProbeTests.swift` with UTF-16 including a BOM, a PNG, an empty file, and a file that is valid UTF-8 for the whole prefix and rubbish after it
- [ ] T016 [P] [US1] Test `DirectoryReader` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/DirectoryReaderTests.swift` for sort order, the entry cap, and a directory that disappears between listing and reading
- [ ] T017 [P] [US1] Test the touched-paths fold in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/TouchedPathsTests.swift`: a transcript with tool call `locations` and `diff` paths yields their union, and a file changed by nobody is absent

### Implementation for User Story 1

- [ ] T018 [P] [US1] Create `FileProbe` in `Packages/AgentsKit/Sources/AgentsKit/Files/FileProbe.swift` returning `kind` (`.text(encoding:)` or `.binary(describedAs:)`), `prefix: Data`, `isTruncated: Bool` and `size: Int`; a NUL byte in the first chunk MUST mean binary, invalid UTF-8 MUST mean binary, and `size` MUST come from the file's attributes rather than from reading it (FR-014, FR-015)
- [ ] T019 [P] [US1] Create `DirectoryEntry` (`url`, `name`, `isDirectory`, `size: Int?` nil for a directory, `modifiedAt: Date?`, `touchedByAgent: Bool`) and `DirectoryReader` in `Packages/AgentsKit/Sources/AgentsKit/Files/DirectoryReader.swift`, reading one level only; directories MUST sort first, then files, each by name case-insensitively, and a directory over the entry cap MUST report how many more there are (FR-010, FR-015)
- [ ] T020 [US1] Create `FolderWatch` in `Packages/AgentsKit/Sources/AgentsKit/Files/FolderWatch.swift` over `FSEventStreamCreate`, coalesced and directory-level, reporting the directories that changed rather than every file (FR-012)
- [ ] T021 [US1] Compute the touched-path set from an agent's transcript in `Packages/AgentsKit/Sources/AgentsKit/Files/TouchedPaths.swift`: the union of every `ToolCallLocation.path` and every `ToolCallContent.Diff.path`, folded once per agent and updated as entries arrive (FR-013)
- [ ] T022 [US1] Build the folder listing in `App/Sources/Sidebar/FilesPane.swift`, starting at the selected agent's folder, with a way into and out of directories (FR-010)
- [ ] T023 [US1] Show a chosen text file's contents in `App/Sources/Sidebar/FilesPane.swift` from the probe's prefix, saying there is more when it is truncated (FR-011, FR-015)
- [ ] T024 [US1] Show what a file is rather than its bytes when the probe says binary, in `App/Sources/Sidebar/FilesPane.swift` (FR-014)
- [ ] T025 [US1] Mark every entry whose path is in the touched set, in `App/Sources/Sidebar/FilesPane.swift`, so the agent's work is findable without reading the conversation (FR-013)
- [ ] T026 [US1] Redraw the open file and the shown directory on a `FolderWatch` event in `App/Sources/Sidebar/FilesPane.swift`, within 2 seconds of the write landing (FR-012, SC-002)
- [ ] T027 [US1] Say what happened when the folder or the open file disappears, in `App/Sources/Sidebar/FilesPane.swift`, and clear the contents rather than leaving stale ones on screen (FR-016)
- [ ] T028 [US1] Keep the pane read-only: no create, rename, delete or edit affordance anywhere in `App/Sources/Sidebar/FilesPane.swift` (FR-017)
- [ ] T029 [US1] Persist the pane's folder and open file into `AgentPaneState` in `App/Sources/Sidebar/FilesPane.swift`, so returning to an agent returns to where the user left off (FR-005)

**Checkpoint**: User Story 1 is complete. Quickstart scenario 1 passes, and the feature is worth shipping on its own.

---

## Phase 4: User Story 2 - Run something yourself, in the same folder (P1)

**Goal**: a shell in the agent's folder that outlives the window.

**Independent Test**: open the terminal pane on a running agent, run a command that prints the working folder, see the agent's folder. Run a build and watch it scroll.

### Tests for User Story 2

- [ ] T030 [P] [US2] Test `PTY` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/PTYTests.swift`: a shell spawns, `tty` reports a terminal device, a resize reaches the child, and the exit status is reported
- [ ] T031 [P] [US2] Test `Scrollback` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ScrollbackTests.swift`: the cap drops from the front, the tail is what comes back, and a buffer that has dropped says so
- [ ] T032 [P] [US2] Test the idle rule in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ShellIdleTests.swift`: a shell with a running child is never idle whatever the clock says; one with no child and no input past the threshold is
- [ ] T033 [P] [US2] Test replay in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ReplayTests.swift`: each fixture in `Fixtures/terminal/` fed one byte at a time gives the same screen as fed in one chunk. This is the property `shell.attach` rests on

### Implementation for User Story 2

- [ ] T034 [P] [US2] Create `PTY` in `Packages/AgentsKit/Sources/AgentsKit/Terminal/PTY.swift` using `openpty` and `posix_spawn` with `POSIX_SPAWN_SETSID`, the child opening the slave device as its first tty so it becomes the controlling terminal; expose read, write, `TIOCSWINSZ` resize, signal, and exit status (FR-020, FR-021, research section 2)
- [ ] T035 [P] [US2] Create `Scrollback` in `Packages/AgentsKit/Sources/AgentsKit/Terminal/Scrollback.swift` as a ring buffer of raw bytes with a byte cap, dropping from the front and recording that it has dropped
- [ ] T036 [P] [US2] Create `ShellState` in `Packages/AgentsKit/Sources/AgentsKit/Model/ShellState.swift` with exactly `live`, `exited(status: Int32)`, `failed(reason: String)` and `released(reason: String)`
- [ ] T037 [US2] Create `ShellSession` in `Packages/AgentsKit/Sources/AgentsKit/Terminal/ShellSession.swift` holding one `PTY`, one `Scrollback`, a `ShellState`, `startedAt`, `lastInputAt` and an optional `title`; it MUST NOT parse bytes (depends on T034, T035, T036)
- [ ] T038 [US2] Add `isBusy` (a child of the shell is running) and `isIdle` to `ShellSession` as pure functions of `isBusy`, `lastInputAt` and the clock, in `Packages/AgentsKit/Sources/AgentsKit/Terminal/ShellSession.swift` (FR-027, FR-028)
- [ ] T039 [US2] Start a shell in the agent's folder with the user's login shell (via the existing `LoginShellPath`) in `Packages/AgentsKit/Sources/AgentsKit/Terminal/ShellSession.swift`; a folder that no longer exists MUST become `failed` naming the folder, and a shell that will not exec MUST become `failed` (FR-020, FR-024)
- [ ] T040 [US2] Create `ShellHost` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/ShellHost.swift` holding at most one `ShellSession` per agent, keyed by agent id, with attach, detach and reap; attach MUST start a shell if the agent has none, and detach MUST NOT kill anything (FR-023, FR-026)
- [ ] T041 [US2] Track attached connections per agent in `Packages/AgentsKit/Sources/AgentsKit/Daemon/ShellHost.swift`, dropping a connection when its socket closes, so a crashed app leaves no subscriber behind
- [ ] T042 [US2] Reap idle shells on a tick in `Packages/AgentsKit/Sources/AgentsKit/Daemon/ShellHost.swift`, setting `released(reason:)`, and count a busy shell in the work the daemon is holding so it does not shut down under one (FR-027, FR-028)
- [ ] T043 [US2] Kill every shell before the daemon exits, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/ShellHost.swift`, so no pty is orphaned
- [ ] T044 [US2] Add the `shell.*` methods and the `shell.output` and `shell.stateChanged` notifications to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonAPI.swift`, keeping them distinct from 003's agent-owned `terminal.*` and `agent/terminalOutput` (FR-025, contract)
- [ ] T045 [US2] Add error codes `-32010 shellWillNotStart` and `-32011 shellNotLive` to `DaemonAPI.Failure` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonAPI.swift`
- [ ] T046 [US2] Serve `shell.attach`, `shell.detach`, `shell.input`, `shell.resize`, `shell.signal` and `shell.restart` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Shells.swift`; `shell.attach` MUST return the state plus the scrollback tail as raw bytes for the client to replay, and `shell.restart` MUST be refused with `shellNotLive` when the shell is still live (contract)
- [ ] T047 [US2] Push `shell.output` as base64 bytes to every attached connection in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Shells.swift`, never decoding to a `String` on the way through (contract)
- [ ] T048 [US2] Mark a shell gone with its reason after a daemon restart in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Shells.swift`, rather than handing back a new one silently (FR-029)
- [ ] T049 [US2] Add the shell calls and notification subscriptions to `Packages/AgentsKit/Sources/AgentsKit/Client/DaemonClient.swift`
- [ ] T050 [US2] Wrap SwiftTerm's macOS `TerminalView` in `App/Sources/Sidebar/TerminalHostView.swift` as an `NSViewRepresentable`, sized to the pane and using a fixed-width font
- [ ] T051 [US2] Own a SwiftTerm `Terminal` per agent in `App/Sources/Sidebar/TerminalPane.swift`, feeding it the scrollback tail on attach and `shell.output` bytes as they arrive (depends on T049, T050)
- [ ] T052 [US2] Send keystrokes to `shell.input` from `App/Sources/Sidebar/TerminalPane.swift`, including single keypresses; `^C` MUST go through `shell.input` and the line discipline rather than through `shell.signal` (FR-021, contract)
- [ ] T053 [US2] Send the pane's rows and columns to `shell.resize` on layout change in `App/Sources/Sidebar/TerminalPane.swift`, so a full-screen program reflows (FR-021)
- [ ] T054 [US2] Show the title set by OSC 0 or 2 in `App/Sources/Sidebar/TerminalPane.swift` when a program sets one
- [ ] T055 [US2] Draw the not-live states in `App/Sources/Sidebar/TerminalPane.swift`: say what happened for `exited`, `failed` and `released`, keep the scrollback readable, and offer to start a new shell via `shell.restart` (FR-024, FR-028, FR-029)
- [ ] T056 [US2] Keep the attachment across pane switches and agent switches in `App/Sources/Sidebar/TerminalPane.swift`, detaching only when the window closes (FR-022, FR-026)

**Checkpoint**: quickstart scenarios 2 and 3 pass. A build survives quitting the app, and two windows on one agent see one shell.

---

## Phase 5: User Story 3 - Look at what the agent built (P2)

**Goal**: a page beside the conversation, driven by the user.

**Independent Test**: with a local server running in the agent's folder, open the browser pane, go to the address, see the page. Change a file, reload, see the change.

### Tests for User Story 3

- [ ] T057 [P] [US3] Test the navigation policy in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BrowserPolicyTests.swift`: `http`, `https`, `about` and `file` are allowed and every other scheme is refused, written as a pure function over a URL so it is testable without a web view

### Implementation for User Story 3

- [ ] T058 [P] [US3] Create the scheme policy as a pure function in `Packages/AgentsKit/Sources/AgentsKit/Files/BrowserPolicy.swift`, allowing only `http`, `https`, `about` and `file` and refusing by default (FR-034)
- [ ] T059 [US3] Create `App/Sources/Sidebar/BrowserPane.swift` wrapping a `WKWebView` with its own non-default `WKWebsiteDataStore`, held per agent outside the view tree so it is not recreated when the pane is hidden; nothing in the app MUST be able to navigate it on an agent's behalf (FR-031, FR-033, FR-035)
- [ ] T060 [US3] Add an address field and back, forward and reload controls in `App/Sources/Sidebar/BrowserPane.swift` (FR-030)
- [ ] T061 [US3] Refuse window creation in `App/Sources/Sidebar/BrowserPane.swift` by returning nil from `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)` (FR-034)
- [ ] T062 [US3] Apply `BrowserPolicy` in `decidePolicyFor navigationAction` in `App/Sources/Sidebar/BrowserPane.swift`, refusing visibly rather than silently (FR-034)
- [ ] T063 [US3] Refuse downloads in `App/Sources/Sidebar/BrowserPane.swift`, and ask the user before granting camera or microphone via `requestMediaCapturePermissionFor` (FR-034)
- [ ] T064 [US3] Say what failed on `didFailProvisionalNavigation` in `App/Sources/Sidebar/BrowserPane.swift`, naming connection refused, host not found and timeout in plain words and offering reload, rather than showing a blank panel (FR-032)
- [ ] T065 [US3] Keep the current URL in `AgentPaneState` in `App/Sources/Sidebar/BrowserPane.swift`, so switching agents and coming back shows the same page (FR-031)

**Checkpoint**: quickstart scenario 4 passes.

---

## Phase 6: User Story 4 - Keep the things worth keeping (P2)

**Goal**: what the agent handed over, in one list, away from the messages it arrived in.

**Independent Test**: run the fake agent until it has sent resource blocks, open the pane, find one without scrolling the conversation.

### Tests for User Story 4

- [ ] T066 [P] [US4] Test annotation decoding in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ContentBlockTests.swift`: `annotations` with `audience` and `priority` survive a round trip, and a block without annotations still decodes
- [ ] T067 [P] [US4] Test the artifact filter in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ArtifactTests.swift`: a transcript holding `resource_link` blocks, embedded `resource` blocks, tool calls with `locations` and `diff`, and plain messages yields exactly the resource blocks, newest first; a block whose `annotations.audience` is present and does not include `user` is excluded; a block with no annotations is included

### Implementation for User Story 4

- [ ] T068 [US4] Decode `annotations` (`audience`, `priority`) on `resourceLink` and `resource` in `Packages/AgentsKit/Sources/AgentsKit/ACP/ContentBlock.swift`, keeping them on the round trip out (research section 1)
- [ ] T069 [US4] Create `Artifact` (`id`, `uri`, `name`, `mimeType: String?`, `size: Int?`, `arrivedAt`, `entryID`, `embedded: Bool`) in `Packages/AgentsKit/Sources/AgentsKit/Model/Artifact.swift`; `name` MUST fall back to the uri's last path component when the agent sent none (depends on T068)
- [ ] T070 [US4] Write the filter over transcript entries in `Packages/AgentsKit/Sources/AgentsKit/Model/Artifact.swift` as a pure function: a `resource_link` or embedded `resource` block is an artifact and nothing else is; a file a tool call touched MUST NOT be listed. Deriving on read is what makes FR-044 free: nothing is stored, so artifacts last as long as the transcript does, across restarts and for a stopped or archived agent (FR-044, FR-046)
- [ ] T071 [US4] Build the list in `App/Sources/Sidebar/ArtifactsPane.swift`, newest first, each showing what it is and when it arrived (FR-040)
- [ ] T072 [US4] Write the empty state in `App/Sources/Sidebar/ArtifactsPane.swift` saying what will appear there, in the app's own voice, reading as a fact rather than an apology or an error; this is the pane's ordinary screen against every runtime installed today (FR-043, research section 1)
- [ ] T073 [US4] Update the list on the existing `agent/entry` notification in `App/Sources/Sidebar/ArtifactsPane.swift`, with no new push added to the daemon (FR-041)
- [ ] T074 [US4] Open a chosen artifact in `App/Sources/Sidebar/ArtifactsPane.swift`: a `file:` uri in the files pane, an `http(s)` uri in the browser, and an embedded `resource` read in place (FR-042)
- [ ] T075 [US4] Offer a way from an artifact to the message it came from, by `entryID`, in `App/Sources/Sidebar/ArtifactsPane.swift` (FR-042)
- [ ] T076 [US4] Keep an artifact in the list and say it has gone when its uri no longer resolves, in `App/Sources/Sidebar/ArtifactsPane.swift`, rather than hiding it (FR-045)

**Checkpoint**: quickstart scenario 5 passes. Expect the empty state against real runtimes; the fake agent proves the rest.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T077 Pick the scrollback byte cap in `Packages/AgentsKit/Sources/AgentsKit/Terminal/Scrollback.swift` against what a real `xcodebuild` run prints, replacing the placeholder (research section 8)
- [ ] T078 Pick the idle threshold in `Packages/AgentsKit/Sources/AgentsKit/Terminal/ShellSession.swift` from use, replacing the placeholder (research section 8)
- [ ] T079 Pick the minimum conversation width in `App/Sources/Sidebar/SidebarView.swift` in front of the running app, replacing the placeholder (research section 8)
- [ ] T080 [P] Check a folder of 50,000 entries stays responsive and that the tree is never walked, per scenario 7 of `specs/002-right-sidebar/quickstart.md` (FR-015)
- [ ] T081 [P] Check a 200MB log opens to its start quickly and says there is more, per scenario 7 of `specs/002-right-sidebar/quickstart.md` (FR-015)
- [ ] T082 Run an agent runtime inside the terminal pane and confirm nothing claims it is one of this app's agents, per the last row of scenario 7 in `specs/002-right-sidebar/quickstart.md` (spec edge case)
- [ ] T083 Confirm SC-009 by hand, per scenario 6 step 4 of `specs/002-right-sidebar/quickstart.md`: with the sidebar closed, start an agent, follow up and stop it, with no step added anywhere and nothing of the sidebar running
- [ ] T084 Strike the "No third-party dependencies" line from `specs/001-agent-daemon-ui/plan.md:46`, and the matching claim in `specs/003-acp-coverage/plan.md`, since the rule does not exist and a future planning pass will read it
- [ ] T085 [P] Time SC-001 and SC-003 against the running app, per scenarios 1 and 2 of `specs/002-right-sidebar/quickstart.md`: agent's claim to reading the file under 10 seconds, shell ready to type into within 2 seconds
- [ ] T086 [P] Confirm SC-005 by switching between ten agents with the sidebar open, per scenario 6 step 3 of `specs/002-right-sidebar/quickstart.md`: the window stays responsive and each agent returns to the pane and position it was left at
- [ ] T087 Confirm SC-006 and SC-010 by hand, per scenario 3 of `specs/002-right-sidebar/quickstart.md`: nothing running in a terminal is lost by moving between panes or agents, and a build still running when the app is quit is still running 60 seconds later with all its output
- [ ] T088 [P] Confirm SC-004, SC-007 and SC-008 against the running app, per scenarios 2, 4 and 5 of `specs/002-right-sidebar/quickstart.md`
- [ ] T089 Run the whole of `specs/002-right-sidebar/quickstart.md` end to end and record what failed

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: needs Setup. Blocks every user story
- **User stories (Phases 3 to 6)**: each needs Foundational and nothing else. They may run in parallel or in priority order
- **Polish (Phase 7)**: needs the stories it touches

### User Story Dependencies

- **US1 Files (P1)**: needs Phase 2 only. The MVP
- **US2 Terminal (P1)**: needs Phase 2 only. The largest story by some way
- **US3 Browser (P2)**: needs Phase 2 only. Quickstart scenario 4 uses the terminal to start a server, but any other way of starting one does as well
- **US4 Artifacts (P2)**: needs Phase 2 only. Opening an artifact is better with US1 and US3 present, and degrades to reading an embedded resource in place without them

### Within Each Story

- Kit before app: the pure pieces are testable with no window and come first
- Tests alongside the piece they cover, not after the story
- `ShellHost` before the daemon serving, daemon serving before the client, client before the pane

### Parallel Opportunities

- T003, T004, T005 together
- T015, T016, T017 together, and T018, T019 together
- T030 to T033 together, and T034, T035, T036 together
- T066, T067 together
- T080, T081 together, and T085, T086, T088 together
- With more than one person: US1, US2, US3 and US4 all at once after Phase 2

---

## Parallel Example: User Story 2

```bash
# The tests first, all independent:
Task: "Test PTY in Packages/AgentsKit/Tests/AgentsKitTests/Unit/PTYTests.swift"
Task: "Test Scrollback in Packages/AgentsKit/Tests/AgentsKitTests/Unit/ScrollbackTests.swift"
Task: "Test the idle rule in Packages/AgentsKit/Tests/AgentsKitTests/Unit/ShellIdleTests.swift"
Task: "Test replay in Packages/AgentsKit/Tests/AgentsKitTests/Unit/ReplayTests.swift"

# Then the three independent kit types:
Task: "Create PTY in Packages/AgentsKit/Sources/AgentsKit/Terminal/PTY.swift"
Task: "Create Scrollback in Packages/AgentsKit/Sources/AgentsKit/Terminal/Scrollback.swift"
Task: "Create ShellState in Packages/AgentsKit/Sources/AgentsKit/Model/ShellState.swift"
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1 Setup
2. Phase 2 Foundational
3. Phase 3 User Story 1
4. **Stop and validate**: quickstart scenario 1
5. This is worth shipping. Reading the agent's work beside the conversation is the whole of the spec's first claim

### Incremental delivery

1. Setup and Foundational, then the column exists and costs nothing closed
2. US1 Files, tested, shipped. MVP
3. US2 Terminal, tested, shipped. The biggest single gain and the biggest single piece of work
4. US3 Browser, tested, shipped
5. US4 Artifacts, tested, shipped. Expect an empty pane against today's runtimes, by design

### A note on US2

It is half the tasks in the feature. If it stalls, US3 and US4 do not wait on it: they need Phase 2
and nothing more. The order above is priority order, not a dependency chain.

---

## Notes

- [P] means different files and no dependency on unfinished work
- The daemon MUST NOT link SwiftTerm. It moves bytes and parses nothing (plan decision 2)
- `shell.*` is the user's shell. `terminal.*` from 003 is the agent's. Nothing crosses (FR-025)
- Commit after each task or logical group
- Stop at any checkpoint to validate a story on its own
