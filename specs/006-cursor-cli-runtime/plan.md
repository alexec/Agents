# Implementation Plan: Cursor makes four

**Branch**: `006-cursor-cli-runtime` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/006-cursor-cli-runtime/spec.md`

## Summary

Add Cursor to the list of runtimes the app can start, and answer the one question the spec could not:
what Cursor sends that the protocol does not define, and whether the app survives it.

The research answers both, by running Cursor rather than by reading about it. Putting Cursor on the
list is one entry in `RuntimeCatalog` and one test that counts to four, because nothing in this
codebase branches on a runtime's name. The interesting half is smaller than the spec feared and
different in shape.

Cursor sends `cursor/create_plan` as a blocking request. The app already declines a method it does
not know with `-32601`, deliberately and loudly, and a turn answered that way runs to `end_turn`. A
turn where the request is left unanswered did not finish. So the app's existing behaviour is not
merely adequate here, it is the thing keeping the turn alive, and User Story 3's first scenario is
already true. Better still, Cursor sends the same plan again through the protocol's own
`session/update` channel, so declining its private request costs the user nothing at all.

That leaves one real defect, and it is not Cursor's. An inbound **notification** whose method the app
does not recognise is dropped at `ACPSession.swift:398` without a log, an event or a record. Only
unknown kinds *inside* `session/update` are reported. Cursor's `cursor/update_todos`, `cursor/task`
and `cursor/generate_image` would vanish there, and FR-012 says nothing may be dropped silently. The
fix is four lines and belongs to every runtime, not to Cursor.

So the feature is: one catalog entry, one honest fix to unknown notifications, two tests that assume
three runtimes and must be taught about a fourth, and one live test that will fail for Cursor on a
capability it does not advertise. No `cursor/` handler is built, because building one would be this
codebase's first branch on a runtime's identity and the evidence says it buys nothing.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`.
Unchanged from 001 and 003.

**Primary Dependencies**: None, and none added. Cursor is a command on the user's path, started the
way Grok and Copilot are. Unlike Claude it needs no npm adapter: `cursor-agent acp` speaks the
protocol itself.

**Storage**: Unchanged. No new field on `agent.json`, no new transcript kind. `Agent.runtimeID` is a
plain string and has always been able to hold `"cursor"`.

**Testing**: `swift test` in `AgentsKit`. The unknown-notification fix is driven by the fake agent,
which can send a method nobody knows. The live suite (`AGENTS_LIVE=1`) is parameterised over
`RuntimeCatalog.builtIn` and so picks Cursor up by itself, which is how the `configOptions`
assertion below was found before it broke.

**Target Platform**: macOS 27, Apple silicon, one Mac. `cursor-agent` 2026.09.10-fd3934a at
`~/.local/bin/cursor-agent`.

**Project Type**: Desktop app plus a helper executable in its bundle. Unchanged.

**Performance Goals**: None specific. Adding a runtime adds one more `isExecutableFile` check to
drawing the runtime list, which is why `locate` never starts a process.

**Constraints**: No code path may branch on a runtime's identity. This is the constraint that shapes
the whole feature and it is recorded in the live tests themselves
(`LiveRuntimeTests.swift:18-19`). Everything Cursor does must be handled as something *any* runtime
might do, or not handled at all.

**Scale/Scope**: 19 functional requirements over 3 user stories. One new catalog entry, one behaviour
fix in `ACPSession`, three test files, one shell script.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the Spec Kit template. No principles have been written for
this project, by the user's explicit decision, so there is nothing to check against and no violation
can be claimed. The rules in force are the ones 001 and 003 recorded.

| Rule in force | Where the design honours it |
|---|---|
| One code path for every runtime | No `cursor/` handler is built. The one fix is to unknown notifications from any runtime |
| An option we do not understand is skipped, not guessed | Cursor's models and modes arrive in a place the app does not read, and the design leaves it that way |
| A method we do not know is declined loudly, not left to time out | Kept, and now with evidence that it is what keeps a Cursor turn alive |
| The app is a window, the daemon is the owner | Unchanged. Nothing here touches ownership |
| Logic where `swift test` can reach it | The notification fix is in `AgentsKit` and is driven by the fake agent |
| Nothing installed | Cursor is the user's own command. The app installs nothing and does not offer to |

**Re-check after Phase 1**: unchanged. The design adds no dependency, no per-runtime branch, no new
transport and no new stored field. It removes a silent drop.

## Project Structure

### Documentation (this feature)

```text
specs/006-cursor-cli-runtime/
├── plan.md              # This file
├── spec.md              # What it does
├── research.md          # What Cursor actually does, proved by running it
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── acp-client.md    # What changes in what we answer and what we record
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks, not created here)
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKit/
├── Runtimes/
│   └── RuntimeCatalog.swift    # Grows by one entry: cursor, `cursor-agent acp`
└── ACP/
    └── ACPSession.swift        # `receive` stops dropping a notification it does not know

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/RuntimeDiscoveryTests.swift  # Counts to four; gains a Cursor recipe case
├── Integration/ACPSessionTests.swift # An unknown notification is reported, not dropped
├── Live/LiveRuntimeTests.swift       # The configOptions assertion learns that not every runtime has them
└── Fake/FakeACPAgent.swift           # Can send a notification nobody knows

scripts/
└── acp-handshake.sh            # The by-hand probe learns the fourth recipe
```

**Structure Decision**: unchanged from 001. Two thin shells around one library. This feature touches
four source files and one script, which is the point: the catalog was built to make a fourth runtime
cheap, and the research confirms it is.

## Key design decisions

### 1. Cursor is `cursor-agent acp`, never `agent acp`

Cursor's own documentation and its own auth description both call the command `agent`. On this Mac
`agent` is `/Users/alexcollins/.grok/bin/agent`, which is Grok. The catalog entry names
`cursor-agent`, and FR-005a forbids passing Cursor's description through to the user as an
instruction. A runtime knows its own name; it does not know what else is on your path.

`acp` does not appear in `cursor-agent --help`. It exists, it is documented on the web, and
`cursor-agent acp --help` describes it. Research section 1 records the version this was true for.

### 2. No `cursor/` handler, because declining one costs nothing

This is the decision the whole feature turns on, and the evidence is in research section 3.

`cursor/create_plan` is a blocking request. Answered with `-32601` the turn ran to `end_turn`. Left
unanswered it did not finish. And the plan Cursor asked to show privately arrives anyway as a normal
`session/update` with `sessionUpdate: "plan"`, which the app already draws, because 003 built that.

So the app's existing behaviour is correct, complete and already tested
(`ServingTests.swift:175`). Writing a `cursor/create_plan` handler would duplicate a plan the app
already has, and it would be the first code in this repository to care which runtime it is talking
to. The rule against that is not decoration. It is written into the live test itself, above the case
that runs over every runtime:

> Nothing below names a runtime except as data. One code path, three runtimes: if this test needs an
> `if` on the id, the claim in SC-009 is no longer true.

That comment becomes "four runtimes" in this feature, and the claim it guards is exactly what a
`cursor/` handler would break.

The same reasoning covers `cursor/ask_question`, with one honest caveat in decision 5.

### 3. The real bug: a notification nobody knows is dropped silently

`ACPSession.receive` handles `elicitation/complete`, then:

```swift
guard method == ACP.ClientMethod.sessionUpdate, let update = params?["update"] else { return }
```

Any other notification method returns on that line. No log, no event, nothing. Inside
`session/update` an unknown kind becomes `.unknownUpdate(kind)` and reaches the daemon log, so the
app is careful about one half of this and blind to the other.

Cursor's three notifications would land there. So would anything a runtime adds next year. The fix
is to treat an unrecognised *method* the way an unrecognised *update kind* is already treated: yield
an event, let the daemon write one log line, lose nothing. It is four lines, it mentions no runtime,
and it is what FR-012 actually asks for.

### 4. Cursor advertises no `configOptions`, and a live test assumes everyone does

`LiveRuntimeTests.swift` is parameterised over `RuntimeCatalog.builtIn` and asserts a non-empty
`configOptions` with a `model` category. Cursor sends neither. It sends `models` and `modes` on
`session/new`, which `ACPTypes.swift:247` deliberately does not decode, because those are
inconsistent between runtimes and are being retired from the protocol.

So the fourth runtime makes an existing test fail on the day it is added. The assertion is wrong
rather than the runtime: "every runtime offers options" was true of three runtimes by accident. It
becomes "a runtime that advertises options offers usable ones", which is the same rule the rest of
the codebase follows.

This is deliberately not an excuse to start reading `models`. Doing that is a decision for all four
runtimes and the spec puts it out of scope.

### 5. What is still not proved, and what to do about it

`cursor/ask_question` did not fire in either probe. Two turns, one designed to force a question out
of it, and it never asked. So the spec's claim that Cursor asks blocking questions is documented but
unobserved, and the plan does not build for it.

If it does appear during implementation, the landing place already exists and is runtime-agnostic:
003 built the whole elicitation stack, T116 to T123, all done, from `ElicitationRequest` through the
daemon's `holdElicitation` to `ElicitationView`. A question from any runtime that carries a prompt
and a list of answers can be turned into an `ElicitationRequest` without naming the runtime it came
from. That is the shape to reach for. It is not work this feature commits to, because nothing has
yet shown it is needed.

### 6. Signing out is not offered, because Cursor does not offer it

Cursor advertises `cursor_login` and no logout, so `RuntimeAccount.canLogOut` is false and the
sign-out control is already hidden. Nothing to build; it is here because FR-005b says so and someone
will otherwise wonder where it went.

### 7. T076 is not closed by this feature

003's open task, what a signed-out runtime actually returns, needs a real account signed out and
back in. 003 already decided the mapping (`-32000` means needs signing in). Proving it means
signing the user out of Cursor, which is the user's call and not a step on the way to somewhere
else. Recorded in the spec's Dependencies and left there.

## Complexity Tracking

No constitution violations to justify. The one thing worth recording is a violation deliberately
*avoided*:

| Tempting | Why it was rejected |
|---|---|
| A `cursor/create_plan` handler | Would be the first branch on runtime identity in the codebase, and the plan already arrives through `session/update`. Declining costs nothing |
| Reading Cursor's `models` so the app can show one | `session/new` models are undecoded on purpose for all runtimes. Changing that is a four-runtime decision, out of scope here |
| Loosening the live `configOptions` assertion for Cursor only | The assertion is wrong for everyone. It is fixed for everyone |
