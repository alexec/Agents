# Research: One Chat on Every Screen

Every decision below was checked against the code on `main` at `0cd2ccf`.

## 1. Where the two chats actually differ

**Finding.** The data is already shared. `RemoteModel.transcriptItems` is
`AgentsModel.transcriptItems`, which the Mac reads too, so both apps get the same folded runs
and the same dropped plumbing (usage lines, option changes and `.finished` are removed by
`TranscriptDisplayBuilder`). Every difference is in `Remote/Sources/Chat` against
`App/Sources/Chat`:

| Area | Mac | Phone today |
|------|-----|-------------|
| Folded run | latest line, one line, tap unfolds | chevron per call, "N more" / "Show less" |
| Call detail | content, `name:line` links, raw input/output | content, names, no raw |
| Terminal content | live output | "Ran a command on your Mac" |
| Unknown content | pretty-printed raw | "Something this version does not know how to show" |
| Queued prompts | "Waiting its turn" rows, removable | not shown |
| Working | spinner at foot | nothing |
| Following | geometry-driven, by fragment, hysteresis 160/40 | animated scroll per new entry only |
| Bar | floats over transcript; `contentMargins` | opaque inset under transcript |
| Cards | float above the bar; bar stays | replace the bar |
| Header | folder/worktree, meter, runtime above field | meter in bottom toolbar |
| Controls | every advertised option, grouped | none |
| Attach / dictate | yes | no (attach exists on the start sheet, 029) |
| Send icon | queue icon while working | always arrow |
| Cost banners | own limit and day limit | none |
| `@` mentions | local walk | none |
| Drafts | per conversation (`KeepsDrafts`) | `@State`, lost on navigation |
| Stop / Archive | toolbar buttons; Archive leaves | inside a "…" menu; Archive stays |

**Decision.** Close every row, except the ones the spec lists as deliberate.

## 2. Share or port the transcript

**Decision.** Share. Move the Mac's row views to `Shared/UI/Chat/TranscriptRows.swift`.

**Rationale.** Two copies drifted in less than a month. `Shared/UI` exists for this case, and
its README says the two apps sharing no view code is how they came to disagree. The Mac rows touch
the model in exactly three places: `NSWorkspace.open` for a location,
`model.terminalOutput[id]`, and `model.unqueue`. Those three become `ChatActions`, an
environment value holding closures.

**Alternatives.** Porting the Mac's rows into the phone's `EntryView` fixes today's drift and
leaves the next one to happen. A protocol over both models would pull every model member into
the shared layer.

**Detail.** The rows call `BlocksView`, `DiffView`, `PlanView` and `TerminalOutputView`. These
stay per-app with the same names and signatures, and the shared file resolves them in whichever
target compiles it. The Remote needs a `TerminalOutputView` and a `DiffView(diff:)` with the
Mac's signature; its `DiffView` already matches.

## 3. Share the scroller

**Decision.** Extract the Mac `Transcript`'s scroll behaviour into a shared
`TranscriptScroller<Rows: View, Foot: View>`. It takes as inputs: the settle key (selection),
`hasMore`, `entryCount`, `loadEarlier: () async -> Void`, `firstItemID`, `bottomInset`,
`scrollToEndToken`, and a `focusedEntry` binding. The phone's `measure(transcriptHeight:)` is
passed in as an optional `onHeight` closure.

**Rationale.** The Mac's comments record two failed declarative attempts and a stutter
bug that the phone still has (a scroll animated on each entry). The fixed version should be the
only version.

## 4. Options on the phone

**Finding.** `agents/setOption` and the optimistic `pendingOptions` bookkeeping exist, but in
`AppModel`. `PromptControlsState.resolve` is in Core. `OptionMenu` is Mac-only because of
`SelectCapsule`, a popover styled for a pointer.

**Decision.** Move `PendingOption`, `chosenOption` and `setOption` bookkeeping into
`AgentsModel`, with the network call injected, so both apps and a unit test share it. On the
phone, draw each option as a capsule `Menu` (select) or a capsule toggle (boolean), in a
horizontal scroller with permission options first. That is the Mac's order and the Mac's
narrow-width rule.

## 5. Attachments and dictation

**Decision.** Reuse 029's `AttachButton`, `AttachmentStrip` and `PhoneAttachment` rules as they
are, and add paste of a picture via the field's paste handling. Extend `RemoteModel.send` to
take attachments, checking `PhoneAttachment.totalRefusal` first. Move `Dictation.swift` to
`Shared/UI/Chat/`. It imports only AVFoundation and Speech. On iOS the audio session has to be
configured for recording before the engine starts, which is one `#if os(iOS)` block. Add
`NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` to `Remote/Info.plist`.

## 6. Terminal output on the phone

**Finding.** `agent/terminalOutput` is a daemon broadcast. The phone ignores it because
`AgentsModel.apply` does not claim it. `AppModel` collects it itself.

**Decision.** `AgentsModel` claims it and keeps `terminalOutput[terminalID]`, capped at the
same length the Mac keeps. `AppModel` reads the shared copy. The phone shows what it has heard.
Output from before the phone connected is not in the transcript and is not fetched. The call
then says so ("Ran a command on your Mac" followed by whatever arrived), which is the spec's
edge case.

## 7. `@` mentions from the phone

**Decision.** Add `files/mention { agentID, term }` → `[FileMentionDTO { path, relativePath }]`.
The daemon runs `FileMention.matching(term, in: [agent.cwd] + agent.additionalDirectories)`.
The phone debounces by cancelling the previous call on each keystroke, as the Mac does, and on
choosing appends `.file(URL(filePath: path))` as a reference. A reference is a Mac path, which
the agent reads on the Mac, so 029's by-value rule does not apply to it and it does not count
toward the 900 KB.

**Alternatives.** Sending the file's contents by value would double the bytes on the link
for no gain.

## 8. Cost limit on the phone

**Finding.** `agents/setCeiling` exists. `letThisAgentGoOn` is arithmetic in `AppModel`.
The phone has no Settings screen for limits. `cost/setLimits` exists, but a phone limits editor
is a feature of its own.

**Decision.** Move the step arithmetic to `AgentsModel.ceilingToGoOn(for:)` (Core, tested).
The phone banner offers "Let this one go on". In place of "Raise the limit" it says the limit
is changed in Settings on the Mac.

## 9. Cards and the bar

**Decision.** The phone uses the Mac's structure: a `ZStack(alignment: .bottom)` of the
scroller and a `form` stack (permission sheet, form sheet, prompt bar), measured with
`onGeometryChange` to feed `bottomInset`. The phone keeps its stacked `PermissionSheet` as a
deliberate difference.

**Risk.** A tall permission card plus the keyboard on a small iPhone can cover the whole
transcript. When the field is not focused, the bar collapses to the field row alone (header
and options hidden) while a card is up. The prompt area is still present, as FR-018 asks.

## 10. Drafts on the phone

**Decision.** Use `DraftStore` with `DraftKey.agent(id)`, the same key the Mac uses on its own
disk. Nothing syncs between devices; each device keeps its own. The Mac's `KeepsDrafts`
imports AppKit only for the app-termination notification. The phone's version saves on
`scenePhase` going to background instead.

## 11. iPad keyboard

**Decision.** Apply the Mac field's `onKeyPress` handlers on iOS too. SwiftUI delivers them from
a hardware keyboard and never from the on-screen one, so an iPhone without a keyboard is
unaffected. Return sends only when a hardware keyboard is attached. On the on-screen keyboard,
Return adds a line and Send is the button, as on iOS generally.
