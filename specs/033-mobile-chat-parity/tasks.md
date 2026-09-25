---
description: "Task list for 033: one chat on every screen"
---

# Tasks: One Chat on Every Screen

**Input**: Design documents from `specs/033-mobile-chat-parity/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: The logic that moves into AgentsKitCore and the new daemon method are under test, and
so is the FR-021 wording scan (SC-006). Views are checked by building both schemes and by the
run-app skill; the phone walk is Alex's.

All paths are relative to `/tmp/w-033`.

## Phase 1: Setup

- [X] T001 Create `Shared/UI/Chat/` and run `xcodegen generate` so both targets pick it up (`project.yml` already lists `Shared/UI`)
- [X] T002 Record a baseline: `swift test` in `Packages/AgentsKit` plus both `xcodebuild` schemes on the untouched branch, saved to `/tmp/w-033-baseline.log`

---

## Phase 2: Foundational (blocks every story)

- [X] T003 Move the pending-option bookkeeping (`PendingOption`, `chosenOption`, and the sequence rule "Only the latest write for an (agent, option) may clear it") from `App/Sources/AppModel.swift` into `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift` as `beginOption`/`settleOption`/`chosenOption`, and make `AppModel.setOption` call it
- [X] T004 [P] Unit tests for T003 in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentsModelTests.swift`: a pending value wins; a stale settle does not clear a later choice; a settle falls back to `startOptions`
- [X] T005 Claim `agent/terminalOutput` in `AgentsModel.apply` and keep `terminalOutput[terminalID]`, tail-capped at the Mac's cap. Remove the copy in `App/Sources/AppModel.swift` and read the shared one
- [X] T006 [P] Unit test for T005 in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentsModelTests.swift`: chunks append per terminal; the cap keeps the tail
- [X] T007 Add `ceilingToGoOn(for:under:)` to `AgentsModel` and make `AppModel.letThisAgentGoOn` use it
- [X] T008 [P] Unit test for T007 in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/CostLimitTests.swift`
- [X] T009 Create `Shared/UI/Chat/ChatActions.swift`: an environment value with `open(ToolCallLocation)`, `terminalOutput(String) -> String`, and `unqueue(QueuedPrompt, UUID) async`, with no-op defaults

**Checkpoint**: the suite is green, and the Mac builds and behaves as before.

---

## Phase 3: User Story 1 - The conversation reads the same (P1) 🎯 MVP

**Goal**: One set of transcript rows, drawn by both apps.

**Independent Test**: The same conversation, line by line on Mac and phone: the same words and the same taps.

- [X] T010 [US1] Move `EntryRow`, `WorkReportLine`, `QueuedPromptRow`, `ToolRunRow`, `ToolCallLine`, `WorkingLine`, `ComingBackLine` and `StateLine` from `App/Sources/Chat/Transcript.swift` into `Shared/UI/Chat/TranscriptRows.swift`. Add a public `TranscriptRow(item:isExpanded:toggle:)`. Replace `NSWorkspace`, `model.terminalOutput` and `model.unqueue` with `ChatActions`. Use `.help` only under `#if os(macOS)`, and accessibility hints on iOS
- [X] T011 [US1] Make `App/Sources/Chat/Transcript.swift` draw `TranscriptRow` and `QueuedPromptRow`/`WorkingLine`/`ComingBackLine` from Shared, and inject `ChatActions` in `App/Sources/Chat/ChatView.swift` (open with `NSWorkspace`, terminal from `work.terminalOutput`, unqueue from `AppModel`)
- [X] T012 [P] [US1] Give the Remote the per-app types the shared rows call: `TerminalOutputView(text:)` in `Remote/Sources/Chat/BlocksView.swift`, and a Mac-compatible `ServedRequestLine` if the Mac's is not already in the moved set. Match signatures to `App/Sources/Chat/DiffView.swift`
- [X] T013 [US1] Add `unqueue(_:from:)` and `terminalOutput` pass-through to `Remote/Sources/RemoteModel.swift`
- [X] T014 [US1] Replace `EntryView` in `Remote/Sources/Chat/RemoteChatView.swift` with the shared rows plus `QueuedPromptRow` and `WorkingLine`, inject `ChatActions` (open sets `fileOnScreen`), and delete `Remote/Sources/Chat/EntryView.swift`. Keep `WrappingHStack` only if still used
- [X] T015 [US1] Build both schemes; screenshot the Mac chat on a scratch root with the run-app skill and compare with the baseline

---

## Phase 4: User Story 2 - Talking to a running agent works the same (P1)

**Goal**: Every control, attach, dictate and queue, from the phone.

**Independent Test**: Change each control from the phone, attach, dictate, and send while working; the Mac shows it all.

- [X] T016 [US2] Add to `Remote/Sources/RemoteModel.swift`: `chosenOption`/`setOption` using the T003 bookkeeping over `agents/setOption`; `send(_:attachments:to:)` that refuses with `PhoneAttachment.totalRefusal` first; `promptCapabilities(for:)` already exists
- [X] T017 [P] [US2] Create `Remote/Sources/Chat/OptionCapsule.swift`: a select option as a capsule `Menu` (grouped with headings, checkmark on the chosen), a boolean as a capsule toggle, and `.unsupported` as nothing, matching `App/Sources/StartAgent/OptionMenu.swift`
- [X] T018 [P] [US2] Create `Shared/UI/Chat/OptionsNote.swift`, holding the six `PromptControlsState` sentences and "Try again" moved from `App/Sources/Chat/PromptBar.swift`, and use it there
- [X] T019 [US2] Move `App/Sources/Chat/Dictation.swift` to `Shared/UI/Chat/Dictation.swift`, adding an `#if os(iOS)` `AVAudioSession` record setup before the engine starts; add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` to `Remote/Info.plist` in the Mac's words
- [X] T020 [US2] Rebuild `Remote/Sources/Chat/PromptBar.swift` to the Mac's structure: attachment strip (029's `AttachmentStrip`), command list, suggestion chip, the field with `AttachButton`, a dictate button (with the one-time primer sheet) and a send button that shows `arrow.up.to.line` / "Queue" while the agent holds its runtime, and an options row (a horizontal scroll, permission options first, `Spacer`, the rest), or `OptionsNote` when there are no controls
- [X] T021 [US2] Keep words and attachments in the field when a send fails, and clear only on success, in `Remote/Sources/Chat/PromptBar.swift`

---

## Phase 5: User Story 3 - The same things around the field (P2)

**Goal**: The header row and the cost banners.

**Independent Test**: An agent in a worktree at its limit: the worktree, meter and runtime above the field, and the banner; "Let this one go on" works.

- [X] T022 [P] [US3] Create `Shared/UI/Chat/PromptHeader.swift` (the worktree or folder capsule, a meter slot and the runtime capsule) from `App/Sources/Chat/PromptBar.swift` `whereAndWhat`'s agent branch, and use it there
- [X] T023 [P] [US3] Create `Shared/UI/Chat/CostLimitBanner.swift` with the own-limit and day-limit banners moved from `App/Sources/Chat/PromptBar.swift` `atItsLimit`. `raise` is optional; when it is nil the banner says "Change the limit in Settings on your Mac." Use it on the Mac with `SettingsLink`
- [X] T024 [US3] Add `letThisAgentGoOn` to `Remote/Sources/RemoteModel.swift` via `agents/setCeiling` and `ceilingToGoOn`
- [X] T025 [US3] Put `PromptHeader` (with the phone's `ContextMeter`) and `CostLimitBanner` at the top of the phone prompt bar, and remove the bottom-bar `ContextMeter` toolbar item from `Remote/Sources/Chat/RemoteChatView.swift`

---

## Phase 6: User Story 4 - The chat moves the way the Mac's does (P2)

**Goal**: One follow-the-end behaviour; the transcript under a floating bar.

**Independent Test**: A streaming reply follows with no taps; scrolling up holds; sending returns to the end.

- [X] T026 [US4] Extract the scroll behaviour of `App/Sources/Chat/Transcript.swift` into `Shared/UI/Chat/TranscriptScroller.swift` with the inputs in `contracts/chat-surface.md`, and move `App/Sources/Chat/JumpToEnd.swift` into `Shared/UI/Chat/`. Keep the Mac's thresholds (160 to leave, 40 to be back) and its comments
- [X] T027 [US4] Make `App/Sources/Chat/Transcript.swift` a thin wrapper over `TranscriptScroller`; confirm on a scratch root that following, jump-to-end, earlier pages and focus-an-entry behave as before (following checked; leaving the end, jump-to-end and earlier pages are Alex's, see quickstart Status)
- [X] T028 [US4] Add `scrollToEndToken` to `Remote/Sources/RemoteModel.swift` (bumped on a successful send), and rebuild `Remote/Sources/Chat/RemoteChatView.swift` as a `ZStack(alignment: .bottom)` of `TranscriptScroller` and the form stack, measured into `bottomInset`, passing `measure(transcriptHeight:)` as `onHeight`. Delete the phone's own `Place`, `JumpToEnd`, `settle` and `loadEarlier`

---

## Phase 7: User Story 5 - Questions sit where the Mac puts them (P2)

**Goal**: Cards float above the prompt area, and the prompt area stays.

**Independent Test**: A permission request and then a form; each floats above the prompt area and clears on both when answered.

- [X] T029 [US5] In `Remote/Sources/Chat/RemoteChatView.swift`, make the form stack `PermissionSheet`, then `ElicitationSheet`, then `PromptBar` (not archived), in that order, all in the chat column. While a card is up and the field is not focused, the bar shows only its field row
- [X] T030 [P] [US5] Give `Remote/Sources/Permission/PermissionSheet.swift` the Mac's prominence rule (an `allows` option drawn prominent, the rest plain), keeping its stacked layout and full detail

---

## Phase 8: User Story 6 - The same verbs, reached the same way (P3)

**Goal**: Stop and Archive in the top bar, drafts per conversation, keyboard parity, `@` mentions.

**Independent Test**: Stop, then Archive (which leaves the chat); switch conversations with a draft; an iPad keyboard; `@Trans`.

- [X] T031 [US6] In `Remote/Sources/Chat/RemoteChatView.swift`, add Stop as a top-bar button when `canStop`, and Archive beside it, which archives and clears the selection so the view returns to the project. The "…" menu keeps "Exchanged" and "Bring back"
- [X] T032 [US6] Keep the phone's draft per conversation with `DraftStore` and `DraftKey.agent(id)` in `Remote/Sources/Chat/PromptBar.swift`: restore on appear and on selection change, save on change (debounced) and when going to the background, and clear on a successful send
- [X] T033 [US6] Apply the Mac field's `onKeyPress` handlers (Return, Option-Return, Tab, the arrows, Escape) and a highlighted row in the command and mention lists in `Remote/Sources/Chat/PromptBar.swift`
- [X] T034 [US6] Add `DaemonAPI.Method.filesMention`, `FileMentionRequest` and `FileMentionDTO` to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, and dispatch it in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`: an empty term returns `[]`, an unknown agent returns "No such agent", and the search covers `[cwd] + additionalDirectories` with limit 30
- [X] T035 [P] [US6] Integration test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/FileMentionTests.swift` covering a match, an empty term, an unknown agent, and additional directories
- [X] T036 [US6] Phone `@` mentions: `RemoteModel.mentions(term:for:)` over `files/mention`, cancelled per keystroke, drawn as a list in `Remote/Sources/Chat/PromptBar.swift`; choosing one completes the name and appends `.file(URL(filePath: path))`

---

## Phase 9: Polish & cross-cutting

- [X] T037 FR-021 scan in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ConsistencyTests.swift`: fails if `Remote/Sources` declares `EntryRow`, `ToolRunRow`, `ToolCallLine`, `StateLine`, `WorkReportLine`, `JumpToEnd` or `QueuedPromptRow`, or if any string literal of 12+ characters in `Shared/UI/Chat/*.swift` also appears in `App/Sources/Chat` or `Remote/Sources/Chat`
- [X] T038 Update `Shared/UI/README.md` for the `Chat/` folder and `ChatActions`
- [X] T039 Full gate: `swift test` (compare any failures with the baseline, per the flaky-suite memory), both schemes built, and a Mac run-app walk of a live conversation
- [X] T040 Record the deliberate differences and the phone walk (quickstart §4) as Alex's in the feature notes, and commit on `033-mobile-chat-parity`

---

## Dependencies

- Phase 2 blocks everything. T009 blocks T010.
- US1 (T010–T015) comes before US4 (T026–T028): the scroller draws the shared rows.
- US2 comes before US3, US5 and US6, because they all edit the rebuilt phone `PromptBar` and `RemoteChatView`.
- T034 → T035 → T036.
- T037 goes last, once nothing more moves.

## Parallel opportunities

- T004, T006 and T008 alongside each other once T003, T005 and T007 land.
- T012 alongside T010 and T011.
- T017, T018 and T019 together.
- T022 and T023 together.
- T034 and T035 at any time after Phase 2.

## Implementation strategy

MVP is Phase 2 plus US1: the phone reads exactly like the Mac. Then US2 (the controls, the
biggest ask), then US4, which fixes the most-felt behaviour, then US3, US5 and US6. After each
phase both schemes build and the suite is green.
