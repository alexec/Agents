# Implementation Plan: Paper Document View

**Branch**: `007-paper-document-view` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/007-paper-document-view/spec.md`

## Summary

A Markdown file in the files pane stops being a wall of monospaced source and becomes a document:
headings that look like headings, lists that indent, tables that line up, images that appear, set on
a reading surface with a measure short enough to read. One control flips back to the exact source.
HTML gets the same surface by a different route.

The research turned this from a rendering feature into a parsing one. The pane's Markdown is drawn
by `MarkdownText`, which reads `MarkdownBlock.parse` — a hand-written line scanner that trims every
line to its whitespace before deciding what it is, and therefore cannot see nesting at all. This
repository's own documents are nested lists and task lists: 2,212 checkboxes and a maximum intent
depth of nine. Rendering them with the parser we have would produce a flat, wrong document very
prettily.

Foundation already ships the parser we need. `AttributedString(markdown:interpretedSyntax: .full)`
returns a complete CommonMark parse with the full nesting ancestry, table column alignment, code
fence languages, image URLs and link destinations. Over all 1,634 Markdown files in this working
tree it failed zero times at a mean of 2.8ms. So the largest piece of this feature is replacing the
inside of `MarkdownBlock.parse` while keeping its shape, which hands chat the same fixes and keeps
one parser in the app rather than two.

Three things Foundation gets wrong and we correct: YAML front matter swallows the heading after it
(224 files here start with it), task checkboxes come through as literal `[ ]` text, and raw HTML
blocks arrive with no presentation intent. Each is a small, tested transform either side of the
parse.

HTML is the one place with a second renderer. The cheap route — `NSAttributedString`'s HTML importer
— drops relative links silently, flattens tables to bare lines and imposes Times. It was probed and
rejected on evidence. HTML instead goes through the `WKWebView` the app already owns in
`BrowserPane`, with scripts off, all network blocked, and our own stylesheet carrying the same
measure and scale the SwiftUI view uses, read from one place so the two cannot drift.

What is left is small: a document-type decision, a mode toggle in a header bar that has an empty
trailing side waiting for it, and the measure-and-padding arithmetic — which is where the spec's own
number did not survive measurement. SC-003 asks for 60 characters per line at the default 380pt pane
width; `.body` gives 57. Twelve-point type gives 61. That is why the document face is New York 12pt
rather than the body style used everywhere else.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`.
Unchanged.

**Primary Dependencies**: None added. Foundation (the Markdown parser), SwiftUI, and WebKit — all
three already linked, WebKit by `BrowserPane` since 002. `swift-markdown` was considered and
rejected: it wraps the same cmark Foundation already links, and `AgentsKit` has exactly one
dependency, test-only.

**Storage**: One new `UserDefaults` key on `SidebarFrame` for the rendered-or-source preference,
which FR-009 makes a window-level setting rather than a per-agent one. No file on disk, no schema,
no migration. Nothing is written to a project's directory.

**Testing**: `swift test` in `AgentsKit`. The parse, front matter stripping, checkbox extraction,
HTML-block detection, document-type classification, link classification and the measure arithmetic
are pure and get unit tests. The 19 cases already in `Unit/MarkdownBlockTests.swift` are the
regression suite for swapping the parser's insides — they must pass unchanged, except where they
assert a behaviour the research proved wrong. Two tests carry the feature: that the switch over the
twelve block kinds is total, because that is what stops a document silently losing a paragraph, and
that a link is classified in-folder or out, because that is the one place this feature could send a
reader somewhere they did not ask to go. There is no app test target and no snapshot test in this
repository, so the views are checked by running the app — `quickstart.md` says how.

**Target Platform**: macOS 27, Apple silicon, one Mac.

**Project Type**: Desktop app plus a helper executable in its bundle. Unchanged.

**Performance Goals**: Opening a document adds no perceptible delay over opening the same file as
source (SC-002). Measured headroom: 2.8ms mean and 34ms worst over 1,634 real files, against a
128 KB input ceiling `FileProbe` already enforces. The one thing that could go wrong is reparsing on
every `FolderWatch` tick, which is why an unchanged `FileProbe` stops the reload before it starts.

**Constraints**: No new dependency. No second Markdown parser. No script may run and no network
request may be made on a document's behalf (FR-011). Nothing may become editable (FR-017). No colour
literal — the house rule is that colour means something has gone wrong — so the paper quality is
bought with typography and space only. Every font is a semantic or relative system style so Dynamic
Type keeps working (FR-019).

**Scale/Scope**: 20 functional requirements over 3 user stories. Twelve block kinds, nesting to
depth 9, two document types, one pane, one person.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the Spec Kit template. No principles have been written
for this project, by the user's explicit decision, so there is nothing to check against and no
violation can be claimed. The rules in force are the ones 001 through 006 recorded.

| Rule in force | Where the design honours it |
|---|---|
| One code path, no per-kind branching | One Markdown parser for chat and the pane, not two. HTML is a second path because HTML is a second format, not a second consumer |
| Logic where `swift test` can reach it | Parse, classification, link routing and the measure arithmetic are pure functions in `AgentsKit`. `App/Sources` holds views that draw the answers |
| Nothing installed, nothing added | No package. Foundation's parser and the WebKit already in the bundle |
| The pane is read-only, completely | FR-017. Rendering adds no control that writes, and the webview cannot navigate itself anywhere |
| Colour means something is wrong | No colour literal. `.secondary`/`.tertiary`/`.quaternary` and typography only |
| Say plainly when something cannot be done | FR-016's fallback and FR-018's truncation notice are prose in the reader's language, matching `"\(name) is not there any more."` |
| An agent asking for something is a request, not a command | A `show_file` line target opens source view rather than silently changing the reader's saved mode |

**Re-check after Phase 1**: unchanged. The design adds no dependency, no stored file, no daemon
method and no transport. It adds one `UserDefaults` key and removes a parser.

## Project Structure

### Documentation (this feature)

```text
specs/007-paper-document-view/
├── plan.md              # This file
├── spec.md              # What it does
├── research.md          # What Foundation, WebKit and this Mac actually do, proved by running them
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── document-model.md  # The AgentsKit surface the views read
│   └── ui.md              # What the pane does, and when
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks, not created here)
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKit/
├── Model/
│   ├── MarkdownBlock.swift      # Same enum, new insides: Foundation's parse, nesting, images, tasks
│   └── FrontMatter.swift        # New. Strip a leading --- block, and only a leading one
└── Files/
    ├── DocumentKind.swift       # New. Markdown, HTML, or not a document
    ├── DocumentLink.swift       # New. In-folder file, or hand it to BrowserPolicy
    ├── PageMetrics.swift        # New. Width in, measure and padding out. One source for both renderers
    └── FileProbe.swift          # Untouched. DocumentKind reads the URL beside it

App/Sources/
├── Sidebar/
│   ├── FilesPane.swift          # Chooses rendered or source; lifts the truncation notice out of .text
│   ├── DocumentView.swift       # New. The reading surface: measure, padding, scroll position
│   └── HTMLDocumentView.swift   # New. WKWebView, scripts off, network blocked, our stylesheet
└── Chat/
    └── MarkdownText.swift       # Grows a nested renderer and an image case; gains a page style

Packages/AgentsKit/Tests/AgentsKitTests/Unit/
├── MarkdownBlockTests.swift     # The 19 existing cases are the regression suite; nesting, tasks, images, CRLF added
├── FrontMatterTests.swift       # New
├── DocumentKindTests.swift      # New
├── DocumentLinkTests.swift      # New
└── PageMetricsTests.swift       # New. The numbers in research section 6, asserted
```

**Structure Decision**: unchanged from 001. Two thin shells around one library. The split this
feature has to get right is the one `Package.swift` states: everything that decides goes in the kit
where `swift test` reaches it, and the app target draws. That is why `PageMetrics` is a pure
function of width in `AgentsKit` rather than a `GeometryReader` full of numbers in a view — the
measure table in research section 6 is the kind of thing that rots silently unless a test holds it.

## Key design decisions

### 1. `MarkdownBlock.parse` keeps its name and loses its insides

The enum stays the public surface; chat keeps compiling. What changes is that `parse` runs
Foundation's full CommonMark parse and folds the `PresentationIntent` ancestry into blocks, instead
of scanning lines.

The cases have to grow, because the old ones cannot express what the parser now sees:

| Today | Becomes | Why |
|---|---|---|
| `.bullets([String])`, `.numbered([String])` | `.list(ordered: Bool, start: Int, items: [Item])` where `Item` holds `blocks: [MarkdownBlock]` and `checked: Bool?` | Nesting is items containing blocks. Depth 9 was measured in this tree |
| `.quote(String)` | `.quote([MarkdownBlock])` | A quote can hold a list, a heading, another quote |
| — | `.image(source: String, alt: String)` | FR-013. Foundation hands us `imageURL` and the alt text; today both vanish into a paragraph |
| `String` payloads | `AttributedString` payloads | Inline marks come out of the same parse. Re-parsing each paragraph with `.inlineOnly`, as `MarkdownText.inline` does today, is a second parse that can disagree with the first |
| `id` derived from content | Positional identity | `.rule` returns `"hr"` for every rule today, so any document with two rules already feeds `ForEach` duplicate ids. FR-015's scroll restore needs a stable id anyway |

This is the largest change in the feature and the one to do first, because everything else draws
what it produces.

### 2. Front matter is stripped, checkboxes are extracted, HTML blocks are shown verbatim

Three corrections around Foundation's parse, each with a number behind it from this tree: 224 files
start with front matter, 2,212 task checkboxes, 257 raw HTML runs. Research sections 3a–3c have the
probe output; the decisions are strip, extract, and show as an unlabelled code block.

The front matter rule is positional — first line only — because `---` between paragraphs is a
legitimate thematic break and was proved to parse as one. Getting this wrong in the other direction
would eat the top of a document.

### 3. HTML is a webview, and that was an evidence call

`NSAttributedString`'s HTML importer was the cheap answer, so it went first. It drops the `NSLink`
attribute from relative hrefs while still colouring and underlining them — a link that looks
clickable and is not — flattens `<table>` to bare lines, and arrives as Times and Courier with kerning
and stroke attributes set. FR-012 is the requirement most specific to this feature and that path
cannot meet it. Research section 5 has the runs.

So HTML goes through `WKWebView`, which the app already holds outside the view tree in
`BrowserPane`'s `WebHolder`. Scripts off via `allowsContentJavaScript = false`, every load blocked by
a compiled `WKContentRuleList`, the stylesheet injected at document start, and
`loadFileURL(_:allowingReadAccessTo:)` scoped to the browsable folder so relative images resolve and
nothing outside it can be read.

The cost is two renderers. The mitigation is that both read their measure, padding and type scale
from `PageMetrics`, so "the same reading surface" is enforced by a shared function rather than by
someone remembering.

### 4. The document face is New York 12pt, because 13pt does not fit

SC-003 wants 60–90 characters per line at the pane's default width. Measured on this Mac with real
prose: at 380pt with 20pt padding, `.body` at 13pt gives 57 characters. Twelve-point gives 61.

| | advance | at 340pt (default pane) | at the 500pt cap |
|---|---|---|---|
| `.body` 13pt | 5.97 | 57 — misses the floor | 84 |
| New York 12pt | 5.56 | 61 | 90 |

So: prose is `.system(.callout, design: .serif)`, the measure caps at 500pt so the 900pt maximum pane
width cannot run to 154 characters, and padding is 20pt shrinking to 12pt as the pane narrows. At the
280pt minimum that leaves 46 characters — below the floor on purpose, because FR-005 says the padding
gives way and not the text.

Serif rather than a larger sans because the house rule in `design/logo/README.md` reserves colour for
things going wrong, so a document cannot announce itself with colour. New York is a system face, so
Dynamic Type and the accessibility settings keep working. Headings, code and chrome stay on the sans
and mono faces already in use.

### 5. A `show_file` line target beats the saved mode

`ShownFile` carries an optional line, and `FileLines` exists partly to serve it — a numbered gutter
and a scroll to the named row, because "an agent that says 'line 412' is naming something the reader
has to be able to find". A rendered page has no line 412.

So a file opened with `state.openLine != nil` opens in source view regardless of the saved mode, and
**does not change** the saved mode. Open the same file yourself afterwards and it renders. The agent
asked for a place in a file; it did not ask to change how the reader reads.

### 6. The cheapest way to preserve a scroll position is not to reload

`FolderWatch` watches all of `agent.cwd`, and `reloadFile` reassigns `probe` on every tick whether
the open file changed or not. `FileProbe` is already `Equatable`. Comparing before assigning turns
the overwhelmingly common case into no work, no reparse and no scroll jump.

When the file genuinely did change, the blocks' positional ids drive
`.scrollPosition(id:anchor:.top)` over a `.scrollTargetLayout()`, returning to the nearest surviving
id. This is new machinery for this app — there is no `ScrollPosition` anywhere in it today — which is
the second reason the id fix in decision 1 is not optional.

### 7. What is not being built

- **No editing.** FR-017, and the webview cannot navigate itself anywhere either.
- **No print or export.** A page on screen is not a demand for a page on paper.
- **No syntax highlighting inside code blocks.** A different feature with a different appetite.
- **No PDF or Word.** Settled in the spec: a separate feature, not a stretch of this one.
- **No remote documents.** 005 ruled out browsing the Mac's file system from a phone, and the daemon
  has no file methods at all.
- **No table of contents or outline.** Worth wanting; wait until the surface has been used.

### 8. The one thing to find out by running it

`.textSelection(.enabled)` is applied per `Text`, and a rendered document is many of them. Whether a
drag spans blocks on macOS 27 is a question for the running app, not the compiler. It is not a
blocker — chat has had this exact shape since 002, so the pane is no worse than the surface beside
it, and FR-007's source toggle always gives a whole-file selection in one view. It is the first check
in `quickstart.md`, and it should be done on the layout before any of the depth in decisions 1 to 3
is built.

## Complexity Tracking

> No Constitution Check violations. One deliberate departure from the spec is recorded instead.

| Departure | Why | What was rejected |
|---|---|---|
| SC-003's 60-character floor is met by dropping to 12pt type, not by `.body` | Measured: `.body` yields 57 characters at the 380pt default pane width. The spec's floor and the app's default width are not both satisfiable at 13pt | Widening the default pane, which changes a window the reader arranged; or relaxing SC-003, which gives up the thing that makes it read as a document |
| Two renderers, one typography | `NSAttributedString`'s HTML importer drops relative links and flattens tables (research 5); folding HTML into twelve Markdown block kinds would misrepresent the file | One renderer via a shared block model — rejected because arbitrary HTML is not a subset of Markdown |
