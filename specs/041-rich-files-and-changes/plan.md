# Implementation Plan: Code That Reads Like Code, in Files and Changes

**Branch**: `041-rich-files-and-changes` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/041-rich-files-and-changes/spec.md`

## Summary

Code is drawn as plain monospaced rows in five places: `FileLines` (files pane, Mac and phone),
`DiffView` (edits in the conversation, the Changes pane, the phone's changes and permission
sheets), `WholeLine` (035's Whole file), and fenced blocks in `MarkdownText`. This feature gives
all of them one engine and one look:

- **Colour** from tree-sitter, used directly through `swift-tree-sitter`. There are 20 grammars,
  vendored as C sources and pinned by tag. The text is parsed off the main actor and only the
  lines on screen are queried: 1–3 ms per screen after a 13–83 ms parse of a 5,000-line file
  (research R1). Text shows plain first, and colour follows.
- **Diffs** from the standard library's `CollectionDifference`: a line diff of each edit's old
  and new text, then a word diff inside each removed/added pair. The Whole file gets the same
  word marks over the `DiffLine`s the daemon already sends.
- **Folds** over long unchanged runs, and next/previous change in Whole file.
- **One palette**, `CodeInk`, beside `Paper` in `Shared/UI`. It has nine roles, light and dark,
  no reds, and all nine are checked against 4.5:1 contrast.

All of it lives in a new local package, `Packages/CodeText`, that the Mac app and the Remote
link and `agentsd` does not. The daemon and its protocol don't change.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency, complete), C11 for the vendored grammars.

**Primary Dependencies**: `tree-sitter/swift-tree-sitter` 0.25.0 (MIT; pulls the tree-sitter C
runtime). 20 grammar C sources vendored under `Packages/CodeText/Grammars/` (MIT/Apache, listed
with tag and licence in `Grammars/VENDORED.md`). Nothing else. Neon is not used: it drives
`NSTextView`/`UITextView`, and our code is drawn as SwiftUI rows.

**Storage**: None. Compiled highlight queries are cached in memory, one per language per launch.

**Testing**: `swift test` in `Packages/CodeText` (language detection, capture→role mapping,
spans never alter text, line/word diff, folds, limits, palette contrast). The existing
AgentsKit suite must stay green. Both schemes must build (`Agents`, `Remote`), sequentially,
with plugin validation skipped. The look is walked on a scratch root with the run-app skill.

**Target Platform**: macOS 27 and iOS/iPadOS 27, arm64.

**Project Type**: Desktop and mobile app plus a local Swift package.

**Performance Goals**: The first coloured screen of a 5,000-line file in under 0.5 s on the
Mac and 1 s on the phone (SC-001), with the text itself not waiting at all (FR-017). Scrolling
no worse than plain (SC-002). An edit to a file an agent is writing is reparsed incrementally.

**Constraints**: At most 5 MB of download and 20 MB installed added per app (SC-003; the
measured figures are 1.9 MB and about 17 MB). No network, no web view, no JavaScript (FR-016).
Colour is skipped past 512 KB of text or any line over 4,000 characters, and word marks are
skipped for a line over 1,000 characters or a change block over 200 lines (FR-018; R6).

**Scale/Scope**: 20 grammars. Code is drawn by six views: `FileLines`, `DiffView`,
`WholeLine`/`ChangeFileView`, `MarkdownText`'s code case, and the Remote's `ChangesView` and
`PermissionSheet` through `DiffView`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled template, so it has no ratified gates.
The project's standing rules take its place:

| Rule | How this plan meets it |
|---|---|
| Settle the UX before building depth | Phase A is the look: palette plus colour in `FileLines`, walked on a scratch root and shown to Alex before any diff machinery (look gate). |
| Every lane in its own worktree | Built in `.agents/worktrees/041-rich-files-and-changes`; merged only when Alex says so. |
| The daemon parses nothing it only moves | `agentsd` does not link `CodeText`, and the protocol is unchanged. |
| Colour means something went wrong (035 FR-013) | `CodeInk` has no red or orange role, and change is shown by mark, weight, strike and a neutral wash. |
| Never mutate source to prove a test | Tests assert properties (text round-trips, contrast ratios) directly. |
| Both schemes build | Every phase ends with `Agents` and `Remote` building. |

**Result**: pass. Re-checked after Phase 1 design, still passing: the only new dependency is the
one Alex chose, and it is confined to the two apps.

## Project Structure

### Documentation (this feature)

```text
specs/041-rich-files-and-changes/
├── plan.md              # This file
├── research.md          # R1 measured choice; R2–R8 design decisions
├── data-model.md        # Language, CodeSpan, CodeRole, DiffRow, Fold, limits
├── quickstart.md        # How to see it working, what to measure
├── contracts/
│   └── codetext.md      # The package's public API and each view's contract
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
Packages/CodeText/                      # NEW local package; macOS 27 + iOS 27
├── Package.swift                       # CodeText (Swift) + one C target per grammar
├── Grammars/
│   ├── VENDORED.md                     # repo, tag, licence, KB for each grammar
│   ├── TSSwift/ {parser.c, scanner.c, tree_sitter/, include/, queries/highlights.scm}
│   ├── TSPython/ … TSMake/             # 20 in all (R2)
├── Sources/CodeText/
│   ├── Language.swift                  # CodeLanguage: detect(path:firstLine:), fence(tag:)
│   ├── Grammar.swift                   # language → TSLanguage + bundled query, compiled lazily
│   ├── CodeRole.swift                  # capture name → one of nine roles
│   ├── Colourer.swift                  # actor: parse, reparse incrementally, spans(in lines:)
│   ├── CodeDocument.swift              # @Observable per shown text: lines, spans by window
│   ├── LineDiff.swift                  # rows from old/new text; word ranges per paired line
│   ├── WordDiff.swift                  # tokenise + CollectionDifference over tokens
│   ├── Folds.swift                     # context runs → folds, open/closed
│   └── Limits.swift                    # FR-018 thresholds, one place
├── Tests/CodeTextTests/
│   ├── LanguageTests.swift, RoleTests.swift, ColourerTests.swift (text never altered, every grammar)
│   ├── LineDiffTests.swift, WordDiffTests.swift, FoldTests.swift, LimitTests.swift
│   └── Samples/                        # one small file per language
scripts/vendor-grammars.sh              # re-fetch a grammar at its pinned tag (R2)

Shared/UI/
├── CodeInk.swift                       # NEW palette: nine roles × light/dark, beside Paper
├── Code/                               # NEW
│   ├── CodeLine.swift                  # one line as Text: role runs + optional change marks
│   ├── FoldRow.swift                   # "↕ 412 unchanged lines"
│   └── CodeRows.swift                  # lazy rows over a CodeDocument (+ diff rows), used by all
├── Page/FileLines.swift                # CHANGED: rows come from CodeRows; wrap, numbers, place kept
├── Page/MarkdownText.swift             # CHANGED: .code case colours by fence tag
└── Chat/ChatBlocks.swift               # CHANGED: DiffView draws LineDiff rows, folds, word marks

App/Sources/Sidebar/ChangeFileView.swift  # CHANGED: Whole file via CodeRows + folds + next/prev
App/Sources/Sidebar/FilesPane.swift       # CHANGED: passes path to FileLines for detection
Remote/Sources/Panes/FilesPane.swift      # CHANGED: same
project.yml                               # CHANGED: CodeText package for Agents + Remote (not agentsd)
Acknowledgements (App/Resources + Remote) # CHANGED: tree-sitter and grammar licences
```

**Structure Decision**: This is a new local package, not code in `AgentsKitCore`. AgentsKitCore
is linked by `agentsd`, and the daemon must not carry 17 MB of parsers. The views stay in
`Shared/UI`, which both apps already compile, so the Mac and the phone draw code with the same
code (FR-014, FR-021).

## Phases

**A. The look (gate).** Create the package with Swift, Python, TypeScript, JSON and Markdown
grammars. Add `CodeLanguage`, `CodeRole`, `Colourer` and `CodeInk`, and colour in `FileLines`
only. Walk it on a scratch root in all three themes and screenshot it for Alex. **Stop for his
look.** The palette and weight are settled here, before any more is built.

**B. Every language.** Vendor the remaining 15 grammars, then add the sample-file tests (SC-006)
and the size check (SC-003, measured on the built apps).

**C. Diffs.** `LineDiff`, `WordDiff` and `Folds`, test first. `DiffView` draws them, then
`ChangeFileView`'s Whole file gets folds and next/previous.

**D. Everywhere else.** Fenced blocks in `MarkdownText`, the Remote's files pane, and
`ChangesView` and the permission sheet (through `DiffView`).

**E. Limits and live text.** Incremental reparse for text an agent is writing, the FR-018
fallbacks with their line, and timing SC-001, SC-002 and SC-005 on the Mac. The phone walk
follows the real-devices memory and is shown to Alex.

## Complexity Tracking

| Addition | Why needed | Simpler alternative rejected because |
|---|---|---|
| A new local package | Keeps parsers out of `agentsd`, and lets the logic run under `swift test` | Putting it in AgentsKitCore links 17 MB into the daemon; putting it in `Shared/UI` leaves the diff and detection logic untestable outside Xcode |
| Vendored grammar C sources | Published grammar packages fail to link (python's scanner dropped; TypeScript's include path), R1 | Depending on 20 grammar packages means 20 fragile manifests and version skew with the runtime |
| 20 grammars (~17 MB installed) | FR-002 | highlight.js is 0.3 MB, but whole-file only, 10–20× slower to first colour, and restarts from the top on every live change (R1). Chosen by Alex |
