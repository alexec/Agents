# Implementation Plan: The right sidebar

**Branch**: `002-right-sidebar` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/002-right-sidebar/spec.md`

## Summary

001 built a window where you talk to an agent and read what it says it did. This feature adds a
column on the right where you look at what it actually did: its folder, its files, a shell of your
own in that folder, a browser for what it served, and a list of what it handed over.

The four panes are not equally hard. The files pane and the artifacts pane are readers over things
that already exist: the folder on disk, and the transcript the daemon already keeps. The browser is
a `WKWebView` with its delegates set to refuse. The terminal is the feature. It needs a pty, it
needs a shell that outlives the window, and it needs enough of a terminal emulator that `vim` draws
correctly, which this project writes rather than takes.

The research settled the one question the spec left open, and the answer narrows the feature rather
than widening it. An artifact is only what a runtime deliberately hands over, so the artifacts pane
is a filter over the transcript with no crawler behind it. It will be empty against every runtime on
this Mac until one starts sending `resource_link`, and it ships that way on purpose.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`.
Unchanged from 001.

**Primary Dependencies**: None beyond the platform. Foundation, SwiftUI, Observation, Darwin, and
now WebKit and CoreServices, both of which are Apple's and already on the machine. This feature adds
no third-party dependency. The terminal emulator that would justify one is written here instead, for
the reasons in research section 3.

**Storage**: The same files under `~/Library/Application Support/Agents/`. This feature writes no new
agent state: a shell is a live thing that dies with the daemon, and an artifact is read back out of
the `transcript.jsonl` that is already written. The only thing persisted is the sidebar's frame, in
`UserDefaults`, which belongs to the window.

**Testing**: `swift test` in `AgentsKit`. The pieces that decide anything are pure and go there: the
VT parser, the text-or-binary check, the path and directory reading, the artifact filter, the idle
rule for shells. The VT parser is tested against recorded byte streams captured from real `vim`,
`htop` and `less` sessions on this Mac, checked in as fixtures, so the test is what those programs
actually emit rather than what the spec says they should.

**Target Platform**: macOS 27, Apple silicon, one Mac.

**Project Type**: Desktop app plus a helper executable in its bundle. Unchanged.

**Performance Goals**: A shell ready to type into within 2 seconds of the pane opening (SC-003). A
changed file redrawn within 2 seconds of the write landing (SC-002). The VT parser keeps up with a
build that prints as fast as `xcodebuild` prints, without the pane falling behind.

**Constraints**: No sandbox, no third-party dependency, no second way to talk to the daemon. The
sidebar closed leaves 001 exactly as it was (FR-006, SC-009). Nothing the user types in the terminal
reaches the agent (FR-025).

**Scale/Scope**: 4 user stories, 34 functional requirements, 10 success criteria. Four panes, of
which one is most of the work.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the Spec Kit template. No principles have been written for
this project, by the user's explicit decision, so there is nothing to check against and no violation
can be claimed.

The rules in force are the ones 001 recorded and 003 reaffirmed. The design honours them:

| Rule in force | Where the design honours it |
|---|---|
| One person, one Mac, no accounts | Nothing here adds an account. The shell runs as the user, with the access the user has |
| The app is a window, the daemon is the owner | Shells are owned by the daemon and outlive windows. Sidebar frame state is the window's and stays there |
| One code path for every runtime | Nothing in this feature branches on a runtime's name. The artifacts pane reads blocks, not vendors |
| Logic where `swift test` can reach it | The VT parser, the binary check, the directory reader, the artifact filter and the idle rule are all in `AgentsKit` |
| Nothing installed | No new process type. Shells are children of the daemon, which is already in the bundle |
| No third-party dependencies | Held, at a real cost. Research section 3 records what it cost and what would reverse it |
| An option we do not understand is skipped, not guessed | Extended to escape sequences: one we do not know is consumed and dropped, never printed |

**Re-check after Phase 1**: unchanged. The design adds two Apple frameworks, no dependency, no
background service, and no second transport. The one rule under strain is no-dependencies, and it is
recorded above rather than quietly bent.

## Project Structure

### Documentation (this feature)

```text
specs/002-right-sidebar/
├── plan.md              # This file
├── spec.md              # What it does
├── research.md          # Phase 0. The pty proved, the emulator decided, FR-046 answered
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── daemon-api.md    # shell/*, and the notifications a sidebar listens to
│   └── panes.md         # What each pane is given and what it may do
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks, not created here)
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKit/
├── Terminal/               # NEW. The half of a terminal that has no UI
│   ├── PTY.swift               # openpty + posix_spawn(SETSID), read, write, resize, signal
│   ├── VTParser.swift          # Bytes to actions. UTF-8 across chunks, CSI, OSC, SGR
│   ├── Screen.swift            # Grid, cursor, scroll region, alternate buffer, attributes
│   ├── Scrollback.swift        # Ring buffer with a byte cap, and the tail on attach
│   └── ShellSession.swift      # One shell: its pty, its screen, its idle clock
├── Files/                  # NEW. The half of a file browser that has no UI
│   ├── DirectoryReader.swift   # One level, lazily, sorted, with a cap
│   ├── FileProbe.swift         # Text or binary, what kind, how big, from the first chunk
│   └── FolderWatch.swift       # FSEvents on a folder, coalesced, directory-level
├── Model/
│   ├── Artifact.swift          # NEW. A resource_link or resource, with where it came from
│   └── ShellState.swift        # NEW. live, exited(status), released(reason), failed(reason)
├── ACP/
│   └── ContentBlock.swift      # Grows: annotations on resource_link and resource
├── Daemon/
│   ├── ShellHost.swift         # NEW. The daemon's shells, keyed by agent. Attach, detach, reap
│   └── DaemonCore+Shells.swift # NEW. Serving shell/* and pushing shell/output
└── Client/
    └── DaemonClient.swift      # Grows: the shell calls and the shell notifications

App/Sources/
└── Sidebar/                # NEW. The column and its four panes
    ├── SidebarView.swift       # The column, the pane picker, the width, the empty state
    ├── SidebarState.swift      # Frame state in UserDefaults; per-agent pane state in memory
    ├── FilesPane.swift         # The folder, the file, the marks for what the agent touched
    ├── TerminalPane.swift      # Draws a Screen, sends keys, sends its size
    ├── TerminalView.swift      # NSViewRepresentable: the grid, the font, the selection
    ├── BrowserPane.swift       # WKWebView, its delegates, back/forward/reload, the error
    └── ArtifactsPane.swift     # The list, the empty state, and the jump to the message
```

**Structure Decision**: unchanged from 001 and 003. Two thin shells around one library. This feature
leans on it harder than either: a terminal emulator is the clearest case there has been of logic that
must be testable without launching an app, and `App/Sources/Sidebar/` is deliberately thin, four
panes that draw things the kit computed.

## Key design decisions

### 1. The terminal is two halves, and only one of them is a view

`ShellSession` in the kit owns the pty, feeds bytes to `VTParser`, and keeps a `Screen`. It has no
idea a window exists. `TerminalView` in the app draws a `Screen` and sends keys back. The whole of
the difficult part, the parser and the grid, is reachable by `swift test` with no app and no pty: you
hand it bytes and read the grid. The fixtures are real captures from `vim`, `htop` and `less`, so the
test asserts against what those programs emit rather than what the standard says.

### 2. The daemon owns the shell, so the build survives the window

`shell/attach` gives a window the current screen and the tail of the scrollback, and subscribes it to
output. `shell/detach` unsubscribes. Neither starts nor stops anything. A shell is started by the
first attach for an agent and ends when it exits, when it is killed, or when it is reaped for being
idle. Quitting the app detaches every window and kills nothing, which is FR-026 and SC-010. Two
windows attach to the same shell and both get the output, which is FR-023.

### 3. The user's shell and the agent's terminals are different things with different names

003 gives agents terminals, served on `terminal/*` and pushed as `agent/terminalOutput`. This feature
gives the user shells, served on `shell/*` and pushed as `shell/output`. They share `PTY.swift` and
nothing else: different owners, different identifier spaces, different lifetimes. FR-025 is a
requirement that these never meet, and separate names are how it stays true by construction rather
than by care.

### 4. Idle is a rule, not a timer scattered through the code

A shell is idle when no child of it is running and nothing has been typed for a while. That is a pure
function of three inputs, so it lives in `ShellSession` as one, and the daemon asks it on a tick. A
shell that is busy is work the daemon is holding, and the existing lifetime rule already knows how to
count that (FR-027). A reaped shell becomes `.released(reason)` and the pane says so rather than
drawing a dead screen (FR-028).

### 5. What changed comes from the transcript, not from a crawl

FR-013 asks which files changed since the agent started. The answer is already written down: every
tool call carries `locations`, and every edit carries a `diff` with a path. The files pane reads the
agent's own transcript for that set. No baseline snapshot, no walking the tree, and a truthful answer:
it marks what the agent did, not what happened in the folder. A file the user edited themselves is
not marked, which is right.

### 6. An artifact is what the runtime marked, and the empty state does the work

Settled in research section 1, by the user. The pane filters the transcript for `resource_link` and
embedded `resource` blocks, newest first. No runtime sends these today, so the pane's ordinary state
is empty, and FR-043's empty state is the screen people will actually see. It is written as a
statement about what will appear there, in the app's own voice, not as an apology. The filter is a
pure function over transcript entries and is tested with blocks the fake agent sends.

### 7. The browser refuses by default

A page may not open a window, may not navigate to a scheme outside http, https, about and file, may
not download, and must ask before it reaches the camera or the microphone. Each is a delegate method
that returns the refusing answer, written that way round so that a method nobody thought about still
refuses. The app is not sandboxed, so these delegates are the only gate there is, and they have their
own tests.

### 8. The sidebar closed is 001 exactly

FR-006 and SC-009 are a promise that this feature costs nothing when it is not used. The sidebar is
a sibling of the conversation in the window's layout, and when it is closed nothing of it runs: no
FSEvents stream, no web view, no attach. A shell already running stays running in the daemon, because
it belongs to the agent rather than to the pane, but the window is not listening to it.

### 9. Panes take turns, and the state of each is kept

One column, four panes, one visible (the spec's assumption). Switching panes does not tear the hidden
one down: the browser keeps its page, the terminal stays attached, the files pane keeps its folder.
Switching agents does tear down what is per-agent and rebuild it from that agent's kept state, which
is FR-005 and SC-005.

## Risks

| Risk | What it looks like | What we do about it |
|---|---|---|
| The VT parser is a bigger job than it looks | The feature stalls on `vim` drawing wrong, and the other three panes wait behind it | It is built and tested from real captured streams before any pane draws it, and the grid model is the same shape SwiftTerm has, so adopting it later is a view change rather than a rewrite. Research 3 records the reversal and what would trigger it |
| A shell leaks or outlives the daemon | Orphan shells after a quit, or a machine with twenty ptys open | Shells are children of the daemon and die with it. The daemon kills every shell before it exits, and the idle rule reaps the rest. FR-029 marks one killed by a restart as gone, with the reason |
| The empty artifacts pane reads as broken | The user opens it, sees nothing, and concludes the feature does not work | The empty state says plainly that agents have not started handing things over yet. This was the known cost of the FR-046 answer and it is accepted on the record |
| A page in the browser reaches the Mac | An unsandboxed web view downloads something or opens a window | Delegates are written to refuse first. Every capability is an explicit allow, and the refusals are tested |
| `posix_spawn` with SETSID behaves differently under the daemon | Works in a test binary, fails as a child of `agentsd` | Proved today in a standalone binary; the first task under the terminal story proves it again inside the daemon before anything is drawn |
| Watching a huge folder floods the app | An agent running a build in a repo with `node_modules` makes the pane unusable | FSEvents is directory-level and coalesced, the pane re-reads only the directory it is showing, and the tree is never walked |
| The sidebar slows the conversation | 001's window becomes worse for a feature the user is not using | FR-006 is a test, not an aspiration: with the sidebar closed nothing of it is running, and SC-009 is checked in the quickstart |

## Complexity Tracking

No constitution gates exist to violate. The design adds no third-party dependency, no background
service and no second way to talk to the daemon.

One rule is under real strain and is recorded rather than bent: no-dependencies costs this feature a
hand-written terminal emulator, which is the single largest piece of work in it. Research section 3
sets out what was weighed, what it buys, and the conditions under which the user would be asked to
reverse it. Nothing else here is more complicated than it needs to be.
