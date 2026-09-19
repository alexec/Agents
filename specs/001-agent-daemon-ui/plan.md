# Implementation Plan: Agent daemon and basic UI

**Branch**: `001-agent-daemon-ui` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-agent-daemon-ui/spec.md`

## Summary

A Mac app and a daemon it starts. The daemon owns every agent: it launches the runtime, speaks ACP
to it over stdio, records everything it says, holds the questions it asks, and stays alive while the
window is gone. The app is a window onto the daemon and holds no state of its own.

The whole of the protocol work is one code path. Research proved all three runtimes answer the same
`initialize`, advertise their options through the same `configOptions` list, and give a session back
after their process is killed, so nothing in the design needs to know which runtime it is talking to
beyond the command used to start it and whether it answers `session/resume` or only `session/load`.

## Technical Context

**Language/Version**: Swift 6.4 (Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`)

**Primary Dependencies**: None beyond the platform. Foundation, SwiftUI, Observation, Darwin. ACP is
line-delimited JSON-RPC 2.0 over a pipe, which is a small amount of code and not worth a dependency.
The one external thing is the Claude adapter, which is an npm package the user's Node runs, not
something we link.

**Storage**: Files under `~/Library/Application Support/Agents/`, written only by the daemon. One
directory per agent: `agent.json` for the record, `transcript.jsonl` appended as things happen. No
database: one person, tens of agents, a single writer, and a format that survives being read with
`cat` when something goes wrong.

**Testing**: Swift Testing in `AgentsKit`, run by `swift test` with no Xcode and no simulator. A fake
ACP agent fixture for deterministic protocol tests. A separate opt-in suite that drives the three
real runtimes, off by default because it costs money and needs the user's credentials.

**Target Platform**: macOS 27, Apple silicon, one Mac.

**Project Type**: Desktop app plus a helper executable shipped inside its bundle.

**Performance Goals**: New agent output visible within 1s of the runtime emitting it (SC-003).
Follow-up delivered to a running agent within 2s (SC-004). Ten agents running with the list and a
transcript scrolling smoothly (SC-006).

**Constraints**: No app sandbox: the app exists to run other people's CLIs in arbitrary folders, and
a sandbox makes that impossible. Hardened runtime on, signed with Alex's team. No login item and
nothing installed (FR-019, FR-021). No third-party dependencies.

**Scale/Scope**: Tens of agents over the app's life, a handful running at once. A long agent's
transcript can reach tens of megabytes, so the transcript is streamed and windowed rather than
loaded whole.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the Spec Kit template: no principles have been written for
this project yet, by the user's explicit decision ("Not constitution yet"). There is therefore
nothing to check against, and no violation can be claimed.

The rules actually in force for this feature are the ones the spec's Assumptions section states, and
the design honours them:

| Rule in force | Where the design honours it |
|---|---|
| One person, one Mac, no accounts | No auth, no multi-user, a socket only this user can open |
| Nothing installed, nothing to maintain | Daemon is an executable inside the app bundle, started by the app, no login item |
| The app is a window, the daemon is the owner | All state lives in the daemon and on disk; the app holds none |
| One code path for every runtime | Runtimes differ only by launch recipe and one capability check |
| Logic where `swift test` can reach it | Everything that decides anything is in `AgentsKit`; the app and the daemon executable are shells |

**Re-check after Phase 1**: unchanged. No gate exists to fail, and nothing in the design adds a
dependency, a background service, or a second way to talk to a runtime.

## Project Structure

### Documentation (this feature)

```text
specs/001-agent-daemon-ui/
├── plan.md              # This file
├── spec.md              # What it does
├── research.md          # What the three runtimes actually do, proved by handshake
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── acp-client.md    # What we send the runtimes, and what we must answer
│   └── daemon-api.md    # What the app asks the daemon
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks, not created here)
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKit/
├── JSONRPC/            # Line-delimited JSON-RPC 2.0: framing, correlation, notifications.
│                       # One implementation serves both the ACP side and the app side.
├── ACP/                # The protocol types and the client: initialize, session/new,
│                       # session/prompt, session/load, session/resume, session/cancel,
│                       # session/close, the session/update stream, and the two requests we
│                       # must answer (permission, and anything we decline).
├── Runtimes/           # The catalogue of launch recipes, discovery on this Mac, and the
│                       # login-shell PATH problem.
├── Model/              # Agent, AgentState, TranscriptEntry, StartOptions, PermissionRequest.
│                       # No IO, no processes: the part that is pure and cheap to test.
├── Store/              # The on-disk record. Single writer, atomic record writes, appended
│                       # transcripts, recovery on start.
├── Daemon/             # The core: owns AgentSession actors, serves the app, decides when to
│                       # exit, marks dead agents stopped on start.
└── Client/             # What the app uses to talk to the daemon, including starting it.

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/               # State machine, store, codec, options-to-form.
├── Fake/               # FakeACPAgent: a deterministic ACP-speaking fixture.
├── Integration/        # Daemon plus fake agents: survival, resume, permissions, exit rule.
└── Live/               # Opt-in, AGENTS_LIVE=1: the three real runtimes.

App/Sources/            # SwiftUI. Views and view state only; no protocol, no processes.
├── AgentsApp.swift
├── AgentList/
├── Transcript/
├── StartAgent/         # The form built from configOptions
└── Permission/

Daemon/Sources/
└── main.swift          # Twenty lines: parse the socket path, hand off to AgentsKit's Daemon.
```

**Structure Decision**: Two shells around one library. `AgentsKit` holds everything that decides
anything and is tested with `swift test`; `Agents` (the app) and `agentsd` (the helper) are thin
executables. The helper is built as an Xcode target of type `tool` and embedded in the app bundle
under `Contents/Helpers/agentsd`, so there is one thing to build, one thing to sign, and nothing for
the user to install.

## Key design decisions

### 1. The daemon is a helper in the bundle, started by the app

The app looks for a live daemon; if there is none it spawns `Contents/Helpers/agentsd` in a new
session (`posix_spawn` with `POSIX_SPAWN_SETSID`) so the helper is not in the app's process group and
does not die with it. Agents are children of the daemon, not of the app, which is what makes FR-001
true.

One daemon is enforced by an exclusive `flock` on `daemon.lock`. A second daemon that loses the lock
exits without touching anything and its caller connects to the socket instead. This is a file lock
rather than a port or a named service because the lock dies with the process, so a crashed daemon
leaves nothing to clean up.

Rejected: a launchd agent (it is a login item by another name, against FR-019 and FR-021), and an
XPC service (dies with the app that hosts it, which is the opposite of the requirement).

### 2. One JSON-RPC implementation, used twice

ACP is line-delimited JSON-RPC 2.0 over stdio. The app-to-daemon protocol is the same thing over a
Unix socket at `~/Library/Application Support/Agents/daemon.sock`. Writing one `JSONRPCConnection`
that speaks both means the framing, the request correlation, the cancellation and the notification
fan-out are written once and tested once.

Rejected: a Codable-over-socket scheme of our own, which would need its own framing and its own
tests to do what the ACP code already has to do.

### 3. The window is a view, not a copy

The app holds no agent state. It subscribes and renders what the daemon sends: the state of each
agent, appended transcript entries, permission questions, and option changes. Everything the user
does is a request to the daemon. This is what makes two windows agree (FR-016) and makes the
reconnect after a crash boring: connect, ask for the list, subscribe, done.

### 4. A finished agent's process is let go

Research proved all three runtimes hand a session back after their process has been killed, so
holding one open for an idle agent buys nothing. A turn ending in `end_turn` closes the session and
releases the process; the next follow-up starts the runtime again, resumes the session and prompts.
That is what lets the daemon honour its own exit rule (FR-019) instead of accumulating processes.

The cost is a second or two before a follow-up to a finished agent starts moving, and for the Claude
adapter more than that when npm has to fetch. The app says the runtime is starting rather than
looking frozen. Keeping a process warm for a short while is an optimisation this feature does not
need and would be free to add later.

### 5. Resume before load

`session/resume` restores without replaying; `session/load` replays the whole conversation. We keep
our own transcript, so replay is noise we would have to discard. Resume where the runtime advertises
it, load where it does not, and treat load's replayed updates as confirmation rather than as
content. Copilot needs load; Grok and the Claude adapter take resume.

### 6. The agent's identity is ours, the session's is theirs

`session/new` has no field for a client-supplied id and all three runtimes ignore one offered, so the
agent carries our UUID and the runtime's session id is recorded against it and replaced whenever a
new runtime session is started for the same agent (FR-012ca, FR-012cb).

### 7. Options are data, not code

The start form is generated from the `configOptions` the session advertises: each has an `id`, a
`name`, a `category`, a `type` and its choices. The form renders by `type`, orders by `category`, and
knows nothing about models or modes. An option `type` we do not recognise is skipped rather than
guessed at, and a runtime that advertises nothing still starts.

There is a chicken and egg here worth naming: options are advertised by `session/new`, which means a
session exists before the user has chosen anything. So starting an agent is two steps inside the
daemon — create the session, show its options, apply the user's choices with the set-option call,
then send the first prompt. The user sees one dialog.

### 8. We decline the client-side file and terminal capabilities

The protocol lets a client offer file reading, file writing and a terminal for the agent to use. We
advertise none of them in v1, so each runtime uses its own tools, which is what they do on their own
anyway. This removes a whole surface (sandboxing someone else's file writes through our process)
from the first feature. It is a capability flag, so turning it on later changes one struct.

### 9. PATH is the first thing that will break

None of the three runtimes is on the PATH a GUI app inherits from launchd. On this Mac they are at
`~/.local/bin/claude`, `~/.grok/bin/grok` and `/opt/homebrew/bin/copilot`, and `npx` is in Homebrew
too. Discovery therefore resolves each recipe against the user's login-shell PATH, read once by
running their shell as a login shell, and falls back to a short list of usual places. A runtime that
cannot be resolved is listed as not found with where we looked, which is FR-003 doing its job rather
than a silent empty list.

### 10. Starting an agent is a pane, not a dialog, and the controls are glass

The right-hand side shows the start form when no agent is chosen, so the app opens ready to start
one. Three rows: where it works and what runs it, what you want done, and the options that runtime
offers.

The option controls carry their own name only when their choices do not say what they are. "GPT-5.6
Terra" needs no label; "Agent" and "Off" do, and the Claude adapter calls both its model and its
effort level "Default", so a name that turns up twice in a row gets its label back. That rule is in
`AgentsKit`, not in a view, because it is a decision and decisions are tested.

Liquid Glass is used where there are controls: the prompt box, the folder and runtime buttons, the
option capsules, the composer and the permission banner. Not on the transcript, which is content.
The minimum is macOS 27, so nothing is gated.

There is no free-text argument field. A box of flags nobody validates is a way to fail at launch
with a typo, and all three runtimes advertise what they can be told.

## Risks

| Risk | What it looks like | What we do about it |
|---|---|---|
| The GUI PATH problem | The app finds no runtimes although the terminal has all three | Decision 9. It is the first integration test written |
| npx cold start | Starting a Claude agent takes many seconds the first time | Show the runtime starting; it is a state, not a freeze |
| Detecting "installed but not signed in" | The auth-required error is not documented, and Copilot advertises `authMethods` while perfectly signed in, so the presence of auth methods proves nothing | Treat a failed `session/new` as not ready, show the runtime's own auth methods and the command it names. Pin the actual error down against a logged-out runtime during implementation rather than guessing now |
| A huge transcript | The window stalls on an agent that has been running for hours | The transcript is appended on disk and windowed in the UI; the app asks for a range, never the whole thing |
| The daemon dies mid-turn | In-flight work is lost and the record disagrees with reality | Entries are appended as they arrive, not at turn end. On start the daemon marks every agent whose process is gone as stopped (FR-019b) |
| Killing a runtime that persists its own sessions | A runtime left in a state it cannot recover | Cancel, close the session, then terminate, and only kill if that does not work (FR-011b) |

## Complexity Tracking

No constitution gates exist to violate, and the design adds no dependency, no background service and
no second way to talk to a runtime. Nothing to justify.
