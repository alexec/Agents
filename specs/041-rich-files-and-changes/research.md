# Research: Code That Reads Like Code (041)

## R1. Which highlighter: tree-sitter or highlight.js

Measured 2026-09-25 on this Mac (Apple silicon, release builds), in a spike package at
`/tmp/041-spike`. The machine was under heavy load from other agents' builds (load average 44–57),
so absolute times are inflated; each pair below ran in the same conditions and the ratios hold.

### Candidates

| | tree-sitter | highlight.js |
|---|---|---|
| Swift package | `tree-sitter/swift-tree-sitter` 0.25.0 (C runtime + Swift API); Neon 0.6.0 on top for text-system integration | `appstefan/HighlightSwift` 1.1.0 (highlight.js 11 in JavaScriptCore) |
| How it works | A real parser per language, compiled C; a query (`highlights.scm`) names spans | Regex state machine in JS; returns HTML with `<span class>` |
| Languages | One grammar per language, chosen by us | 51 bundled in one 308 KB script |
| Incremental | Yes: reparses only what changed; queries by range | No: whole text every time |

### Speed (5,000-line files; ms)

| File | tree-sitter parse | tree-sitter colour the first screen (150 lines) | tree-sitter colour the whole file | highlight.js whole file (JS only) | HighlightSwift whole file (JS + HTML→AttributedString) |
|---|---|---|---|---|---|
| Swift, 218 KB | 83 | 3.2 | 161 | 1,780 | 720 |
| Python, 168 KB | 39 | 1.1 | 97 | 840 | 452 |
| TypeScript, 175 KB | 44 | 1.8 | 191 | 1,740 | 882 |
| JSON, 69 KB | 13 | 0.6 | 32 | 399 | 523 |
| One 294 KB line (minified JS) | 109 | 734 | 823 | 1,915 | — |

One-off per language per launch, tree-sitter: compiling the highlight query, 1–215 ms (Swift's
is the largest). highlight.js: loading the script into a JavaScript context, 127 ms, once.

Peak memory for the whole run: tree-sitter 108 MB, highlight.js 248 MB.

So for a large file, tree-sitter puts colour on the first screen in roughly **50–120 ms**
(parse plus a range query). highlight.js must colour the whole file first, which took
**0.4–1.8 s**. A file an agent is still writing gets reparsed incrementally by tree-sitter, while
highlight.js starts again from the top on every change. A single very long line is slow for both:
FR-018's plain fallback is needed either way.

### Size

tree-sitter, all 24 grammars FR-002 needs, compiled `-Os` for arm64 (the app is arm64 only):

| Grammar | KB | Grammar | KB | Grammar | KB |
|---|---|---|---|---|---|
| SQL | 10,786 | Rust | 1,079 | Markdown inline | 374 |
| Objective-C | 5,195 | C | 613 | JavaScript | 345 |
| Kotlin | 3,958 | Python | 440 | Go | 207 |
| Swift | 3,667 | Java | 398 | YAML | 182 |
| C++ | 3,354 | Markdown | 373 | Make | 134 |
| Ruby | 2,055 | TSX | 1,404 | CSS | 114 |
| TypeScript | 1,373 | Bash | 1,331 | Dockerfile, TOML, HTML, JSON | 86 |

**Total: 37 MB installed per app, about 3.2 MB compressed** (gzip -9). Without SQL,
Objective-C and Kotlin: 17 MB installed, 1.9 MB compressed. Parse tables compress well, so the
download stays under SC-003's 10 MB. The installed size does not, and it is paid twice (Mac app
and phone app). Query files add about 100 KB.

highlight.js: 308 KB script plus about 330 KB of Swift wrapper, about 0.1 MB compressed.

### Other findings

- **Grammar packages don't build as published.** tree-sitter-python's `Package.swift` checks for
  `src/scanner.c` relative to the wrong directory, drops it, and the link fails. TypeScript's
  scanner includes `../../common/scanner.h`. Either way we would vendor the grammars' C sources
  into our own targets (the spike does this), pinned by tag.
- **HighlightSwift's AttributedString step uses the HTML importer**, which is WebKit-backed and
  must run on the main thread. The spike deadlocked on it the first time. FR-016 rules out a web
  view, so choosing highlight.js would mean running the JS ourselves and turning its HTML into
  spans ourselves, using the library only for the script.
- **Neither needs the network.** Both work on macOS and iOS.

### Decision

**tree-sitter, trimmed** (chosen by Alex, 2026-09-25), used directly through `swift-tree-sitter`
0.25.0, without Neon.

- **Rationale**: It puts colour on the first screen 10–20× sooner than highlight.js does on large
  files. It reparses incrementally as an agent writes. It is native code with no JavaScript
  engine, and it uses half the memory. The size cost is bounded by leaving out the three heaviest
  grammars.
- **Alternatives considered**:
  - All 24 grammars: 37 MB installed, and SQL alone is 10.8 MB.
  - highlight.js through HighlightSwift: 0.3 MB, but whole-file only and slow, and its
    AttributedString step goes through WebKit.
  - Splash: Swift only.
  - Runestone: a UIKit editor, not a highlighter, with no macOS support.
- **Why no Neon**: Neon drives a text view's storage (`NSTextView`/`UITextView`). The app draws
  code as SwiftUI rows in a lazy stack (`FileLines`, `DiffView`), so the parts of Neon we would
  use (a visible-range query and incremental reparse) are a few dozen lines against
  `swift-tree-sitter` (R3, R7).

## R2. The grammar set

**Decision**: 20 grammars, vendored as C sources under `Packages/CodeText/Grammars/`, each
pinned to the tag measured in R1 and listed in `VENDORED.md` with its licence.
`scripts/vendor-grammars.sh <name>` re-fetches one.

| Grammar | Tag | Covers |
|---|---|---|
| swift | alex-pinkus 0.7.3-with-generated-files | .swift |
| c | v0.24.1 | .c, .h, **.m** (Objective-C as C) |
| cpp | v0.23.4 | .cc .cpp .cxx .hpp .hh .mm |
| python | v0.25.0 | .py .pyi, `#!…python` |
| javascript | v0.23.1 | .js .mjs .cjs .jsx, `#!…node` |
| typescript / tsx | v0.23.2 | .ts .mts .cts / .tsx |
| json | v0.24.8 | .json .jsonc, `.babelrc` etc. |
| go | v0.25.0 | .go |
| rust | v0.24.2 | .rs |
| java | v0.23.5 | .java |
| ruby | v0.23.1 | .rb, Gemfile, Rakefile, `#!…ruby` |
| bash | v0.25.1 | .sh .bash .zsh, .zshrc .bashrc, `#!…sh` |
| yaml | v0.7.2 | .yml .yaml |
| toml | v0.7.0 | .toml |
| html | v0.23.2 | .html .htm |
| css | v0.23.2 | .css |
| markdown (block only) | v0.5.1 | .md in a diff or Whole file. The files pane shows Markdown as a page (022), and fenced blocks use their own grammar. |
| dockerfile | v0.2.0 | Dockerfile, *.dockerfile |
| make | main @ pinned commit | Makefile, *.mk |

It adds about 17 MB installed and 1.9 MB compressed (R1). Kotlin (.kt, .kts) and SQL (.sql) are
plain. `.h` is coloured as C: C++ headers are usually `.hpp`, and C's grammar reads most C++
headers acceptably.

**Rationale**: Published grammar packages fail to link as they stand (R1), and vendoring puts
every C file and query in one place, built one way. `highlights.scm` queries are vendored beside
each grammar. Where a grammar's query inherits another's (TypeScript and TSX take JavaScript's),
the vendored file is the concatenation, so each language needs exactly one query.

## R3. Drawing coloured code in SwiftUI rows

**Decision**: Keep the row-per-line lazy stack every view already uses. Each row is one `Text`
built from an `AttributedString` whose runs carry a foreground colour from `CodeInk`. A
`CodeDocument` (`@Observable`, one per shown text) owns the split lines and asks the `Colourer`
actor for spans **by window**: 200 lines around what is on screen. It publishes each window as
it arrives. A row with no spans yet draws plain.

**Rationale**:
- It keeps `FileLines`' behaviours as they are: wrapping, the gutter, scroll-to-line, keepsPlace
  and `textSelection`.
- Windows turn thousands of rows into a few async requests.
- A row reads only its own line's spans, so a window arriving redraws only the rows it covers.

**Alternatives considered**:
- `NSTextView`/`UITextView` with Neon: two platform views, and it loses the shared SwiftUI rows.
- Colouring the whole file before showing it breaks FR-017.

## R4. Nine roles and one palette

**Decision**: Capture names from every `highlights.scm` map, by their first component with a few
exceptions, to nine roles: `keyword`, `string`, `comment`, `number` (numbers, booleans,
constants), `type`, `function`, `property` (attributes and properties), `punctuation` (and
operators), and `plain`. Anything unmapped is `plain`. `CodeInk` gives each role a light and a
dark colour, derived from `Paper`'s warm ink:

- Comments: a muted warm grey, italic.
- Keywords: a deep ink blue, semibold.
- Strings: a dark olive green.
- Numbers: a plum.
- Types: a teal.
- Functions: an indigo (a slate blue at first; too close to the ink in light, changed at the T024 look gate).
- Properties: brown.
- Punctuation: the secondary ink.

There is **no red, orange or pink role**; StateTint keeps those for failure. The exact hex values
are settled at the look gate (Phase A).

**Rationale**: Nine roles give the structure FR-001 asks for without the noise of a 30-colour
theme. A test computes the WCAG contrast of every role against `Paper.ground` and `Paper.well` in
both appearances and fails below 4.5:1 (SC-007).

## R5. Line and word diffs

**Decision**: Both come from the Swift standard library, and no diff library is added.

- **Lines**: `newLines.difference(from: oldLines)` (Myers) over `[Substring]` gives removals and
  insertions. They are walked in order into `DiffRow`s marked context, removed or added. In each
  change block (a run of removals then insertions between two context lines), removed line *i*
  pairs with added line *i* when both exist.
- **Words**: each paired line is tokenised into identifier runs, whitespace runs and single
  punctuation characters. Diffing the token arrays the same way gives character ranges, marked on
  each side. When less than a third of the tokens are shared, the lines aren't pairs, so no word
  marks are drawn (a rewrite, not an edit).
- **Whole file**: the daemon's `DiffLine`s (035) are already a line diff. Word marks are added to
  them by the same pairing, app-side.

**Rationale**: `CollectionDifference` is fast enough at edit sizes (hundreds of lines), is on
both platforms, and needs no dependency. It matches the spec's "word marks, not moves".

## R6. Limits (FR-018)

**Decision**: One `Limits` type holds:

| Limit | Value | Why |
|---|---|---|
| Colour a text of at most | 512 KB | The files pane reads the first 128 KB already (035/022); 512 KB covers pages and diffs with room. |
| Colour no text with a line longer than | 4,000 characters | R1: a single 294 KB line took 734 ms even for one screen, because a screen range can't split a line. Minified and generated files are what hit this. |
| Word-mark a line of at most | 1,000 characters | Token diff cost is quadratic in the worst case. |
| Word-mark a change block of at most | 200 paired lines | Beyond that it is a rewrite. |
| Fold unchanged runs longer than | 8 lines, keeping 3 either side | The same shape as `git diff -U3`. |

A file past a colour limit shows plain, with one line saying "Shown without colour: too large"
or "…: a line is too long". 035's `drawLimit` (2,000 changed lines) stays as it is.

## R7. Text that is still being written

**Decision**: When a `CodeDocument` gets new text for the same file, it finds the common prefix
and suffix, builds one `InputEdit`, calls `tree.edit(_:)`, and reparses with the old tree. Only
the windows the change touched are invalidated; the rest keep their spans. The reader's place is
kept by the existing `keepsPlace` and `ScrollViewReader` logic, which this does not touch.

**Rationale**: FR-007. A full reparse of 5,000 lines is 13–83 ms. Incremental reparse is
typically a few ms for an append, which is what an agent writing a file mostly does.

## R8. First use of a language

**Decision**: Each language's query is compiled on first use, off the main actor, and cached for
the life of the app. The Swift query took 93–215 ms to compile under load (R1); others took
under 65 ms. The text shows plain meanwhile (FR-017). There is no warm-up at launch: most
sessions never open most languages.

## R9. What stays the same

Some things don't change:
- The daemon's protocol, `ChangedFileDetail`, and `DiffLine`'s wire shape.
- 035's draw limit.
- `LivePage`'s typing surface; its fenced blocks are coloured by `MarkdownText`.
- How the files pane reads files: the first 128 KB and the probe.

`agentsd` does not link `CodeText`.
