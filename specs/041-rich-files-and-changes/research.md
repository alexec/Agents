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

_Pending Alex's choice (asked 2026-09-25)._
