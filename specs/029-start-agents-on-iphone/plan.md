# Implementation Plan: Starting agents on iPhone

**Branch**: `029-start-agents-on-iphone` | **Date**: 2026-09-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/029-start-agents-on-iphone/spec.md`

## Summary

The phone gets a New agent sheet on the project page: runtime, the runtime's own choices, a
prompt and attachments, sent with `agents/start`. The iPad gets the same sheet, which closes
013's T072.

Most of it is already there. `agents/options` makes a draft session and answers from a cache,
`agents/start` takes the choices, `DraftStore` keeps an unsent prompt per project, and
`PromptControlsState` and `ModeMemory` in AgentsKitCore already decide which choices to draw
and what to open them on. The phone has never used any of these.

Reading the code turned up four gaps, and they are most of the work (research §1–§5):

1. **The mode memory is the Mac app's, not the Mac's.** It is in the app's `UserDefaults`.
   It moves into the daemon as `modes.json`, with `modes/remembered`, `modes/import` and a
   `modes/changed` broadcast. The app copies its existing keys across once, filling gaps only.
   The runtime default and model/effort are already shared, so they stay where they are.
2. **Nothing ends an unused draft.** Each `agents/options` holds a runtime process until a
   start uses it, which on the Mac already leaks one process each time the form changes. A
   phone would leak one every time the sheet opens. The fix is `agents/discardDraft`, plus
   ending a draft 30 s after the connection that made it goes.
3. **A start is not idempotent.** A retry after a lost reply makes a second agent. The fix is
   `StartRequest.requestID`, remembered by the daemon and stored on the agent as
   `startRequestID`.
4. **A file reference from a phone points at nothing on the Mac.** Pictures are sent by value,
   downscaled to fit the relayed link's 1 MB record. Text files are sent by value as embedded
   resources. Anything else is refused with a sentence.

**Order.** The sheet goes first, against the daemon as it is, and is settled by running it
(memory: settle the UX before building depth). The four gaps are filled behind it. The P1
story can already be demonstrated after the first phase, because `agents/start` with defaults
works today.

**Stated up front.** Nothing here makes the phone reach the Mac from a train. That is the
relayed link, 013 Track A, which is Alex's. This feature works over whichever link
`DaemonClient` has, which today means the same network. The spec's cellular test is recorded
as waiting on Track A.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, strict concurrency complete. Unchanged.

**Primary Dependencies**: SwiftUI, PhotosUI (`PhotosPicker`), UniformTypeIdentifiers
(`fileImporter`), ImageIO for downscaling. All first-party. No new package.

**Storage**: Daemon, `modes.json` in the root's Application Support folder, beside the option
cache. Phone, the existing `DraftStore` under `DraftKey.newAgent(folder:)`. `Agent` records
gain `startRequestID`.

**Testing**: `swift test` in `Packages/AgentsKit` for everything in the daemon and core. Scratch
daemon over `daemon.sock` for the wire. Simulator screenshots for the sheet. A real-iPhone walk
by Alex for the gate. See [quickstart.md](./quickstart.md).

**Target Platform**: iOS 27 on iPhone (judged), iPadOS 27 (same sheet, judged against T072),
macOS 27 (the mode memory's new home; behaviour unchanged for the person).

**Project Type**: The existing five: Mac app, daemon, bridge, Remote app, notification
extension. The notification extension and the bridge do not change.

**Performance Goals**: The sheet draws with choices in under 0.5 s when the daemon answers from
its option cache, which is the normal case after the first use of a runtime in a folder. The
new agent's conversation is on the phone within 2 s of Send on the direct link (SC-002, direct
link only until Track A).

**Constraints**: Everything attached by value in one start is 900 KB or less, under the relayed
link's 1 MB record. Nothing about the Mac's start form changes for the person. The daemon
accepts every existing caller unchanged, since all new fields are optional.

**Scale/Scope**: One new sheet (about 400 lines), around 150 lines of daemon change, 4 new
daemon methods or notifications, 2 new optional fields. Tests for each daemon rule.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` has never been filled in: it is still the template, so it
sets no gates. The project's working rules come from its memory and earlier features instead,
and this plan checks against those:

| Rule | Where it comes from | This plan |
|------|---------------------|-----------|
| The daemon owns the truth; windows and phones only show it | 001, 013 | Mode memory moves *into* the daemon. The phone keeps only its unsent draft |
| Settle the layout by running it before building machinery | Memory | Phase 1 is the sheet against today's daemon |
| Parity: anything the Mac has and the remote does not is a decision, not an accident | 013 FR-021, `parity.md` | Folders, MCP servers and extra arguments are excluded by name in the spec |
| Never lose what the person typed | 005, 013 FR-028, `RemoteModel.send` | Draft kept on every refusal and drop, cleared only on a settled start |
| Scratch copies share the real app's defaults | Memory | The mode memory moves out of `UserDefaults`, which removes one shared key family |
| Main checkout is only main | Memory | Built in `/tmp/w-029` |

**Gate: pass.** Re-checked after Phase 1 design: still passes. The only additions to the wire
are optional fields and new methods.

## Project Structure

### Documentation (this feature)

```text
specs/029-start-agents-on-iphone/
├── spec.md
├── plan.md                  # this file
├── research.md              # Phase 0
├── data-model.md            # Phase 1
├── quickstart.md            # Phase 1
├── contracts/
│   ├── daemon-api.md        # new and changed methods
│   └── start-screen.md      # what the sheet shows and does
├── checklists/requirements.md
└── tasks.md                 # /speckit-tasks, not written here
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/
├── AgentsKitCore/
│   ├── Daemon/DaemonAPI.swift            # requestID, startRequestID, discardDraft, modes/*
│   ├── Model/Agent.swift                 # startRequestID
│   ├── Model/ModeMemory.swift            # defaultsKey kept: the Mac reads it once to import
│   └── Client/AgentsModel.swift          # defaultRuntimeID(available:), remembered modes copy
└── AgentsKit/Daemon/
    ├── DaemonCore+Commands.swift         # idempotent start, draft ownership, discardDraft, mode writes
    ├── DaemonCore+Dispatch.swift         # route the new methods
    ├── ModeStore.swift                   # new: modes.json, load/save/import
    └── Daemon.swift                      # onDisconnected orphans that connection's drafts

App/Sources/
└── AppModel.swift                        # read modes from AgentsModel, import once, discard replaced drafts,
                                          # defaultRuntimeID from AgentsModel

Remote/Sources/
├── RemoteModel.swift                     # start state, options, discard, send with requestID, reconcile
├── Projects/ProjectPageView.swift        # New agent toolbar button, sheet
└── StartAgent/                           # new
    ├── StartAgentView.swift              # the sheet
    ├── ChoiceRows.swift                  # runtime menu, select menus, switches
    └── PhoneAttachments.swift            # photo/file picking, downscale, size and capability refusals

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/ModeStoreTests.swift             # new
├── Unit/StartIdempotencyTests.swift      # new
└── Unit/DraftLifetimeTests.swift         # new
```

**Structure Decision**: The existing layout. Daemon rules go in AgentsKit where they can be
tested. Anything both apps must agree on goes in AgentsKitCore. The sheet goes in a new
`Remote/Sources/StartAgent/`, mirroring the Mac's `App/Sources/StartAgent/`.

## Phases

1. **The sheet, against today's daemon.** Toolbar button, sheet, runtime menu,
   `agents/options` and `agents/draftOptions`, choice rows, prompt, Send with `agents/start`,
   open the new agent. `DraftStore` for the unsent prompt. The runtime default is computed from
   `AgentsModel`. Refusals come from `JSONRPCError.message`. Add the `-start` DEBUG launch flag.
   Screenshot it and settle the layout. **This alone delivers US1.**
2. **Draft lifetime.** `agents/discardDraft`, connection ownership, grace-period expiry. The phone
   discards on dismissal and on runtime change; the Mac discards drafts it replaces.
3. **Idempotent start.** `requestID` and `startRequestID`, a single-flight map in the daemon, the
   phone's reconcile-on-reconnect.
4. **Mode memory in the daemon.** `ModeStore`, the three wire pieces, writes on start and on
   mode `setOption`, the Mac reading from `AgentsModel` and importing once. **Completes US2.**
5. **Attachments.** Photo and Files pickers, downscaling, the 900 KB cap, capability refusals.
   **Completes US3.**
6. **iPad and gate.** Check the sheet as a form sheet on iPad, point 013's T072 at this
   feature, update `parity.md`'s start row, then Alex's real-iPhone walk (SC-006).

Phases 2–5 are independent of each other after Phase 1. Phases 2 and 3 both touch `start`'s draft
handling, so they are best done one after the other by one person.

## Complexity Tracking

No constitution gates, so nothing to justify against them. One choice worth recording:

| Choice | Why | Simpler alternative rejected because |
|--------|-----|--------------------------------------|
| `startRequestID` persisted on `Agent`, not only an in-memory map | Answers a retry correctly across a daemon restart, and lets the phone find the agent without a new query | In-memory only makes two agents when the daemon restarts between the start and the reply, which is the case 025 made survivable |
