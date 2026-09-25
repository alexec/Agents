# Implementation Plan: One Chat on Every Screen

**Branch**: `033-mobile-chat-parity` | **Date**: 2026-09-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/033-mobile-chat-parity/spec.md`

## Summary

The phone's chat becomes the Mac's chat. The two already read one model (`AgentsModel`, which
folds entries into `TranscriptItem`s). They diverge only in the views: `App/Sources/Chat` and
`Remote/Sources/Chat` each draw the transcript, the prompt bar and the cards, and the phone's
copies are older and smaller.

The approach is to **share what can be shared, then port what cannot**:

1. **The transcript rows move to `Shared/UI/Chat/`** and both apps draw them. `EntryRow`,
   `ToolRunRow`, `ToolCallLine`, `StateLine`, `WorkReportLine`, `QueuedPromptRow`,
   `WorkingLine` and `ComingBackLine` become one copy. The few things that differ per
   platform (opening a touched file, a command's output, taking a queued prompt back) come in
   through one environment value, `ChatActions`. The phone's `EntryView.swift` goes. This
   answers FR-001 to FR-005 and most of FR-021, because shared code cannot be worded twice.
2. **The follow-the-end scroller moves to `Shared/UI/Chat/TranscriptScroller.swift`.** This is
   the Mac's `Transcript` scroll logic (follow mode, hysteresis, `contentMargins` under a floating
   bar, lift on a growing floor, the scroll-to-end token, anchored earlier pages) with its model
   calls turned into inputs. `JumpToEnd` becomes one copy. This answers FR-016 and FR-017.
3. **Agent actions move into `AgentsModel`** where both clients can reach them: the pending
   optimistic option value (`chosenOption`/`setOption` bookkeeping), the "let this one go on"
   arithmetic, and terminal output collected from `agent/terminalOutput`. The Mac's `AppModel`
   now calls these instead of holding its own copy.
4. **The phone's prompt area is rebuilt to the Mac's layout.** From top to bottom: the header row
   (folder or worktree, meter, runtime), the cost-limit banner, the attachment strip, the command
   and mention lists, the suggestion chip, the field with attach, dictate and send-or-queue, and
   the options row. The header row, the banners and the options notes are shared views.
   `OptionMenu` gets an iOS face: a `Menu` or `Toggle` capsule, the same data and the same order.
   `Dictation` moves to `Shared/UI`, with `#if` only where AppKit and UIKit differ. The
   recogniser code is already platform-neutral.
5. **One new daemon method, `files/mention`,** runs the existing `FileMention.matching` on the
   Mac, so the phone can offer `@` names from the agent's folder (FR-013). The result is a list
   of Mac paths, which the phone attaches as references. That is safe here where it is not for
   Files, because these paths name files on the Mac, where the agent reads them.
6. **Layout and verbs on the phone:** the prompt area floats over the transcript and cards float
   above it (FR-018). Stop is a toolbar button and Archive pops to the project (FR-019). The
   draft is kept per conversation with the phone's existing `DraftStore` (FR-014). iPad hardware
   keys use the same `onKeyPress` handlers as the Mac (FR-015).
7. **A consistency check** (FR-021) is added to `ConsistencyTests`. It fails if `Remote/Sources`
   defines its own transcript row or prompt-area message types again, and if any user-facing
   literal in the shared chat folder is duplicated in either app's chat folder.

**Order.** The layout comes first and is settled by running it (memory: settle the UX before
building depth). Phase 1 is the shared rows and the scroller, visible on both at once. Phase 2 is
the prompt area against the daemon as it is. The one daemon addition, `files/mention`, comes
last, behind a UI that already works without it.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, strict concurrency complete. Unchanged.

**Primary Dependencies**: SwiftUI; Speech and AVFoundation (dictation, both platforms);
PhotosUI and UniformTypeIdentifiers (phone attachments, already used by 029). No new package.

**Storage**: No new storage. The phone's per-conversation draft uses the existing `DraftStore`
under the key the Mac already uses for an agent.

**Testing**: `swift test` in `Packages/AgentsKit` covers the moved model logic (pending options,
ceiling step, terminal output, `files/mention`) and the consistency scan. Both schemes are
built with `xcodebuild` (skip plugin validation; build sequentially). The Mac is checked with
the run-app skill on a scratch root. The phone is built for the generic simulator. The walk on a
real iPhone and iPad is Alex's (memory: no Simulator GUI, no throwaway simulators).

**Target Platform**: iOS 27 on iPhone and iPadOS 27 (judged), macOS 27 (the Mac chat must not
change for the person, apart from the shared rows being the same rows).

**Project Type**: The existing five targets. The daemon gains one method, the Mac app and the
Remote change, and the bridge and notification extension are untouched.

**Performance Goals**: Following a streaming reply moves the pane by the fragment with no
animation restarts, as on the Mac (SC-004). A control change shows at once (optimistic) and
settles within 2 s (SC-003). `files/mention` answers within 300 ms for a normal repository,
using the kit's existing capped walk.

**Constraints**: Shared/UI may import only SwiftUI and AgentsKitCore, never `AppModel`,
`RemoteModel`, AppKit or UIKit outside `#if os(...)`. The phone links AgentsKitCore only. The
Mac's look and behaviour must be unchanged except where the Mac's copy was the one being moved.
Phone attachments stay within 029's 900 KB total.

**Scale/Scope**: About 700 lines move to Shared/UI, about 350 are deleted from the Remote, the
Remote prompt area grows by about 300, and the daemon grows by about 40 plus tests.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled template and sets no gates. This plan
checks against the project's working rules instead:

| Rule | Where it comes from | This plan |
|------|---------------------|-----------|
| The daemon owns the truth; windows and phones only show it | 001, 013 | Options, queue, ceilings and file search all go through the daemon. The phone keeps only its draft |
| Shared/UI holds definitions both apps must agree on; arithmetic lives in AgentsKitCore under test | `Shared/UI/README.md` | Views move to Shared/UI; pending-option and ceiling arithmetic move to `AgentsModel` in Core, under test |
| Settle the layout by running it before building machinery | Memory | Phases 1–2 are layout against today's daemon; `files/mention` is last |
| Parity: anything the Mac has and the remote does not is a decision | 013 FR-021 | The spec's Deliberate Differences are the whole list, and FR-021's scan enforces it |
| Never lose what the person typed | 005, 013, 025 | Draft kept per conversation. A failed send keeps words and attachments |
| Main checkout is only main | Memory | Built in `/tmp/w-033` on `033-mobile-chat-parity` |

**Gate: pass.** Re-checked after Phase 1 design: still passes. The wire gains one method and no
changed shapes.

## Project Structure

### Documentation (this feature)

```text
specs/033-mobile-chat-parity/
├── spec.md
├── plan.md                  # this file
├── research.md              # Phase 0
├── data-model.md            # Phase 1
├── quickstart.md            # Phase 1
├── contracts/
│   ├── daemon-api.md        # files/mention
│   └── chat-surface.md      # ChatActions and the shared views' inputs
├── checklists/requirements.md
└── tasks.md                 # /speckit-tasks
```

### Source Code (repository root)

```text
Shared/UI/Chat/                         # new: compiled into both apps
├── ChatActions.swift                   # environment value: open location, terminal text, unqueue
├── TranscriptRows.swift                # EntryRow, ToolRunRow, ToolCallLine, StateLine, WorkReportLine,
│                                       # QueuedPromptRow, WorkingLine, ComingBackLine
├── TranscriptScroller.swift            # follow mode, earlier pages, lift, JumpToEnd
├── PromptHeader.swift                  # folder/worktree, meter, runtime capsules
├── CostLimitBanner.swift               # own-limit and day-limit banners
├── OptionsNote.swift                   # PromptControlsState notes and "Try again"
└── Dictation.swift                     # moved from App/Sources/Chat

App/Sources/Chat/                       # Mac: Transcript.swift shrinks to wiring; PromptBar uses shared pieces
Remote/Sources/Chat/                    # phone: EntryView.swift deleted; RemoteChatView and PromptBar rebuilt
Remote/Sources/Chat/OptionCapsule.swift # the iOS face of OptionMenu
Remote/Info.plist                       # microphone and speech usage strings
Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift  # pending options, ceiling step, terminal output
Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift    # files/mention
Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift
Packages/AgentsKit/Tests/AgentsKitTests/Unit/ConsistencyTests.swift # FR-021 scan
Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentsModelTests.swift
Packages/AgentsKit/Tests/AgentsKitTests/Integration/FileMentionTests.swift
```

**Structure Decision**: No new target. Shared views go in a `Chat/` subfolder of the existing
`Shared/UI`, which `project.yml` already compiles into both apps, so `xcodegen generate` is the
only project step. Types that keep one name per app (`BlocksView`, `DiffView`, `PlanView`,
`MarkdownText`, `TerminalOutputView`) stay per-app. The shared rows call them by name and each
target supplies its own, which keeps `NSImage`/`UIImage` out of Shared/UI.

## Complexity Tracking

No gate violations. One choice is worth recording:

| Choice | Why | Simpler alternative rejected because |
|--------|-----|--------------------------------------|
| An environment value (`ChatActions`) instead of the shared rows reading a model | Shared/UI cannot see `AppModel` or `RemoteModel`; three closures are the whole difference | A protocol both models conform to leaks every other model member into the shared layer and needs `any` existentials in `@Environment` |
