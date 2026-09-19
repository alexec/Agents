# Implementation Plan: Complete ACP coverage

**Branch**: `003-acp-coverage` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/003-acp-coverage/spec.md`

## Summary

001 built a client that speaks enough of the protocol to run an agent. This feature makes the client
speak all of it: everything an agent can send us, everything an agent can ask of us, and everything
a runtime advertises that the app currently cannot reach.

The work divides cleanly. Most of it is content the runtimes already send and we discard (usage,
diffs, plans, cost, non-text blocks), which is decoding plus drawing. A smaller part is us serving
the agent (files, terminals, forms), which is new surface with real consequences and goes in behind
capability flags that are turned on last. A third part is the app reaching methods it never called
(authenticate, providers, list, fork, delete), which is mostly daemon API and UI.

The research settled the one decision that mattered: Grok changes what it does when we advertise
file and terminal support, routing every read and write through us instead of doing it silently. So
serving those methods is not busywork for completeness, it is the difference between watching an
agent work and taking its word for it.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`.
Unchanged from 001.

**Primary Dependencies**: None beyond the platform. Foundation, SwiftUI, Observation, Darwin. This
feature adds no dependency: the schema is read from the published SDK during design and turned into
Swift by hand, the way the existing types were.

**Storage**: The same files under `~/Library/Application Support/Agents/`. `agent.json` grows fields
(usage, plan, folders, MCP servers, runtime account). Every new field is optional on read, so an
agent written by 001 still loads. `transcript.jsonl` gains entry kinds; an unknown kind read back is
kept and skipped rather than failing the file.

**Testing**: `swift test` in `AgentsKit`, with the fake agent extended to ask for everything a real
agent can ask for: file reads and writes, terminals, elicitation forms, plans, diffs, usage. This is
the only way most of this feature can be tested at all, because no runtime on this Mac sends an
elicitation form and only one uses the file methods. The opt-in live suite (`AGENTS_LIVE=1`) grows
one case per runtime capability, to catch the day a runtime changes its mind.

**Target Platform**: macOS 27, Apple silicon, one Mac.

**Project Type**: Desktop app plus a helper executable in its bundle. Unchanged.

**Performance Goals**: The context meter updates within 500ms of a usage notification. Terminal
output appears within 500ms of the command producing it. A diff of a 1MB file draws without stalling
the transcript.

**Constraints**: No sandbox, no new dependency, no second way to talk to a runtime. A file the app
writes for an agent must be inside that agent's folders. A terminal the app starts must not outlive
the agent, and must not outlive the daemon.

**Scale/Scope**: 52 functional requirements over 9 user stories. Every ACP method not listed in the
spec's Out of Scope section.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the Spec Kit template. No principles have been written for
this project, by the user's explicit decision, so there is nothing to check against and no violation
can be claimed.

The rules in force are the ones 001 recorded and this spec's Assumptions section adds to. The design
honours them:

| Rule in force | Where the design honours it |
|---|---|
| One person, one Mac, no accounts | Nothing here adds an account. Runtime sign-in is the runtime's own |
| The app is a window, the daemon is the owner | Files are served by the daemon, terminals are owned by the daemon, forms are answered through the daemon |
| One code path for every runtime | Every new action is gated on the advertised capability, never on the runtime's name |
| Logic where `swift test` can reach it | Serving, path checking, form shapes and content decoding are in `AgentsKit` |
| Nothing installed | No new process type. Terminals are children of the daemon |
| An option we do not understand is skipped, not guessed | Extended to content blocks, config shapes and form fields |

One rule from 001 is deliberately reversed, with the user's approval on 2026-09-18: "we decline the
client-side file and terminal capabilities". Research section 1 is the evidence.

**Re-check after Phase 1**: unchanged. The design adds no dependency, no background service, and no
second transport.

## Project Structure

### Documentation (this feature)

```text
specs/003-acp-coverage/
├── plan.md              # This file
├── spec.md              # What it does
├── research.md          # What the runtimes actually do with each capability, proved today
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── acp-client.md    # Everything we send, and everything we now answer
│   └── daemon-api.md    # What the app asks the daemon, extended
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks, not created here)
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKit/
├── JSONRPC/            # Unchanged.
├── ACP/
│   ├── ACPTypes.swift      # Grows: every method, every capability, both directions
│   ├── ContentBlock.swift  # NEW. text, image, audio, resource_link, resource
│   ├── ToolCallContent.swift # NEW. content, diff, terminal
│   ├── SessionUpdate.swift # Grows: plan_update, plan_removed, usage, compaction
│   ├── ACPSession.swift    # Grows: authenticate, providers, list, fork, delete, elicitation
│   └── Serve/              # NEW. What we do when an agent asks us for something
│       ├── FileService.swift     # fs/read_text_file, fs/write_text_file, path confinement
│       └── TerminalService.swift # terminal/create|output|wait_for_exit|release|kill
├── Runtimes/           # Grows: account state per runtime (signed in, provider, auth methods)
├── Model/              # Grows: Attachment, Usage, Plan, ElicitationRequest, ServedRequest,
│                       # RuntimeSession, MCPServer. ConfigOption decoding made lenient
├── Store/              # Grows: new agent.json fields, new transcript kinds, both optional on read
├── Daemon/             # Grows: serves the new app requests, owns terminals, holds forms
└── Client/             # Grows: the new calls and the new notifications

App/Sources/
├── Chat/               # Attachments in the composer, diffs and terminals in the transcript,
│                       # the context meter, plans, compaction
├── StartAgent/         # Boolean and grouped options, extra folders, MCP servers
├── Permission/         # Joined by Elicitation/ for structured questions
├── Runtimes/           # NEW. Sign in, sign out, provider, and what a runtime advertises
└── Sessions/           # NEW. What the runtime holds that the app does not: adopt, fork, delete
```

**Structure Decision**: unchanged from 001. Two thin shells around one library. Everything that
decides anything stays in `AgentsKit` where `swift test` reaches it, which matters more in this
feature than the last one, because most of what is being built cannot be triggered by a runtime on
this Mac and can only be exercised by the fake agent.

## Key design decisions

### 1. Capability flags go on last, and only over working code

Advertising a capability is a promise: Grok stops doing its own file IO the moment we claim we can
do it. So each served method is built and tested against the fake agent with the flag off, and the
flag is flipped in a single change at the end of that story. A half-served capability is worse than
none, because the runtime has no fallback.

### 2. Reads are recorded, writes are asked

Grok issued three reads and one write for a one-word edit. A permission question per read would make
the app unusable, and a read is not a change. So a file read is served and recorded in the
transcript; a file write goes through the same permission question a tool call goes through, with
the diff in the question. This is the spec's assumption made concrete.

### 3. A file request outside the agent's folders is refused, in the kit

Path confinement is one function in `AgentsKit`, run on every served path: resolve it, resolve every
folder the agent was given, and refuse anything that is not inside one of them, after following
symlinks. It has its own tests with the awkward cases (`..`, a symlink pointing out, a path that
does not exist yet but whose parent does). This is the one piece of this feature where a mistake
writes to the wrong place on someone's disk, so it is pure, small and tested first.

### 4. Terminals belong to the daemon and die with the agent

`terminal/create` starts a process under the daemon, keyed by a terminal id, with its output kept in
a ring buffer with a byte cap. `terminal/output` reads the buffer, `terminal/wait_for_exit` waits,
`terminal/release` and `terminal/kill` end it. Every terminal an agent owns is killed when that
agent is stopped, and the daemon kills all of them before it exits. The daemon already tracks
runtime processes this way, so this is the same pattern rather than a new one.

### 5. Content becomes blocks, in both directions

Today a message is a string. It becomes a list of blocks, which is what the protocol has always
sent, so an image in a reply draws as an image and an attachment in a prompt is the same type going
the other way. The transcript entry keeps a plain-text rendering alongside the blocks so that
existing records still read and so that search stays simple.

### 6. Tool call state is merged field by field

The audit found `rawInput` being lost when a completion update arrives. The fix is a merge that
takes each field only when the update carries it, and appends content rather than replacing it. Tool
call content arrives in pieces and the last piece is not the whole story.

### 7. Options decode leniently, and a group is a heading

One tolerant decoder handles four shapes: a flat list of choices, a list of groups, a boolean, and
something unrecognised. A group becomes its choices with a heading. An unrecognised type or a
malformed choice costs that one option. Nothing inside the options list can fail `session/new`,
which is the bug this fixes.

### 8. Usage has two homes

`used/size` drives a meter on the agent, updated live, kept on the agent record so it survives a
restart. The `usage` on a prompt response is written into the transcript against that turn, with the
cost if the runtime sent one. Cost is shown as sent, in the currency sent, with no conversion.

### 9. The runtime account is a runtime fact, not an agent fact

Whether a runtime is signed in, which provider it points at, and how to sign in belong to the
runtime, shared by every agent using it. The daemon holds that, refreshes it on a handshake, and
tells the app when it changes. Signing out asks first and names the agents it stops, because those
agents are mid-conversation.

### 10. Elicitation is the permission question grown up

A permission question is a request the agent is blocked on, held by the daemon, answerable from any
window, surviving having no window at all. An elicitation form is the same thing with a shape. It
reuses that machinery: held on a continuation in the session, mirrored in the daemon, drawn by the
app, answerable late. The form is built from the schema by a renderer that handles the described
field kinds and refuses to submit a value that does not fit.

### 11. Adopting a session makes an ordinary agent

A session from the runtime's list becomes an agent with our own UUID, the runtime's session id, the
folder it names, and the title it wrote. Its history is whatever `session/load` replays, which is the
one case where a replay is content rather than noise. An id already held by an agent is not offered.

## Risks

| Risk | What it looks like | What we do about it |
|---|---|---|
| We advertise file support and get it wrong | Grok's edits fail or land in the wrong place, and it has no fallback | Decision 1: flags last. Decision 3: confinement is pure, tested first, and refuses by default |
| A served write escapes the agent's folders | The app writes to somewhere the user did not agree to | One confinement function, symlinks resolved, its own test suite, and a write still needs permission |
| Terminals outlive their agent | Orphan processes after a stop or a daemon exit | Terminals are children of the daemon, tracked per agent, killed on stop and on exit |
| Old records stop loading | An agent from 001 disappears from the list after an upgrade | Every new field is optional on read; an unknown transcript kind is kept and skipped. A test loads a record written by 001 |
| Content-as-blocks breaks the transcript | Messages read as empty or double | The plain-text rendering is kept alongside the blocks, and coalescing is tested on records from 001 |
| Elicitation is built blind | We ship a form nobody sends, shaped wrong | Driven from the schema, tested by a fake agent, and cheap to correct because no runtime depends on it yet |
| The signed-out error is still unproved | The one thing 001 could not test is still untested | Sign a runtime out deliberately during implementation, which is the carried-over task T085 |
| This feature is large | It stalls half-built | Nine stories, each independently shippable, in priority order. P1 alone is worth shipping: it fixes a bug that can lose an agent |

## Complexity Tracking

No constitution gates exist to violate. The design adds no dependency, no background service and no
second way to talk to a runtime. The one reversal of a previous decision (serving files and
terminals) is recorded in the Constitution Check above with the evidence that prompted it and the
user's approval.
