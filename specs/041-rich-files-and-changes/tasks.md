# Tasks: Code That Reads Like Code, in Files and Changes

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/codetext.md](contracts/codetext.md), [quickstart.md](quickstart.md)

**Tests**: Included. The contract lists six invariants to be tested, and the plan asks for the
diff logic to be written test first. Every pure-logic test lives in `CT/Tests/CodeTextTests/` and
runs with `swift test` in `CT/`. Views are proven by run-app walks and screenshots.

**Where**: Everything runs in the worktree `.agents/worktrees/041-rich-files-and-changes` on
branch `041-rich-files-and-changes`. Never edit the shared checkout at
`/Users/alexcollins/Agents`. Paths are relative to the worktree. `CT/` stands for
`Packages/CodeText/`. The R1 spike (grammar clones in `/tmp/041-spike/grammars/src-*`, inputs in
`/tmp/041-spike/inputs/`) may be reused. If `/tmp` has been cleared, `scripts/vendor-grammars.sh`
fetches again.

**Gates**:
- **T024, the look (after US1's first coloured file)**: run-app screenshots of the files pane
  in Light and Dark. **Stop for Alex's look** before any more languages or diff work (see
  memory: settle the UX before building depth). Palette hex values change here, not later.
- **T043, the diff look**: screenshots of a one-word edit and a folded edit, in the conversation
  and in Changes. Show Alex before Whole file.

**Rules that apply everywhere**:
- Change is shown by mark, weight, strike and a neutral wash, never red and green (035 FR-013).
  `CodeInk` has no red, orange or pink role.
- `agentsd` and `AgentsKit` never link `CodeText`.
- Text is never altered by colour: marks and line numbers stay outside the selectable line
  `Text` (FR-006).
- The window never polls `daemon.sock` (see memory: daemon socket polling exhausts descriptors).
- Build the `Agents` and `Remote` schemes one after the other, with plugin validation skipped
  (see memory: xcodebuild).
- Colour work happens off the main actor. The main actor only builds `AttributedString`s for
  rows on screen.

## Phase 1: Setup

- [ ] T001 Bring the branch up to date and record a baseline:
  - Merge `main` into `041-rich-files-and-changes` and verify it with `git merge-base` (see memory: a branch can move under a merge).
  - Run `swift test` in `Packages/AgentsKit` once, and write the count and any failures into this task. Known flakes on main: BlockedTests twoHelpers, aPickedUpAgentKeepsTheCommands, WorktreeStart.
  - Build `Agents`, then `Remote`, and note both results here.
- [ ] T002 Create the package `CT/Package.swift` (tools 6.2, platforms `.macOS("27.0")`, `.iOS("27.0")`):
  - Dependency: `https://github.com/tree-sitter/swift-tree-sitter` from `0.25.0`, product `SwiftTreeSitter`.
  - Product: library `CodeText`, target `CodeText` (Swift, depends on `SwiftTreeSitter` and every grammar target), with `resources: [.copy("Queries")]`.
  - Test target `CodeTextTests` with `resources: [.copy("Samples")]`.
  - Grammar targets are added by T004. Put a header comment in the same voice as `Packages/AgentsKit/Package.swift`, saying why this is a separate package: `agentsd` must not carry 17 MB of parsers (plan: Structure Decision).
- [ ] T003 Write `scripts/vendor-grammars.sh <name|all>`, which reads the table at the top of the script:
  - Columns: name, repo, tag or commit, subdirectory, query files in order.
  - For each grammar it:
    - shallow-clones the repo at the pin into a temp dir;
    - copies `parser.c`, `scanner.c` if present, and `tree_sitter/` into `CT/Grammars/TS<Name>/`;
    - writes `CT/Grammars/TS<Name>/include/ts_<name>.h` declaring `const TSLanguage *tree_sitter_<name>(void);` (with `typedef struct TSLanguage TSLanguage;`);
    - concatenates the listed query files, in order, into `CT/Sources/CodeText/Queries/<name>.scm`.
  - Rewrite `#include "../../common/scanner.h"` to a local copy (TypeScript/TSX).
  - Pins and query orders come from research R2 and these tree-sitter.json facts:
    - cpp = c `highlights.scm` + cpp `highlights.scm`
    - typescript = ts `highlights.scm` + javascript `highlights.scm`
    - tsx = ts `highlights.scm` + javascript `highlights-jsx.scm` + javascript `highlights.scm`
    - javascript = `highlights-jsx.scm` + `highlights.scm`
    - make is pinned to commit `a4b9187`
    - markdown = `tree-sitter-markdown/` block grammar only.
- [ ] T004 Wire the grammar targets in `CT/Package.swift`: one `.target(name: "TS<Name>", path: "Grammars/TS<Name>", cSettings: [.headerSearchPath("."), .unsafeFlags(["-w", "-Os"])])` per vendored grammar, listed from one array so adding a language is one line (FR-020). Check `-Os` is accepted for a package dependency in Xcode. If not, drop it and note the size difference at T058.
- [ ] T005 [P] Write `CT/Grammars/VENDORED.md`: for each of the 20 grammars, the repo, pin, licence (read from the repo's LICENSE), compiled KB from research R1, and the extensions it covers. Also record that SQL and Kotlin are left out and why (research R1, R2).
- [ ] T006 Add `CodeText` to `project.yml`:
  - Under `packages:` as `path: Packages/CodeText`.
  - As a dependency of the `Agents` and `Remote` targets only, with a comment in the file's voice saying `agentsd` must not link it.
  - Run `xcodegen generate` and build both schemes.
- [ ] T007 Add a check, `scripts/check-agentsd-links-no-parsers.sh`:
  - It fails if `project.yml`'s `agentsd` target lists `CodeText`.
  - It fails if `nm` on the built `agentsd` shows any `tree_sitter_` or `ts_parser_` symbol.
  - Run it now, and again at T060.

## Phase 2: Foundational (blocks every story)

Vendor the five grammars the look gate needs first, `swift python javascript typescript json`,
with `scripts/vendor-grammars.sh`. The other 15 come in T025.

**Tests first. Each must fail before its code exists.**

- [ ] T008 [P] `CT/Tests/CodeTextTests/LanguageTests.swift`: `CodeLanguage.detect(path:firstLine:)` tries exact name, then extension, then `#!`.
  - Cases: `a.swift`→swift; `A.SWIFT`→swift; `x.m`→c; `x.mm`→cpp; `x.h`→c; `x.tsx`→tsx; `x.jsx`→javascript; `Dockerfile`→dockerfile; `Makefile`→make; `x.mk`→make; `Gemfile`→ruby; `.zshrc`→bash; a name with no extension and first line `#!/usr/bin/env python3`→python; `#!/bin/zsh`→bash.
  - Unknowns give nil: `x.kt`, `x.sql`, `x.xyz`, a name with no extension and no `#!`.
  - `fence(tag:)`: `ts`→typescript; `py`→python; `sh`/`shell`/`zsh`→bash; `yml`→yaml; `objc`/`objective-c`→c; `swift {.line-numbers}`→swift (drop after the first space or `{`); `""`/nil/`text`/`sql`→nil.
- [ ] T009 [P] `CT/Tests/CodeTextTests/RoleTests.swift`: `CodeRole.role(forCapture:)` is total and follows data-model.md.
  - `keyword.return`→keyword; `string.special`→string; `comment.documentation`→comment; `number`/`constant.builtin`/`boolean`→number; `type.builtin`→type; `function.method`→function; `property`/`attribute`→property; `operator`/`punctuation.bracket`→punctuation; `variable.builtin`→keyword; `variable`, `label` and `""`→plain.
  - Every capture name in every vendored `Queries/*.scm` maps without trapping; parse the `@name` tokens from the files.
- [ ] T010 [P] `CT/Tests/CodeTextTests/ColourerTests.swift`, for each vendored language with a sample in `CT/Tests/CodeTextTests/Samples/sample.<ext>` (50–150 lines of real-looking code, including a string, comment, number, type and function):
  - (a) Spans on each line don't overlap and lie within the line.
  - (b) **Text is untouched** (contract invariant 1): build the per-line `AttributedString` the way `CodeLine` will, with a helper in the package, `CodeText.attributed(line:spans:)` using plain `foregroundColor` placeholders. Joining `String(characters)` over the lines equals the input.
  - (c) The Swift sample has at least one each of keyword, string, comment, number and type.
  - (d) A half-written file (the sample cut mid-string) still gives spans and no crash.
- [ ] T011 [P] `CT/Tests/CodeTextTests/LimitTests.swift` (contract invariant 5): text of 512 KB + 1 gives `plainBecause == .tooLarge` and no spans; a 4,001-character line anywhere gives `.lineTooLong`; the constants equal research R6's.

**Implementation**

- [ ] T012 `CT/Sources/CodeText/Language.swift`: `CodeLanguage` with all 20 cases (contract), plus its `extensions`, `fileNames`, `interpreters` and `fenceTags` tables (data-model.md), `detect` and `fence`. Unknown gives nil: "It is never guessed from content beyond the `#!` line." Makes T008 pass.
- [ ] T013 `CT/Sources/CodeText/CodeRole.swift`: the role enum and its mapping table. Makes T009 pass.
- [ ] T014 `CT/Sources/CodeText/Limits.swift`, public constants:
  - `colourMaxUTF16 = 512 * 1024`
  - `colourMaxLine = 4_000`
  - `wordMarkMaxLine = 1_000`
  - `wordMarkMaxPairs = 200`
  - `foldMinimum = 8`
  - `foldContext = 3`
  - `window = 200`

  Plus `PlainReason` and `static func plainReason(for text: String) -> PlainReason?`.
- [ ] T015 `CT/Sources/CodeText/Grammar.swift`: `language → SwiftTreeSitter.Language` via each `tree_sitter_<name>()`, and `query(for:) async throws -> Query`, compiled from `Bundle.module`'s `Queries/<name>.scm` on first use and cached in an actor for the process lifetime (research R8). A query that fails to compile logs once and gives nil, and the language is then shown plain; it never crashes.
- [ ] T016 `CT/Sources/CodeText/Colourer.swift`: an `actor Colourer` holding one `Parser` and `MutableTree` per document id.
  - `parse(id:text:language:)`
  - `edit(id:newText:)`: common prefix/suffix gives one `InputEdit`, then `tree.edit`, then reparse with the old tree (research R7).
  - `spans(id:lines: Range<Int>, lineStarts: [Int]) -> [[CodeSpan]]`: run the query with `cursor.setRange` over those lines' UTF-16 range, `resolve(with: .init(string:))`, `.highlights()`, map to roles, drop `plain`, split multi-line captures at line ends, resolve overlaps by letting the later (more specific) capture win over its range, and shift ranges to line-relative UTF-16.
  - `forget(id:)`.

  Makes T010 pass.
- [ ] T017 `CT/Sources/CodeText/CodeDocument.swift`: a `@MainActor @Observable` class per the contract.
  - `init(text:language:)` splits lines once and sets `plainBecause` from `Limits`. If it has a language and no limit, it starts a parse on the `Colourer`.
  - `appear(line:)` requests window `line / Limits.window` and the one after, once each.
  - `spans(line:)` reads from `windows`.
  - `update(text:)` diffs against the old text, calls `Colourer.edit`, and drops only the windows overlapping the changed line range.
  - `deinit`/`close()` forgets the id.
  - Add `os_signpost` intervals `parse` and `firstWindow` under subsystem `com.alexecollins.Agents`, category `CodeText`, for SC-001.
- [ ] T018 [P] `Shared/UI/CodeInk.swift`: nine roles, with `Color(light:dark:)` hex beside `Paper`, per research R4:
  - comment a muted warm grey, italic
  - keyword deep ink blue, semibold
  - string dark olive
  - number plum
  - type teal
  - function slate blue
  - property brown
  - punctuation `.secondary`

  Also `removedWash` (about 6% ink) and `changedWash` (about 14% ink). A header table in the same form as `Paper.swift`'s. No hue within 30° of red above 40% saturation.
- [ ] T019 [P] `CT/Tests/CodeTextTests/PaletteContrastTests.swift` (SC-007):
  - Mirror `CodeInk`'s hex values in `CT/Sources/CodeText/InkValues.swift` (the numbers only, so the test runs under `swift test`).
  - Have `Shared/UI/CodeInk.swift` read from it, via `import CodeText`.
  - Compute the WCAG relative-luminance contrast of each role against `Paper.ground` (`FBF9F4`/`1C1B19`) and `Paper.well` (`F1EDE4`/`2A2825`), and require ≥ 4.5 in both appearances.
  - Assert the no-red hue rule.

**Checkpoint**: `swift test` in `CT/` is green, both schemes build, and nothing is drawn differently yet.

## Phase 3: User Story 1 — A file reads like code (P1) 🎯 MVP

**Goal**: The files pane colours code on the Mac and phone, text first and colour after.

**Independent test**: Open one sample per vendored language in the files pane. Each is coloured,
`notes.xyz` is plain, and line numbers, wrapping and the named line are unchanged.

- [ ] T020 [US1] `Shared/UI/Code/CodeLine.swift`: a view that builds one `Text` from a line's `Substring` and `[CodeSpan]`, applying `CodeInk` colour, weight and italic per role, with `.appText(.code)`. Built so it can later take `changed: [Range<Int>]` and a `kind` (T034); for now, plain rows only. Empty line → `" "` as today.
- [ ] T021 [US1] Change `Shared/UI/Page/FileLines.swift`:
  - Add `path: String? = nil`, keep the existing init working, and create a `@State CodeDocument` from `text` and `CodeLanguage.detect(path:firstLine:)`.
  - Each row calls `document.appear(line:)` in `.onAppear` and draws `CodeLine`.
  - When `text` changes for the same path, call `document.update(text:)` instead of rebuilding.
  - Keep everything else as it is: the gutter widths, the "Line N is past what is shown here." line, `keepsPlace`, the scroll-to-line `task(id:)`, the named-line tint, `textSelection(.enabled)`.
  - When `plainBecause` is set, show one `.appText(.fine)`, `.secondary` line above the rows: "Shown without colour: the file is too large." or "Shown without colour: a line is too long." (research R6).
- [ ] T022 [US1] Pass the open file's path to `FileLines` in `App/Sources/Sidebar/FilesPane.swift` (the `.text` case, around line 203) and `Remote/Sources/Panes/FilesPane.swift`.
- [ ] T023 [US1] Run `CT` tests, and build `Agents` then `Remote`.
- [ ] T024 [US1] **Look gate.** Use the run-app skill on a scratch root (see memory: drive the scratch app only when Alex is away):
  - Put `CT/Tests/CodeTextTests/Samples/*` and a `notes.xyz` in the scratch project.
  - Open `sample.swift`, `sample.py`, `sample.ts` and `sample.json` in Files.
  - Screenshot each in Light and Dark (the Paper setting) into `specs/041-rich-files-and-changes/walk/01-*.png`.
  - Check there is no red, the numbers are unchanged, `notes.xyz` is plain, and copying a line gives plain text.
  - **Stop and show Alex.** Record his palette changes here and apply them to `InkValues.swift` before going on.
- [ ] T025 [US1] Vendor the remaining 15 grammars with `scripts/vendor-grammars.sh all`:
  - c, cpp, go, rust, java, ruby, bash, yaml, toml, html, css, markdown, dockerfile, make, tsx.
  - Add a sample file for each to `CT/Tests/CodeTextTests/Samples/`.
  - T008–T010 now cover all 20 languages (SC-006). Fix any query that fails to compile against its grammar version by pinning the query to the same tag, never by editing the grammar.
- [ ] T026 [US1] Live text (US1 AS5, FR-007):
  - Add a test in `CT/Tests/CodeTextTests/IncrementalTests.swift`: append 100 lines, one at a time, to a Swift document. After each `update`, the spans for untouched lines equal a fresh parse's, and only windows overlapping the changed lines were dropped.
  - Then walk it on scratch: an agent writes a long Swift file while it is open in Files, the colour follows, and the place is kept. Screenshot `walk/02-live.png`.
- [ ] T027 [US1] [P] Accessibility: rows keep their plain text as the accessibility label, so VoiceOver reads the code, not the colour. Check with Accessibility Inspector on the scratch window.

**Checkpoint**: US1 is complete and shippable alone. Files are coloured on the Mac and phone.

## Phase 4: User Story 2 — An edit shows what changed (P1)

**Goal**: Every edit is a real line diff with word marks and folds, coloured, in the
conversation, Changes, the phone's changes sheet and the permission sheet.

**Independent test**: A one-word change in a 40-line passage shows at most 10 lines, one
removed and one added, with the word washed on both. A new file is all added.

**Tests first**

- [ ] T028 [P] [US2] `CT/Tests/CodeTextTests/LineDiffTests.swift` for `LineDiff.rows(old:new:)`:
  - (a) Identical texts give all context.
  - (b) One changed line in 40 gives 39 context rows, one removed and one added, with the removed row before the added one.
  - (c) old nil gives all `.added`, no `changed`.
  - (d) A pure insertion gives no `.removed`.
  - (e) Round-trip (contract invariant 3): context + removed rows rebuild old, and context + added rows rebuild new, for 200 random edit pairs from a seeded generator over the Swift sample.
  - (f) Trailing newline differences survive the round-trip.
- [ ] T029 [P] [US2] `CT/Tests/CodeTextTests/WordDiffTests.swift`:
  - `let total = 10` → `let total = 12` marks only `10`/`12`.
  - An indentation-only change marks the leading whitespace.
  - Two lines sharing fewer than a third of their tokens get no `changed`.
  - A 1,001-character line gets no `changed`.
  - A block of 201 pairs gets none.
  - Pairing is removed *i* ↔ added *i* within a change block, with the unmatched remainder unpaired.
  - Ranges are UTF-16 and valid on lines with emoji and combining marks.
- [ ] T030 [P] [US2] `CT/Tests/CodeTextTests/FoldTests.swift` for `Folds.of(_:context:minimum:)`:
  - A run of 8 context rows is not folded; a run of 9 between changes folds to 3 + fold + 3.
  - A leading run keeps 3 only before the first change, and a trailing run keeps 3 only after the last.
  - All-added rows give no folds.
  - Folds never cover a non-context row, nor one within 3 of a change (contract invariant 4).

**Implementation**

- [ ] T031 [US2] `CT/Sources/CodeText/LineDiff.swift`: `DiffRow` per the contract, and `rows(old:new:)` via `new.split(…omittingEmptySubsequences: false).difference(from: old…)`, walked in order into rows (research R5). Makes T028 pass.
- [ ] T032 [US2] `CT/Sources/CodeText/WordDiff.swift`:
  - Tokenise into identifier runs (letters, digits, `_`), whitespace runs and single other characters.
  - Diff the tokens with `CollectionDifference`, and turn the removed and inserted token offsets into UTF-16 ranges.
  - Skip when shared tokens are under 1/3 of the longer line's tokens, or past `Limits`.
  - `LineDiff` calls it for each pair. Makes T029 pass.
- [ ] T033 [US2] `CT/Sources/CodeText/Folds.swift`: `Fold`, and `Folds.of`. Makes T030 pass.
- [ ] T034 [US2] Extend `Shared/UI/Code/CodeLine.swift` with `kind` and `changed`:
  - Syntax colour stays underneath (US2 AS5).
  - Removed rows are struck through with tertiary opacity, as 035 did.
  - Added rows are semibold, as 035 did.
  - The whole row sits on `CodeInk.removedWash` for removed rows and none for added. Changed ranges sit on `changedWash` on both sides.
  - The mark column (`+`, `−`) and the line number are separate `Text`s outside the selectable line.
  - Accessibility label prefix: "Added: " / "Removed: ".
- [ ] T035 [US2] `Shared/UI/Code/FoldRow.swift`: "↕ N unchanged lines" in `.appText(.fine)`, `.secondary`, as a `.plain` `Button` that is the whole row (see memory: SwiftUI card taps). Opening it replaces the fold with its rows in place, without moving what is above.
- [ ] T036 [US2] `Shared/UI/Code/CodeRows.swift`: a lazy stack over `[DiffRow]` plus folds (open state in `@State Set<Int>`) plus a `CodeDocument` for colour.
  - Colour the new side's lines by parsing the new text, and the removed lines by parsing the old text, as two documents keyed by side.
  - Each row calls `appear`.
  - Used by T037 and T046.
- [ ] T037 [US2] Rewrite the body of `DiffView` in `Shared/UI/Chat/ChatBlocks.swift`:
  - Draw with `CodeRows(LineDiff.rows(old: diff.oldText, new: diff.newText), language: CodeLanguage.detect(path: diff.path, firstLine: nil))`.
  - Keep the signature, `maxHeight` (280 in the conversation, nil in Changes), `showsPath`, `paperWell` and horizontal scrolling for long lines.
  - Delete the old `lines` builder and its "Not a real diff algorithm" comment.
- [ ] T038 [US2] Check every `DiffView` caller: `Shared/UI/Chat/TranscriptRows.swift:345`, `App/Sources/Sidebar/ChangeFileView.swift:250`, `Remote/Sources/Chat/ChangesView.swift:101`, `Remote/Sources/Permission/PermissionSheet.swift:59`. All still compile and need no change. Note here any that needed one.
- [ ] T039 [US2] Keep 035's `ChangeFileView.drawLimit` gate as it is, in front of the new rows. Confirm "N lines changed in M edits" + Show changes still appears for a 2,001-line change.
- [ ] T040 [US2] Build `Agents` then `Remote`, and run `CT` tests.
- [ ] T041 [US2] Measure SC-004 in a test in `CT/Tests/CodeTextTests/LineDiffTests.swift`: a one-word change in a 40-line passage gives at most 10 visible rows after folding (3 + 1 + 1 + 3 + two folds).
- [ ] T042 [US2] Walk on scratch with a real Claude agent (quickstart §4):
  - Ask it to change one word in the middle of a 40-line function in `sample.swift`.
  - Ask it to add a new function to `sample.py`.
  - Screenshot the conversation and Changes in Light and Dark into `walk/03-*.png`.
- [ ] T043 [US2] **Diff look gate.** Show Alex T042's screenshots, and record his changes to the wash strengths or marks here.

**Checkpoint**: US1 and US2 are complete. This is the MVP.

## Phase 5: User Story 3 — Whole file goes straight to what changed (P2)

**Goal**: Whole file folds long unchanged runs, and Next/Previous move between changes.

**Independent test**: Two changes 400 lines apart show with folds between them. Next moves to
the second.

- [ ] T044 [P] [US3] Tests in `CT/Tests/CodeTextTests/LineDiffTests.swift` for `LineDiff.rows(whole:)`:
  - Kinds and `newLine` are carried through unchanged.
  - Removed/added pairs in a change block get `changed`.
  - `LineDiff.changeStops(_:)` gives the first row index of each change block.
- [ ] T045 [US3] Implement `rows(whole:)` and `changeStops` in `CT/Sources/CodeText/LineDiff.swift`.
- [ ] T046 [US3] Replace `WholeLine` and the `wholeFile` body in `App/Sources/Sidebar/ChangeFileView.swift`:
  - Map `[DiffLine]` to the tuple input at the call site.
  - Draw with `CodeRows` and folds, with the line number column kept as 035 has it (40 pt, `.quaternary`, blank for removed rows; FR-013).
  - Keep the draw-limit gate and the `wholeProblem`/progress states.
- [ ] T047 [US3] Add Previous and Next change buttons (`chevron.up` / `chevron.down`, `.borderless`, `.help("Previous change")` / `.help("Next change")`) to `ChangeFileView`'s header, shown only in Whole file:
  - They scroll the `ScrollViewReader` to the stop above or below the current one.
  - A stop inside a closed fold opens it first.
  - They are disabled at the ends.
- [ ] T048 [US3] Walk on a git scratch project (quickstart §4 step 3). Screenshot `walk/04-whole.png`, then Next, then `walk/05-whole-next.png`.

## Phase 6: User Story 4 — Code in the conversation and pages matches (P3)

**Goal**: Fenced blocks are coloured by their tag, in the same palette.

**Independent test**: Tagged `swift`, `ts` and `py` blocks are coloured; untagged and `text` blocks are plain.

- [ ] T049 [US4] Change the `.code(language, text)` case in `Shared/UI/Page/MarkdownText.swift`:
  - Draw the block's lines with `CodeLine` and a `CodeDocument` from `CodeLanguage.fence(tag: language)`.
  - Keep the language label, horizontal scroll, `paperWell`, `textSelection` and the caret trailing behaviour (`self.text(…, caret:)`). If the caret needs the block to stay one `Text`, build one `AttributedString` for the whole block from the per-line spans instead of rows.
- [ ] T050 [US4] Walk: ask an agent for three fenced blocks (`swift`, `ts`, `py`) and one untagged. Screenshot the conversation and the same blocks in a page (`show_file` on a `.md` scratch file) into `walk/06-fences.png`.

## Phase 7: User Story 5 — The same on the phone and the iPad (P3)

**Goal**: The phone and iPad draw everything above the same way, within SC-001's phone limit.

**Independent test**: The same file, edit and fence as on the Mac match on both devices.

- [ ] T051 [US5] Build `Remote` for a device, and install on the iPhone, then the iPad, one at a time (see memory: real iPhone and iPad; it replaces Alex's own Remote, so ask him first).
  - Open `sample.swift` in Files, the T042 edit in Changes, and T050's fences.
  - **Ask Alex to look early**, and record what he sees here.
- [ ] T052 [US5] Time the phone with the T017 signposts. Open `swift5k.swift` (copied from `/tmp/041-spike/inputs/` into the scratch project), and record `firstWindow` from Console, filtered to subsystem `com.alexecollins.Agents`, category `CodeText`. It should be under 1 s (SC-001).

## Phase 8: Polish and proof

- [ ] T053 [P] Limits walk (SC-005, quickstart §5): open a 294 KB single-line `long.js` and a 20 MB `big.json` on scratch. Both show plain within a second with the reason line, and the app stays responsive. Sample the process if not (see memory: waitUntilExit / sample a silent hang first).
- [ ] T054 [P] Mac timing (SC-001, SC-002): open `swift5k.swift` and record the `firstWindow` signpost with `xctrace` or `/usr/bin/log` (see memory: zsh `log`). It should be under 0.5 s. Record a scroll top to bottom with Instruments' SwiftUI template, against the same file on main plain. Write the load average beside the numbers.
- [ ] T055 [P] Acknowledgements: add tree-sitter's and each grammar's licence notice to the apps' acknowledgements, beside any existing ones. If none exist, add `App/Resources/Acknowledgements.md` and `Remote/Resources/Acknowledgements.md` with the notices, generated from `CT/Grammars/VENDORED.md`.
- [ ] T056 Full test run: `swift test` in `CT/` and in `Packages/AgentsKit`. Compare against T001's baseline, and judge flakes by six runs, not one (see memory: the suite is broadly flaky under load).
- [ ] T057 Build `Agents` then `Remote` in Release.
- [ ] T058 Size (SC-003, quickstart §7): `du -sk` and `ditto -c -k` sizes of Release `Agents.app` and `Remote.app` against main's Release build. It should be at most +20 MB installed and +5 MB compressed. Record the numbers in research.md under R1.
- [ ] T059 Run quickstart.md §1–§7 end to end on the finished branch, with screenshots in `walk/`. Write `specs/041-rich-files-and-changes/walk/README.md` listing what was seen and what is Alex's (phone and iPad looks).
- [ ] T060 Rerun `scripts/check-agentsd-links-no-parsers.sh` on the Release build.
- [ ] T061 Update the spec's Status to "Implemented", update the 041 line in the memory spec queue with the head commit and what is left, and commit. Don't merge into main until Alex says it's this lane's turn (see memory: main checkout is only main).

## Dependencies

- **Setup (T001–T007)** comes before everything. T003 comes before T004, and T006 before any view work.
- **Foundational (T008–T019)** blocks every story. The tests T008–T011 and T019 come before their implementations T012–T018.
- **US1 (T020–T027)**: T020 → T021 → T022 → T023 → **T024 gate** → T025, T026, T027.
- **US2 (T028–T043)** needs Foundational and T020 (`CodeLine`), and should wait for the T024 gate, since the palette may change. T028–T030 → T031–T033 → T034–T036 → T037 → T038–T042 → **T043 gate**.
- **US3 (T044–T048)** needs US2's `CodeRows` and `Folds` (T033, T036).
- **US4 (T049–T050)** needs only Foundational and T020, so it can run beside US2 or US3.
- **US5 (T051–T052)** needs whatever it walks: US1 at least. Best done after US2 and US4.
- **Polish (T053–T061)** comes after the stories it proves.

## Parallel examples

- Foundational tests: T008, T009, T010, T011 and T019 are separate files and can be written together.
- T012, T013, T014 and T018 are separate files once their tests exist.
- US2 tests: T028, T029 and T030 together, then T031, T032 and T033 together.
- After the T043 gate, US3 (T044–T048) and US4 (T049–T050) touch different files and can go together.
- Polish: T053, T054 and T055 together.

## Implementation strategy

1. **MVP is US1 plus the T024 look gate.** Colour in the files pane is the first thing Alex sees
   and the thing every later view reuses. Stop at the gate.
2. **Then US2**, the other P1: it answers 035's question. Stop at T043.
3. **Then US3 and US4 in either order, then US5 on the devices**, and polish last.
4. Every phase ends with both schemes building and `CT` green, so the branch can pause at any
   checkpoint without leaving anything half-drawn.
