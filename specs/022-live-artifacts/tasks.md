---
description: "Task list for Live Artifacts, A Proof Of Concept"
---

# Tasks: Live Artifacts, A Proof Of Concept

**Input**: Design documents from `/specs/022-live-artifacts/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/show-file-tool.md](./contracts/show-file-tool.md), [contracts/daemon-api.md](./contracts/daemon-api.md), [quickstart.md](./quickstart.md), [findings.md](./findings.md)

**Tests**: Included, and put where they carry a claim. Everything pure — the passage split, the line diff, the three-way merge, the line-to-passage lookup — is a function from strings to values and is exhausted in unit tests, each written before the type it tests. The daemon's `artifact/write` and the turn note are tested against `DaemonCore` the way `show_file` is in `ShowFileTests`. The page itself has no test target and is **walked, not asserted**: `quickstart.md` is its test plan, and each slice ends with a walk task that is not checked off until it has been seen.

**Organization**: Phases are the plan's slices A–G, in that order. They map onto the stories as US1 → A and B, US2 → C and D, US4 → E, US3 → F, US5 → G. **Slice A is the gate**: its last task is running the app and seeing the page follow an agent, and nothing in B–F is started until that has been seen — [[settle-ux-before-building-depth]] is the rule and 007's retirement is the reason.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US5)

## Path Conventions

- `Packages/AgentsKit/Sources/AgentsKitCore/Model/` — `Passage.swift`, **new**, beside `MarkdownBlock.swift`. Pure: no I/O, no platform, no `import SwiftUI`.
- `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/` — `AppService.swift` (the tool's description) and `Briefing.swift` (the turn note's wording).
- `Packages/AgentsKit/Sources/AgentsKit/Daemon/` — `DaemonCore+Artifacts.swift`, **new**; `DaemonCore+Commands.swift` (the note goes out in `beginTurn`); `DaemonCore+Dispatch.swift` (the new method).
- `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift` — the request type and method name.
- `App/Sources/Sidebar/` — `LivePage.swift`, `PassageEditor.swift`, `ImageStamps.swift`, **new**; `FilesPane.swift` routes `.md` to the page.
- `App/Sources/AppModel.swift` — `writeArtifact`.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration}/` — Swift Testing. Neither app has a test target.
- `specs/022-live-artifacts/findings.md` — the deliverable.

Run `xcodegen generate` after adding any source file to the app target; the pbxproj lists files explicitly. Build with `-skipPackagePluginValidation`. Launch the built app with `env -i` and a scratch `--root`, per the quickstart, so nothing here touches real agents.

---

## Phase 1: Setup

**Purpose**: The empty suites and the one shared type's file, so every later task adds to something rather than inventing a place.

- [X] T001 Create `Packages/AgentsKit/Sources/AgentsKitCore/Model/Passage.swift` with a doc comment stating what a passage is (a run of source lines separated by blank lines, fences kept whole) and why it is split from source rather than from `MarkdownBlock` (research §2: Foundation's parser returns no source ranges). Declare `public struct Passage: Hashable, Sendable` with `source: String`, `lines: ClosedRange<Int>`, `separator: String` (the blank-line run that followed it, empty for the last), `isHeading: Bool`, and a memberwise `public init`. No functions yet.
- [X] T002 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/PassageTests.swift` with `import Foundation`, `import Testing`, `@testable import AgentsKitCore` and an empty `@Suite("Passages") struct PassageTests {}` whose doc comment names the claim: split then join is the identity on any document, and every line of the document is in exactly one passage.
- [X] T003 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/PassageMergeTests.swift` with the same imports and an empty `@Suite("Merging one passage") struct PassageMergeTests {}` whose doc comment names the claim: the person's text appears in every result, merged or collided (FR-015).
- [X] T004 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ArtifactWriteTests.swift` with `import Foundation`, `import Testing`, `@testable import AgentsKit`, `@testable import AgentsKitCore` and an empty `@Suite("Writing an artifact for the person", .timeLimit(.minutes(1))) struct ArtifactWriteTests {}`, copying the `temporary()`, `core(_:locations:watching:)`, `midTurn()` and `mintedToken(_:)` helpers from `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ShowFileTests.swift` verbatim.

**Checkpoint**: The package builds; three suites exist and pass because they are empty.

---

## Phase 2: Foundational — the passage split

**Purpose**: `Passage.split` and `Passage.join` are what every slice is built on: the page, the diff, the merge and the turn note all name passages. Nothing in A–F starts before these pass.

- [X] T005 In `PassageTests.swift`, write the tests for `Passage.split(_:)` before it exists: plain text with no blank lines is one passage with `lines == 1...n`; two paragraphs separated by one blank line are two passages and the first's `separator` is `"\n"`; three blank lines between paragraphs are kept in `separator` exactly; a fenced block (```` ``` ````) containing a blank line is one passage; a `~~~` fence likewise; an unclosed fence runs to the end of the document as one passage; a heading line followed directly by a paragraph with no blank line is one passage with `isHeading == true`; front matter (`---` … `---`) at the top is one passage; the empty string is `[]`; a document that is only blank lines is `[]`; `lines` of consecutive passages are contiguous and the last ends at the document's line count.
- [X] T006 In `PassageTests.swift`, write the tests for `Passage.join(_:)`: `join(split(x)) == x` for every input in T005 and for `README.md` read from the repository root; joining `[]` is the empty string.
- [X] T007 In `PassageTests.swift`, write the tests for `Passage.index(containing:in:)`: line 1 is passage 0; the last line is the last passage; a line inside a separator run belongs to the passage before it; a line past the end returns the last passage's index (data-model.md: "the last passage when the line is past the end"); zero and negative return nil; an empty array returns nil.
- [X] T008 Implement `Passage.split(_:)`, `Passage.join(_:)` and `Passage.index(containing:in:)` in `Passage.swift` until T005–T007 pass. Split by scanning lines once, tracking whether inside a fence (a line whose trimmed prefix is three or more backticks or tildes toggles it; the closing fence must be the same character and at least as long); a blank line outside a fence ends the current passage and is appended to its `separator`. `isHeading` is true when the first line matches `^#{1,6}\s` or the passage's second line is all `=` or all `-` with a non-blank first line. Run `swift test --package-path Packages/AgentsKit --filter PassageTests`.

**Checkpoint**: Split, join and lookup are total and round-trip on the repository's own documents.

---

## Phase 3: Slice A — the live page, read-only (US1, the gate) 🎯 MVP

**Goal**: A `.md` file opens on the paper surface, every change to it on disk appears within a second, the changed passages are marked and the view goes to the first. Nothing is typed.

**Independent Test**: quickstart Slice A — an agent writes a document in four steps; each step appears, is marked, and the view is on it; a screenshot of each.

- [X] T009 [US1] In `PassageTests.swift`, write the tests for `PassageChange.between(old:new:)` before it exists: identical texts give `changedLines == nil`, `changed` empty, `first == nil`; a paragraph appended at the end marks only the new last passage and `first` is its index; a word changed in the second of three paragraphs marks only index 1; two non-adjacent passages changed marks both and `first` is the lower; a passage deleted marks the passage now at that index (or the last if it was last); an entirely different text marks every passage and `first == 0`; `old` empty and `new` non-empty marks all.
- [X] T010 [US1] Add `public struct PassageChange: Hashable, Sendable` to `Passage.swift` with `changedLines: ClosedRange<Int>?`, `changed: IndexSet`, `first: Int?`, and `static func between(old: String, new: String) -> PassageChange` using `CollectionDifference` over `new.split(separator: "\n", omittingEmptySubsequences: false)`, folding every insertion offset (and, for removals, the offset in `new` where the removal sits, clamped) into one line range, then intersecting with `Passage.split(new)`'s ranges. Until T009 passes.
- [X] T011 [US1] Create `App/Sources/Sidebar/LivePage.swift`: a `struct LivePage: View` taking `text: String`, `url: URL`, `line: Int?` (the line an agent named, or nil) and `isEditing: Bool` (always false in this slice). It holds `@State passages: [Passage]`, `@State marked: [Int: Date]`, `@State lastLoaded: String`. Body: `GeometryReader` → `PageMetrics.forPane(width:)` → `ScrollViewReader` → `ScrollView` → `LazyVStack(alignment: .leading, spacing: 0)` of one `MarkdownText(markdown: passage.source, base: url)` per passage, `.id(index)`, each padded to the measure and centred exactly as `DocumentView` does today, with the serif `.callout` face and `.textSelection(.enabled)`. A marked passage gets `.background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))` that animates to clear over 2 s from its `Date`.
- [X] T012 [US1] In `LivePage.swift`, add `.onChange(of: text)`: compute `PassageChange.between(old: lastLoaded, new: text)`, replace `passages`, set `marked[i] = .now` for each changed index, then if `!isEditing` and `first != nil`, `withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(first, anchor: .center) }` after the same 50 ms beat `FileLines` uses, and set `lastLoaded = text`. On first appearance: split, no marks, no scroll.
- [X] T013 [US1] In `LivePage.swift`, honour `line`: `.task(id: line)` — if `line != nil`, `Passage.index(containing: line, in: passages)` → scroll to it and mark it. This is FR-007's "a named line goes to the passage holding it" and it is what makes T015's routing safe.
- [X] T014 [US1] In `App/Sources/Sidebar/FilesPane.swift`, add a `@State private var lastText: String?` and make `reloadFile(_:)` keep the previous probe's text; in `fileView(_:)`, route `isMarkdown(url)` to `LivePage(text: probe.text ?? "", url: url, line: state.openLine, isEditing: false)` **whether or not `state.openLine` is set**, and update the "a line an agent named still wins" comment to say the page now has a passage for every line (FR-007). Everything else keeps `FileLines`.
- [X] T015 [US1] In `FilesPane.swift`, change the `FolderWatch` callback so that when the open file's re-read produces the **same** text, nothing is republished (a build touching a sibling file must not mark the page). Compare on the probe's text, not the file's date.
- [X] T016 [US1] Update `App/Sources/Sidebar/DocumentView.swift`'s doc comment: it is now the renderer `LivePage` was grown from, kept for the `Remote` target's use and for nothing on the Mac; if nothing on the Mac references it after T014, delete the Mac copy rather than leaving two.
- [X] T017 [US1] `xcodegen generate`, then `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build` and `swift test --package-path Packages/AgentsKit`. Both clean.
- [X] T018 [US1] **The gate.** Walk quickstart Slice A in the built app under `env -i … open -n … --args --root /tmp/agents-022`: an agent writes `notes.md` in four steps with `show_file` called first. Screenshot each step to `specs/022-live-artifacts/walk/A-<n>.png`. Then drag the sidebar to 900 pt and screenshot. Write what was seen at the foot of this file under "Slice A walk" — whether the page reads as paper, whether the marks land on the right passage, whether it follows, and whether it wants a window of its own. **Do not begin Phase 4 until this is written and Alex has seen the screenshots.**

**Checkpoint**: The page is live and follows. US1 is deliverable on its own.

---

## Phase 4: Slice B — attention (US1)

**Goal**: The one sentence the agent is given, and the measurement of whether it acts on it.

**Independent Test**: quickstart Slice B — "show me the Plan section" lands on that passage on the page; a line past the end lands on the last passage; a fresh conversation asked for a document opens the page by itself, or does not, and that is recorded.

- [X] T019 [P] [US1] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AppServiceTests.swift`, extend `everyToolIsListedWithASchemaTheAgentCanFill` (or add `theShowFileSchemaHasNotGrown`) to assert `show_file`'s `inputSchema.properties` has exactly the keys `path` and `line` and `required == ["path"]`, with a comment citing [contracts/show-file-tool.md](./contracts/show-file-tool.md): the schema is the contract and an argument added here is a contract change.
- [X] T020 [P] [US1] In `AppServiceTests.swift`, add a test that `show_file`'s description contains the phrases "opens as a page", "follows your edits" and "show it once", so the sentence cannot be edited away without the test saying so.
- [X] T021 [US1] In `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, replace `showFileTool`'s description with the four paragraphs in [contracts/show-file-tool.md](./contracts/show-file-tool.md) — the second paragraph is the whole change; the schema is not touched. Update the `showFile` reply in `DaemonCore+AppTools.swift` only if its wording no longer matches the contract's "Result text" (it should already).
- [ ] T022 [US1] Walk quickstart Slice B steps 1 and 2 in the built app. Record at the foot of this file whether the passage landed on was the right one.
- [X] T023 [US1] **Measurement.** Walk quickstart Slice B step 3 with Claude and with one of Grok, Copilot or Cursor: a fresh conversation, "write me a short design note as notes.md", nothing said about showing it. Fill the findings row "`show_file` called unasked at the start of a document" in `specs/022-live-artifacts/findings.md` per runtime.
- [X] T024 [US1] Only if T023 found no runtime calls it: add `public static let liveDocument` to `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift` with the sentence in the contract's "Briefing" section, append it in `Briefing.text(for:)` after `suggestions`, extend `BriefingTests.everyLineIsInTheBlockThatIsSent` and `itStaysShortEnoughToBeRead`, and re-run T023's measurement once. Record both results in the same findings row.

**Checkpoint**: Nothing the agent is given has changed but words, and the findings say whether words were enough.

---

## Phase 5: Slice C — typing on the page (US2)

**Goal**: Click a passage, type, pause; the file on disk holds it, written by the daemon; the page does not move.

**Independent Test**: quickstart Slice C — type a sentence, count two seconds, `cat` the file.

- [X] T025 [P] [US2] In `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, add `public static let artifactWrite = "artifact/write"` to `Method` beside `agentsShowFile`, and `public struct ArtifactWriteRequest: Codable, Sendable { public var agentID: UUID; public var path: String; public var text: String }` with a memberwise `public init`, doc-commented from [contracts/daemon-api.md](./contracts/daemon-api.md): called by a window for the person's edit; the daemon writes so it knows the person did.
- [X] T026 [P] [US2] In `ArtifactWriteTests.swift`, write the tests before the method exists: a write inside the agent's folder lands on disk byte-for-byte and replies; a write to a path outside `agent.folderScope` is refused with `invalidParams` and the scope's own refusal sentence, and nothing is written; a relative path is refused; an unknown `agentID` is refused with `noSuchAgent`; a write to a file that does not exist yet creates it; a write of the same text twice is not an error.
- [X] T027 [US2] Create `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Artifacts.swift` with `public func artifactWrite(_ request: DaemonAPI.ArtifactWriteRequest) async throws` implementing the contract's steps 1–3 and 5: look up the agent, check `agent.folderScope.allows(request.path)` and throw `scope.refusal(for:)` as `invalidParams` otherwise, read the previous text if the file exists, write with `Data.write(to:options: .atomic)`, reply. Step 4 (the note) is Phase 8. Until T026 passes.
- [X] T028 [US2] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, add `case DaemonAPI.Method.artifactWrite:` beside `agentsShowFile`, decoding `ArtifactWriteRequest` and replying with an empty object, following the shape of the neighbouring cases exactly.
- [X] T029 [US2] In `App/Sources/AppModel.swift`, add `func writeArtifact(agentID: UUID, path: String, text: String) async -> String?` that calls `client.call(DaemonAPI.Method.artifactWrite, DaemonAPI.ArtifactWriteRequest(...))` and returns the error's message on failure, nil on success, in the style of `signIn(runtimeID:methodID:)`.
- [X] T030 [US2] Create `App/Sources/Sidebar/PassageEditor.swift`: a `struct PassageEditor: View` with `@Binding draft: String`, `onCommit: () -> Void`, `onClose: () -> Void`. A `TextEditor(text: $draft)` in `.font(.system(.callout, design: .serif))`, `.scrollContentBackground(.hidden)`, no border, the same padding as a rendered passage so the text does not jump when it opens, `@FocusState` focused on appear, `onKeyPress(.escape)` → `onClose`, and a 1 s `Task`-based debounce on `draft` change → `onCommit`. Blur (focus lost) → `onCommit` then `onClose`.
- [X] T031 [US2] In `LivePage.swift`, add `@State editing: (index: Int, base: String, draft: String)?` and `@State saveProblem: String?`. Clicking a rendered passage (`.onTapGesture`, or a transparent `Button` if taps are eaten — see [[swiftui-card-taps-and-observation]]) sets `editing` with `base = passages[i].source`; that index renders `PassageEditor` instead of `MarkdownText`. `onCommit`: if `draft != base`, build the document with `Passage.join` over `passages` with `draft` at `index`, call `model.writeArtifact`, show `saveProblem` under the editor as small secondary text if it returns one, else set `base = draft`. `onClose`: commit if dirty, then `editing = nil`. Pass `isEditing: editing != nil` into the follow logic from T012 (FR-013).
- [X] T032 [US2] In `LivePage.swift`, when `text` changes while `editing != nil` **and** the change is exactly what was just written (the new text equals the last document handed to `writeArtifact`), do not mark anything and do not scroll: the person's own save coming back through FSEvents is not news.
- [X] T033 [US2] In `FilesPane.swift`, update the doc comment that says the pane is "read-only, deliberately and completely (FR-017)" to say that 022 makes one exception — a Markdown file on the page — and why (plan.md, Complexity Tracking). Pass `state.agentID` through to `LivePage` so it can call `writeArtifact`.
- [ ] T034 [US2] `xcodegen generate`, build both, run the package tests. Walk quickstart Slice C. Record at the foot of this file: whether the caret stayed where clicked when the editor opened, whether the text moved on open, the time from pause to `cat` showing it.

**Checkpoint**: The person can type on the page and the daemon writes it. US2's first half.

---

## Phase 6: Slice D — the merge (US2)

**Goal**: An agent's write landing while the person is mid-passage is combined with their text when elsewhere, and kept-with-a-card when it is the same passage. Nothing typed is ever lost silently.

**Independent Test**: quickstart Slice D — the agent rewrites another section mid-sentence, then the same section.

- [ ] T035 [US2] In `PassageMergeTests.swift`, write the tests before the type exists, each asserting the person's `edited` text appears in the result: theirs unchanged → `.merged` with the edit spliced at the same index; theirs changed a passage **before** mine → `.merged` and `passageIndex` shifted up by the number of passages added; theirs changed a passage **after** mine → `.merged` at the same index; theirs deleted a passage before mine → `.merged`, index shifted down; theirs rewrote my passage's lines → `.collided` with `theirs` equal to the agent's passage at that place and `text` holding mine there; theirs deleted my passage entirely → `.collided`, mine placed at the clamped index, `theirs` empty; theirs is the empty document → `.collided`, `text == edited`; my edit is identical to `base` (nothing typed) → `.merged` with `text == theirs`.
- [ ] T036 [US2] Add `public enum PassageMerge` to `Passage.swift` with `enum Result: Hashable, Sendable { case merged(text: String, passageIndex: Int); case collided(text: String, passageIndex: Int, theirs: String) }` and `static func apply(base: String, theirs: String, mine: Passage, edited: String) -> Result` per data-model.md: find `mine.source`'s lines as a contiguous run in `theirs` (first occurrence at or after the old position, else anywhere); if found, replace that run with `edited` and return `.merged`; otherwise find the passage of `theirs` containing `mine.lines.lowerBound` (clamped to the last), replace it with `edited`, and return `.collided` with that passage's source as `theirs`. Until T035 passes.
- [ ] T037 [US2] In `LivePage.swift`, in the `text` change handler when `editing != nil` (and the change is not the person's own save, T032): call `PassageMerge.apply(base: lastLoaded, theirs: text, mine: passages[editing.index], edited: editing.draft)`. On `.merged`: set `passages = Passage.split(result.text)`, `editing.index = passageIndex`, `editing.base = draft`, mark every changed passage **except** the editing one, do not scroll, and call `writeArtifact(result.text)` so disk holds both (FR-012). On `.collided`: the same, plus `collision = (index, theirs)`.
- [ ] T038 [US2] In `LivePage.swift`, add `@State collision: (index: Int, theirs: String)?` and, under the editor when set, a card: one line of secondary text "The agent changed this passage while you were typing. Yours is kept; theirs is below." then `theirs` rendered with `MarkdownText`, and two buttons — "Use theirs" (`draft = theirs`, commit, clear) and "Keep mine" (clear). The card is the `Button`'s content, not a `Button` inside a card ([[swiftui-card-taps-and-observation]]).
- [ ] T039 [US2] In `LivePage.swift`, when the file is gone (`FilesPane`'s `fileProblem` is set) while `editing != nil`: keep the editor and its draft on screen above the `Gone` message rather than unmounting it (spec edge case: "keeps the last content it had, so nothing the person typed is lost"). Route `fileProblem` into `LivePage` as an optional.
- [ ] T040 [US2] Build, test, walk quickstart Slice D steps 1–3. Record at the foot of this file: whether the caret held through a merge, whether the card appeared on the collision, whether the file held both after each step, and what an edit in another editor looked like on the page.

**Checkpoint**: Two writers, one page, nothing lost. US2 complete.

---

## Phase 7: Slice E — pictures (US4)

**Goal**: An SVG beside the document draws at its reference, and a redraw of the file is marked and followed though the document's text did not change.

**Independent Test**: quickstart Slice E — the agent draws a diagram as an SVG file, then changes it; a missing image shows its alternative text.

- [ ] T041 [P] [US4] In `PassageTests.swift`, write a test for `Passage.imageSources` (before it exists): a passage `![alt](./a.svg)` yields `["./a.svg"]`; a passage with two images yields both in order; a paragraph with none yields `[]`; an image inside a fenced block yields `[]`; `![alt](https://x/y.png)` yields it too (the page decides not to fetch, not the split).
- [ ] T042 [P] [US4] Add `public var imageSources: [String]` to `Passage` in `Passage.swift`: the destinations of `![...](...)` matches in `source` outside fences, by a single regex over the passage; no parsing of the alt text. Until T041 passes.
- [ ] T043 [US4] Create `App/Sources/Sidebar/ImageStamps.swift`: `struct ImageStamps` holding `[Int: Stamp]` where `Stamp` is `url: URL, modified: Date?, size: Int?, token: UUID`. `static func take(passages: [Passage], base: URL) -> ImageStamps` resolves each `imageSources` entry against `base` (file URLs only, `standardizedFileURL`, and only inside `base.deletingLastPathComponent()`'s tree — FR-019 says nothing outside is fetched) and reads `.contentModificationDateKey` and `.fileSizeKey`. `func refreshed() -> (ImageStamps, changed: IndexSet)` re-reads and bumps `token` where date or size differ.
- [ ] T044 [US4] In `LivePage.swift`, hold `@State images: ImageStamps`, rebuilt whenever `passages` change. Give each `MarkdownText` `.id(images[index]?.token)` so a bumped token reloads the picture. Add an `onFolderEvent` closure that `FilesPane` calls from its `FolderWatch` callback **even when the document's text is unchanged**: call `images.refreshed()`, mark every changed index, and follow the first under the same `isEditing` rule (FR-020).
- [ ] T045 [US4] In `FilesPane.swift`, pass the folder event through to `LivePage` (T044) alongside the existing re-read, so an SVG rewritten beside an unchanged document still reaches the page.
- [ ] T046 [US4] Check `App/Sources/Chat/MarkdownText.swift`'s `image(source:alt:)` against FR-019: a non-file URL already falls to the alt text; confirm a path resolving outside the document's folder also does (add the check if not — one `hasPrefix` on the standardized path), and that an SVG loads through `NSImage(contentsOf:)`. No other change to `MarkdownText`.
- [ ] T047 [US4] `xcodegen generate`, build, test, walk quickstart Slice E steps 1–3. Screenshot the redraw landing. Record at the foot of this file. Then walk step 4 with two runtimes and fill the findings rows "SVG images beside the document" and "A graph asked for: what the agent drew it as" in `findings.md`.

**Checkpoint**: Pictures are live. US4 complete.

---

## Phase 8: Slice F — telling the agent (US3)

**Goal**: The person's edits since the agent last wrote reach the agent as a block after their next words, and the agent builds on them.

**Independent Test**: quickstart Slice F — edit a paragraph, ask the agent to continue; its write keeps the edit; the daemon log shows the note.

- [ ] T048 [P] [US3] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift`, write tests for `Briefing.artifactEdited(_:)` before it exists, against the wording in [contracts/daemon-api.md](./contracts/daemon-api.md): one edit produces "Since your last turn I edited `<path>`. Lines 12–15 now read:" followed by the passage in a fence and the closing sentence; two edits to the same file produce one file line and two "Lines a–b now read:" blocks in document order; edits to two files produce two file paragraphs; twenty-one edits produce twenty blocks and "…and more. Read the file before changing it."; an empty list produces nil.
- [ ] T049 [P] [US3] In `ArtifactWriteTests.swift`, write the tests before the note exists: after one `artifact/write` that changes one passage, the agent's next `agents/prompt` sends the runtime a second text block after the person's words whose text is exactly `Briefing.artifactEdited` for that edit (read it off `launcher.lastAgent`'s prompt params the way `ShowFileTests` reads `newSessionParams`); the transcript's `userMessage` records only the person's words; a second prompt sends no note; two writes to the same passage before a prompt produce one block holding the later text; a write of identical text produces no note; a daemon restarted between the write and the prompt sends no note (in-memory by design — assert, do not fix).
- [ ] T050 [US3] Add `public struct ArtifactEdit: Hashable, Sendable { path: String; lines: ClosedRange<Int>; text: String; at: Date }` to `DaemonCore+Artifacts.swift` (daemon-side, not Core) and `var artifactEdits: [UUID: [ArtifactEdit]] = [:]` to `DaemonCore` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` beside `needsBriefing`, with the doc comment saying it is not persisted and why (data-model.md: the edit is on disk for the agent to read).
- [ ] T051 [US3] In `artifactWrite` (T027), implement contract step 4: `PassageChange.between(previous, text)`, one `ArtifactEdit` per changed index holding that passage's `lines` and `source`, coalesced by `path` + `lines` (later replaces earlier), capped at 20 per agent with the oldest dropped. Until the relevant T049 cases pass.
- [ ] T052 [US3] Add `public static func artifactEdited(_ edits: [ArtifactEdit]) -> String?` to `Briefing.swift` producing the contract's wording, grouped by path in first-seen order, blocks in `lines` order, the first 20 then the "…and more" line. Until T048 passes.
- [ ] T053 [US3] In `DaemonCore+Commands.swift` `beginTurn`, after the briefing append at the `needsBriefing` line: `if let note = Briefing.artifactEdited(artifactEdits[agentID] ?? []) { outgoing.append(.text(note)); artifactEdits[agentID] = nil }`. Only for `from == .person`? **No** — a workflow's prompt should carry it too; the agent needs to know either way. Until T049 passes.
- [ ] T054 [US3] Add `artifactEdits[agentID] = nil` wherever `dropAppTokens(for:)` is called on an agent's removal, so a deleted agent's notes do not linger.
- [ ] T055 [US3] Build, test, walk quickstart Slice F step 1 with Claude, and step 2 (an edit mid-turn) with every installed runtime. Fill the findings rows "The turn note reaching the agent", "The agent respecting the note" and "Mid-turn edit: runtime's own stale-file guard" per runtime in `findings.md`. If any runtime overwrote the person's mid-turn edit, write one paragraph under "What the real feature needs" saying so — that is the one place a real tool might earn its place.

**Checkpoint**: The agent is told. US3 complete.

---

## Phase 9: Slice G — findings (US5)

**Goal**: The written record that is the reason for the proof of concept.

**Independent Test**: every row of `findings.md`'s table has a status, an observation and a verdict; a reader who did not watch can say which tools the real feature needs.

- [ ] T056 [US5] Walk quickstart Slices A–F end to end with a second runtime (whichever of Grok, Copilot or Cursor was not used in T023), and fill the "Runtimes walked" table in `specs/022-live-artifacts/findings.md`.
- [ ] T057 [P] [US5] Fill the findings rows "The page following whole-file writes (line diff)" and "Marks placed on the right passage" from the Slice A and D walks, with counts (marks right / marks tried).
- [ ] T058 [P] [US5] Fill "The person's edit surviving an agent write elsewhere" and "The collision card" from the Slice D walk, against SC-004 and SC-005's numbers (fifty alternating edits; every collision).
- [ ] T059 [P] [US5] Fill "A 'what changed since I wrote' tool, callable mid-turn" from T055: needed, or not, per runtime, and why.
- [ ] T060 [P] [US5] Fill "Passage-level editing as the shape of editing" and "The sidebar as the page's home vs a window of its own" from the Slice A and C walks and from what Alex said at the gate.
- [ ] T061 [P] [US5] Fill "Finer-grained agent edits", "Mermaid written by an agent unasked" and "Inserting an image from the page" — each either observed or "not reached for, in N documents across M runtimes".
- [ ] T062 [US5] Write "Things that grated" and "What the real feature needs" in `findings.md`: each entry one or two sentences with the walk it came from. Set the file's status line to "walked, <date>".
- [ ] T063 [US5] Re-read `spec.md`'s SC-001 to SC-008 against the walks and write, at the foot of this file under "Success criteria", which held, which did not, and the number seen for each.

**Checkpoint**: The PoC has said what it learned. US5 complete; the feature is done.

---

## Phase 10: Polish

- [ ] T064 [P] Run `swift test --package-path Packages/AgentsKit` in a detached worktree at HEAD ([[three-lanes-one-tree]]) and confirm the only failures are the known flakes named in memory.
- [ ] T065 [P] Re-read every doc comment added in `Passage.swift`, `LivePage.swift`, `DaemonCore+Artifacts.swift` and `Briefing.swift` against the house rule that a comment says why, and cite the FR or research section each decision came from.
- [ ] T066 Update `README.md`'s "A file, shown" bullet: a Markdown file opens as a page that follows the agent's edits and can be typed on, and the person's edits are told to the agent on its next turn. Two sentences, no more.

---

## Dependencies

- Phase 1 → Phase 2 → Phase 3. **T018 is the gate**: Phases 4–9 do not start until it is written up and seen.
- Phase 4 (B) depends on Phase 3 only.
- Phase 5 (C) depends on Phase 3. Phase 6 (D) depends on Phase 5.
- Phase 7 (E) depends on Phase 3 only and can be built beside C and D.
- Phase 8 (F) depends on Phase 5 (it hangs off `artifactWrite`).
- Phase 9 (G) depends on everything, and T056 on the second runtime being signed in.

## Parallel Opportunities

- T002, T003, T004 together. T005, T006, T007 together (one file, but independent tests).
- After T018: Phase 4 and Phase 7 beside Phase 5.
- T019 and T020 together. T025 and T026 together. T041 and T042 together. T048 and T049 together.
- T057–T061 together once the walks are done.

## Implementation Strategy

Slice A alone is the MVP and is worth stopping at if it disappoints: a page that reads as paper and follows the agent is the whole of the first story, and if the sidebar turns out to be the wrong home the answer changes the rest. The two pure types come first in every slice, tested before written, because they are the only parts of this that can be proven rather than seen. The daemon changes are small and contract-shaped. The page is walked, screenshotted and written up at the end of every slice, and `findings.md` is filled as each measurement is taken rather than reconstructed at the end.

---

## Walk notes

*(Filled in as each slice's walk task is done.)*

### Slice A walk

*2026-09-23, in progress.* A scratch copy of the built app was launched against
`/tmp/agents-022` with a clean environment, a project at `/tmp/scratch-022`, and Claude asked
from the project page to write `notes.md` in four separate writes with `show_file` first.
It did exactly that — four writes and a `show_file` call, all in the transcript, and the
file on disk is the four-step document. The window stayed on the project page throughout,
so the pending `show_file` waited for the conversation to be opened (FR-009) and **the page
was never on screen during the agent's turn**. First observation for the findings: a
document started from the project page is written before anyone can watch, because the
conversation it belongs to is not the one on screen. Second observation: the agent called
`show_file` **before its first write**, as asked, and the daemon refused it because the file
did not exist yet ("There is no file at …") — so even with the conversation open the page
would not have appeared. The spec's edge case ("the file does not exist yet … the page opens
empty and fills") is not what the daemon does today; that is Slice B's first job.

Seen, once the conversation and the Files pane were opened by hand
(`walk/A-page-open.png`): the document on the paper surface, serif, title and three sections,
the pane at its default width, no chrome. It reads as a page. Not yet seen: the marks and the
follow, because the second prompt (four more writes) was typed while Alex was using the Mac
and never reached the agent. `walk/A-project-page-while-writing.png` is what the person saw
while the agent wrote: the project page, nothing live.

Still to see before the gate: four more writes with the page open — the tint landing on the
changed passage, the view moving to it, and the jump back to the first paragraph. The scratch
app is running against `/tmp/agents-022`; the conversation is open with Files showing
`notes.md`.

### Slice B walk

*2026-09-23.* The measurement (T023) was run over the scratch daemon's socket with the
window connected, once per runtime, before and after the briefing line: see the findings row.
The daemon change this walk needed first — a Markdown file may be shown before it exists —
is in `showFile` with its test. Step 1 of the quickstart, asked over the socket, produced no
`show_file` call at all: Claude read the file and pasted the Plan section into its reply.
So the visual half of step 1, and step 2 (a line past the end), are still to be seen on
screen, and T022 stays open for that.

### Slice C walk

*2026-09-23.* Code built and 1065 tests pass, including four for `artifact/write`. The
walk itself (T034: click, type, pause, `cat`) is not done: Alex was at the Mac and my
clicks land in whatever window is in front. Left open until the Mac is free or Alex walks
it. What to look for is in the quickstart; what I am unsure of is whether a click on a
rendered passage reaches `onTapGesture` through `textSelection(.enabled)` on the scroll
view above it — if it does not, the passage becomes a `Button` and the walk says so.

### Slice D walk

### Slice E walk

### Slice F walk

### Success criteria
