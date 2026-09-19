# Implementation Plan: A Restarted Background Service Picks Up the Chats That Were Working

**Branch**: `011-restart-running-chats` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/011-restart-running-chats/spec.md`

## Summary

Most of this feature already exists. `DaemonCore+Recovery.swift` marks every chat the record
called live as stopped with `daemonGone` before the socket opens, then picks each one back up
after it by sending the ordinary `prompt` — which already knows how to start a runtime, continue
the conversation and begin a turn. The words it sends explain the restart, and differ for a chat
that was holding a question open. That covers Story 1, Story 2's honesty about the interruption,
Story 3's failure path, and the one-at-a-time rule.

What is left is four things the existing code does not do, and one it does slightly wrong:

- **Nothing stops a loop.** A chat whose own work brings the daemon down is picked back up every
  single time the daemon starts, forever, spending real money each round (FR-016, FR-017). This
  is the only genuinely new mechanism in the feature: a small persisted count on the record,
  incremented when the restart words are sent and cleared by any turn that reaches its own end.
- **A chat with words already queued is abandoned.** `pickUp` guards on
  `agent.queuedPrompts.isEmpty`, meaning to say "somebody has already spoken to it". A prompt
  queued *before* the crash trips the same guard, so that chat is never picked back up at all
  (FR-020). The guard is replaced by one that actually means what it says, and the restart words
  go to the *front* of the queue: they are about the interruption, and must be read before words
  the person typed believing the turn was still running.
- **A window cannot see a chat coming back.** Between `recover()` and the prompt landing, a chat
  reads as plainly "Stopped" with an ending of "Stopped with the daemon" — which is true of the
  moment and misleading about the next one (FR-018). The daemon knows better: it has `resuming`.
  That set is broadcast, exactly as `showFile` is, and the app derives a row from it.
- **Stopping a returning chat does not stop it.** `stop()` finds no live runtime and no
  `holdsRuntime` state, so it does nothing, and the resume loop starts the chat a moment later
  (FR-021). `stop()` learns to withdraw a chat from the queue of ones still to be picked up.
- **The order is whatever the dictionary felt like.** `recover()` iterates `agents`, a Swift
  `Dictionary`, and the comment in `pickUpEachInTurn` says "in the order they were found" as
  though that meant something. Sorted by last activity, so the chat the person most recently left
  running is the first one back.

Two requirements need no code. FR-019 (spending limits) is inherited for free: picking a chat back
up *is* a prompt, so whatever gate `010-cost-limits` puts in `prompt` applies to it, and the
existing failure path already writes the refusal into the chat and drops the words. FR-011's
exclusion of chats whose process died while the daemon watched is already true, because that
ending is recorded as `processDied` and only `daemonGone` is eligible.

### The seams

| Seam | What it already does | What this feature adds |
|---|---|---|
| `DaemonCore.recover()` | Reads the record, marks live-looking chats stopped, remembers what each was doing in `interrupted` | Returns them in a deliberate order; skips chats already at the pick-up limit |
| `DaemonCore.pickUp(_:)` | Sends the restart words through `prompt` | Counts the attempt, puts the words first, stops guarding on the queue |
| `DaemonCore.move(_:on:)` | The one funnel every state transition passes through | Clears the pick-up count when a turn reaches its own end |
| `DaemonCore.stop(_:)` | Cancels the turn, the permission, the runtime | Withdraws the chat from `resuming`/`interrupted` |
| `BroadcastBox` + `AgentsModel.apply` | Carries transient per-chat facts the record does not hold (`filesToShow`) | Carries `resuming` the same way |

## Technical Context

**Language/Version**: Swift 6.2, strict concurrency

**Primary Dependencies**: Foundation, SwiftUI (app and Remote). No new third-party dependency.

**Storage**: The existing per-agent JSON record under the daemon's root, through `AgentStore`. One
new field on `Agent`. `Agent` already round-trips unknown keys, so an older build reading a record
written by this one does not delete the count.

**Testing**: Swift Testing (`import Testing`) in `Packages/AgentsKit/Tests/AgentsKitTests`, split
`Unit` / `Integration` / `Live` / `Fake`. Recovery is already driven end to end in
`Integration/DaemonTests.swift` through the injectable `SessionLauncher` and a temporary root, with
no CLI, credential or network. Every scenario in this feature is reachable that way.

**Target Platform**: macOS 27+ for the app and daemon. `AgentsKitCore` also builds for iOS 27+ and
must stay free of `Process`, `posix_spawn` and PTY — the new model field and the new notification
type go there, the recovery logic stays in `AgentsKit`.

**Project Type**: Desktop app plus a long-lived local daemon, talking JSON-RPC over a unix socket,
with an iOS remote reading the same model types.

**Performance Goals**: Every eligible chat is working again or carrying its explanation within one
minute of the daemon starting (SC-001). Ten returning chats leave the machine usable and the app
responsive throughout (SC-005), which the existing one-at-a-time rule already delivers.

**Constraints**: Nothing may be picked back up before the socket is open, or a window would connect
to find it over. Nothing may be marked live before the socket is open, or a window would see a
state already known to be untrue. The daemon must not exit for idleness while chats are on their
way up. The restart words describe this minute and must never be delivered later than it.

**Scale/Scope**: Tens of chats on the record, of which the handful that were mid-turn are
candidates. One daemon per machine.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unmodified template — every principle is an unfilled
`[PRINCIPLE_N_NAME]` placeholder. There are no project principles to check against, so the gate
passes vacuously in both directions. It is recorded here rather than silently skipped so that a
later `/speckit-constitution` knows this feature was never measured against one.

In its place, the design was held to the conventions the codebase enforces in practice:

| Convention | How this feature holds to it |
|---|---|
| The daemon owns state; windows are views of it | The decision to pick a chat back up, the count that bounds it, and the order are all `DaemonCore`'s. The app renders a broadcast fact and decides nothing. |
| The record is written before the windows are told | The pick-up count is saved before the words are sent, so a daemon killed mid-pick-up comes back knowing it already tried. |
| A derived or transient fact must not become a state | `resuming` is broadcast and held client-side, following `filesToShow`/`wantsEyes`, whose own comment says it "is not a state and must never become one". No new `AgentState` case; the transition table is untouched. |
| Agents are told the truth, in sentences | The words about a restart, and about a pick-up that was refused or abandoned, are plain-language lines in the transcript, in the app's own bracketed voice. |
| `AgentsKitCore` is what both platforms can hold | The `Agent` field, the notification type and the method name go in Core; recovery stays in `AgentsKit`; both the window and the Remote read the same fact. |
| Nothing is a special kind of start | Picking a chat back up remains an ordinary prompt. That is what makes FR-019 free and what keeps the runtime, session and option handling in one place. |

**Post-design re-check**: passes. No new package, process, transport or state. One field is added to
a persisted model that already tolerates unknown keys; one notification and one list method are
added alongside their exact precedents; the one change to existing behaviour — `stop()` cancelling
a pending pick-up — makes the person's own decision authoritative, which is the direction the
spec's Story 5 asks for.

## Project Structure

### Documentation (this feature)

```text
specs/011-restart-running-chats/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── daemon-api.md    # Phase 1 output
├── checklists/
│   └── requirements.md  # From /speckit-specify
├── spec.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/
│   └── Agent.swift                    # + restartPickUps, and its coding
├── Daemon/
│   └── DaemonAPI.swift                # + agents/resuming method, agent/resuming notification
└── Client/
    └── AgentsModel.swift              # + resuming set, fed by notification and seeded on connect

Packages/AgentsKit/Sources/AgentsKit/Daemon/
├── DaemonCore+Recovery.swift          # order, the pick-up limit, queue-front delivery, broadcast
├── DaemonCore+Commands.swift          # stop() withdraws a pending pick-up; enqueue-at-front
├── DaemonCore+Dispatch.swift          # + agents/resuming
└── DaemonCore.swift                   # move() clears the count on a turn that ends

App/Sources/
├── AgentList/AgentRow.swift           # "Coming back" row and icon
└── Chat/Transcript.swift              # the same words at the head of an open chat

Remote/Sources/
├── Projects/AgentCard.swift           # the same on the phone
└── Chat/EntryView.swift

Packages/AgentsKit/Tests/AgentsKitTests/
├── Integration/DaemonTests.swift      # extends the four existing recovery tests
└── Unit/                              # the pick-up-limit rule, decided without a daemon
```

**Structure Decision**: No new files. Every change lands in a file that already owns the concern —
recovery in `DaemonCore+Recovery.swift`, the transient client fact beside `filesToShow` in
`AgentsModel.swift`, the row text beside the existing state switch in `AgentRow.swift` and its
twin in `AgentCard.swift`. The pick-up-limit rule is the one piece of pure logic, and it is a
computed property on `Agent` in Core so that a unit test can exhaust it and both platforms can ask
it.

## Complexity Tracking

> No Constitution Check violations. Section intentionally empty.
