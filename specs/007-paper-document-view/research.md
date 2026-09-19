# Research: Paper Document View

**Feature**: `007-paper-document-view` | **Date**: 2026-09-18

Everything below was run, not recalled. The probes are throwaway Swift files compiled with the
same toolchain the app uses (Apple Swift 6.4, target `arm64-apple-macosx27.0.0`). Where a number
appears, it came out of a run on this Mac.

---

## 1. Foundation already has a full CommonMark parser, and it is better than ours

**Decision**: `MarkdownBlock.parse` is reimplemented on top of
`AttributedString(markdown:options:)` with `interpretedSyntax: .full`. No new dependency, no
hand-written line scanner.

**What the probe showed.** Given one document containing nested lists, ordered lists, nested block
quotes, a GFM table with alignment, a fenced code block, an image, a setext heading, a hard break
and inline marks, Foundation returned 29 runs carrying a complete `PresentationIntent` ancestry:

```
"top level"     intent=[paragraph > listItem 1 > unorderedList]
"nested item"   intent=[paragraph > listItem 1 > unorderedList > listItem 1 > unorderedList]
"deeper"        intent=[paragraph > listItem 1 > unorderedList > listItem 1 > unorderedList > listItem 1 > unorderedList]
"a quote"       intent=[paragraph > blockQuote]
"nested quote"  intent=[paragraph > blockQuote > blockQuote]
"a"             intent=[tableCell 0 > tableHeaderRow > table [left, right]]
"let x = 1\n"   intent=[codeBlock 'swift']
"alt text"      intent=[paragraph] imageURL=./diagram.png
"Setext heading" intent=[header 1]
"link"          intent=[paragraph] link=./other.md
```

Every component the hand-written parser gets wrong, it gets right: the full nesting ancestry, the
list item's ordinal, the table's per-column alignment, the code fence's language, the image URL and
its alt text, and the link destination as a `URL` rather than as text inside a string.

**What the existing parser does instead.** `MarkdownBlock.parse`
(`Packages/AgentsKit/Sources/AgentsKit/Model/MarkdownBlock.swift:56`) trims every line to its
whitespace before deciding what it is (`:77`), which destroys indentation before nesting can be
seen. Consequences, all confirmed in the code:

| Input | What we do today |
|---|---|
| `  - nested` under `- top` | Flattened into one `.bullets` array; the nesting is gone |
| `Title\n----` | `.paragraph("Title")` then `.rule` — a heading becomes a horizontal line |
| `![alt](x.png)` | Stays as text inside a paragraph; SwiftUI `Text` draws nothing |
| `- [ ] todo` | A bullet whose text literally begins `"[ ] "` |
| `a\r\nb` (CRLF) | `components(separatedBy: .newlines)` splits on `\r` **and** `\n`, so every line gets a phantom blank line after it |
| `>> deep` | One `>` stripped; quote text is `"> deep"`, never re-parsed |
| `    indented code` | Trimmed, then reinterpreted — `    - item` becomes a bullet |
| Two `---` rules in one file | Both get `id == "hr"` (`:47`), so `ForEach` gets duplicate IDs |

**Rationale for replacing rather than adding a second parser.** Two parsers would mean the same
file reads differently in chat and in the pane, which is the inconsistency the spec's assumptions
set out to avoid, and it is the same rule 006 wrote down as *one code path*. Replacing also hands
chat the nested-list, CRLF and duplicate-id fixes for nothing. The 19 existing cases in
`Unit/MarkdownBlockTests.swift` become the regression suite that says the swap lost nothing.

**Alternatives considered.**

- *Extend the hand-written scanner.* Nested lists alone mean tracking indentation stacks, lazy
  continuation and loose-vs-tight items — reimplementing cmark, badly, in a file that already has
  two latent bugs.
- *Add `swift-markdown` (Apple's cmark-gfm wrapper).* It is the same parser Foundation already
  links, reached through a package. `AgentsKit` has exactly one dependency, SwiftTerm, and it is
  test-only. Paying a dependency for something in Foundation is not a trade.

---

## 2. It is fast enough, measured over this repository

**Decision**: no caching, no incremental parse, no background queue. Parse on the main actor when
the file is opened.

Ran the full parse over every `.md` file in the working tree:

```
markdown files: 1634
parse failures: 0
total parse time: 4611ms, mean 2.8ms
slowest: 34ms  (swift-argument-parser CHANGELOG.md)
block kinds seen: blockQuote, codeBlock, header, listItem, orderedList, paragraph,
                  table, tableCell, tableHeaderRow, tableRow, thematicBreak, unorderedList
max intent nesting depth: 9
```

2.8ms mean, 34ms worst, zero failures across 1,634 real files. SC-002 asks that rendering add no
perceptible delay; a 34ms worst case on a file far larger than anything in this project clears that
without machinery. `FileProbe` reads at most 128 KB anyway, which bounds the input.

Two numbers to build against: **twelve block kinds** is the complete vocabulary the renderer must
cover — nothing else appears — and **nesting depth 9** means the renderer must recurse, not special-case
one level.

---

## 3. Three things Foundation gets wrong, and what to do about each

### 3a. YAML front matter is corrupted, and 224 files in this tree start with it

```
input:  ---\ntitle: Thing\nstatus: Draft\n---\n\n# Real heading\n\nBody.
output: [thematicBreak] "⸻"
        [header] "title: Thing"   [header] " "   [header] "status: Draft"   [header] "Real heading"
        [paragraph] "Body."
```

The opening `---` becomes a rule, the front matter becomes a setext `h2`, and — the part that
matters — **the real `# Real heading` is swallowed into that same header run**. Content is lost, not
just mis-styled.

**Decision**: strip a leading front matter block before parsing. A `---` line as the very first line
of the file, up to the next `---` line. Positional, because a `---` anywhere else is a legitimate
thematic break and the probe confirms it parses as one:

```
input:  Para.\n\n---\n\nNext para.
output: [paragraph] "Para."  [thematicBreak] "⸻"  [paragraph] "Next para."
```

Front matter is dropped rather than rendered as a table. It is metadata for tooling; the reader
opened a document.

### 3b. Task list checkboxes are not parsed, and there are 2,212 of them here

```
input:  - [ ] todo\n- [x] done
output: [paragraph > listItem > unorderedList] "[ ] todo"
        [paragraph > listItem > unorderedList] "[x] done"
```

Foundation gives the list structure but leaves the checkbox as literal text. 2,212 such items across
this repository — every `tasks.md` and every `checklists/requirements.md`, which are among the files
most worth reading well.

**Decision**: post-process. A list item whose text begins `[ ] `, `[x] ` or `[X] ` loses that prefix
and gains a `checked: Bool` on the item. The renderer draws a checkbox glyph in place of the bullet.
Read-only, like everything else in the pane.

### 3c. Raw HTML inside Markdown arrives with no presentation intent

```
input:  Before.\n\n<div class="x">\n  <b>inside</b>\n</div>\n\nAfter with <br> inline.
output: [paragraph] "Before."
        [-]         "<div class=\"x\">\n  <b>inside</b>\n</div>\n"     ← no intent at all
        [paragraph] "After with "   [paragraph] "<br>"   [paragraph] " inline."
```

A run with a nil `presentationIntent` is exactly the signal for an HTML block — a clean seam, not a
guess. 257 such runs in this tree.

**Decision**: show it verbatim, as a code block without a language label. The existing parser's
`nothingIsLost` test (`MarkdownBlockTests.swift:57`) already asserts HTML is not dropped, and that
promise is worth keeping. Interpreting HTML inside Markdown would mean running the HTML path from
inside the Markdown path, which is two renderers in one document.

---

## 4. Truncation needs no special handling

`FileProbe` reads the first 128 KB, so a document can be cut anywhere. Probed the two cuts that
looked dangerous:

```
unclosed fence:   ```swift\nlet x = 1\nlet y = 2       →  [codeBlock] "let x = 1\nlet y = 2\n"
ragged table row: | a | b |\n|---|---|\n| 1 | 2 |\n| 3 | →  header a,b then cells 1, 2, 3
```

cmark closes the fence at EOF and pads the short row. Both render. Nothing to build; FR-016's
truncation notice is the whole answer, and it just has to be lifted out of the `.text` branch of
`FilesPane.fileView` (`FilesPane.swift:151`) so rendered mode carries it too.

---

## 5. HTML: `NSAttributedString` is the wrong tool, `WKWebView` is the right one

**Decision**: HTML renders in a `WKWebView` with scripts disabled, all network blocked by a content
rule list, our own stylesheet injected, and the file's own URL as the base so relative links and
images resolve.

**Why not `NSAttributedString(data:options:[.documentType: .html])`.** It was the cheap option, so it
got probed first. Three findings, in order of severity:

1. **Relative links are dropped entirely.** Given
   `<a href="./x.md">link</a>` and `<a href="https://example.com">web</a>`:

   ```
   "link" -> [NSColor, NSFont, NSKern, NSParagraphStyle, NSStrokeColor, NSStrokeWidth, NSUnderline]
   "web"  -> [..., NSLink, ...]   LINK = https://example.com/ (NSURL)
   ```

   The relative one is *styled* as a link — colour and underline — and carries no `NSLink`. It looks
   clickable and is not. FR-012 is the requirement most specific to this feature, and this path
   cannot satisfy it.

2. **Tables collapse.** `<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>`
   comes back as the string `"a\nb\n1\n2\n"` with `textBlocks` empty. The column structure is gone,
   not merely unstyled.

3. **It imposes its own typography.** Everything arrives as `Times-Roman@12` and `Courier@13` with
   `NSKern`, `NSStrokeColor` and `NSStrokeWidth` set. Reaching the paper typography would mean
   stripping and rewriting every attribute run, at which point the importer is doing nothing useful.

It does get two things right, recorded so nobody re-probes them: scripts do **not** run
(`<script>document.write('SCRIPT RAN')</script>` produced no such text), and it is fast once warm —
16ms for 500 paragraphs, after a 674ms first call that is WebKit spinning up.

**Why `WKWebView` instead.** The app already owns the pattern: `BrowserPane.swift` holds a
`WKWebView` in a `WebHolder` outside the view tree, keyed by agent, so state survives a pane switch,
and `BrowserPolicy` (`AgentsKit/Files/BrowserPolicy.swift`, already unit-tested) is the existing home
for "is this URL allowed". HTML in the pane is that machinery with three things turned off and one
turned on:

| Requirement | How |
|---|---|
| FR-011, no scripts | `WKWebpagePreferences.allowsContentJavaScript = false` |
| FR-011, no network | A `WKContentRuleList` blocking every load, compiled once; plus a navigation delegate that refuses non-`file:` subresources |
| FR-012, links | The navigation delegate sees the resolved absolute URL. Inside the browsable folder and readable → open it in the pane. Anything else → hand to `BrowserPolicy`, which already decides |
| FR-013, relative images | Free: `loadFileURL(_:allowingReadAccessTo:)` scoped to the folder makes them resolve |
| FR-004, paper | Our stylesheet, injected at document start, with the same measure and scale the Markdown view uses |

**Alternative rejected: parse HTML into `MarkdownBlock` and use one renderer.** Tempting — one
reading surface, no WebKit. But arbitrary HTML is not a subset of Markdown's twelve block kinds, and
an agent-generated report with a two-column layout would come out as a lie about what the file
contains. Rendering HTML as HTML and admitting it is a second path is more honest than pretending
one block model covers both.

**Consequence accepted**: two renderers, one typography. The stylesheet and the SwiftUI view read
the same scale from one place in `AgentsKit` so they cannot drift.

---

## 6. The measure: SC-003 is not reachable at the default pane width in `.body`

**Decision**: document prose is New York at 12pt (`.system(.callout, design: .serif)`), the text
measure is capped at **500pt**, and horizontal padding is **20pt**, shrinking to **12pt** as the pane
narrows.

This is the one place the spec's own numbers did not survive contact. SC-003 asks for 60–90
characters per line at the pane's default width. `SidebarFrame` puts that default at 380pt, with a
280pt minimum and a 900pt maximum. Measured the average advance of real prose in each candidate face:

| Style | pt | advance | chars at 340pt text width (380 pane, 20pt padding) | chars at 500pt cap |
|---|---|---|---|---|
| `.body` | 13.0 | 5.97 | **57** | 84 |
| `.callout` | 12.0 | 5.58 | **61** | 90 |
| `.subheadline` | 11.0 | 5.18 | 66 | 97 |
| New York 12pt | 12.0 | 5.56 | **61** | 90 |
| New York 13pt | 13.0 | 5.99 | 57 | 83 |

So `.body` at the default width gives 57 characters and **misses the spec's floor**. 12pt — either
`.callout` or New York at the same size — gives 61 and clears it. Going to 11pt would clear it by
more and start to read as small print.

The 500pt cap is the other end: at the 900pt maximum pane width an uncapped line would run to 154
characters. 90 characters at 5.56pt is 500pt, so that is the cap, and above it the surface simply
centres the measure and lets the pane be wide.

At the 280pt minimum, 12pt padding leaves 256pt and 46 characters. Below the floor, deliberately —
FR-005 says the padding gives way rather than the text, and 46 characters of readable prose beats 61
characters that do not fit.

**Why serif.** `design/logo/README.md` records the one house rule about visual spend: *"the app uses
colour for one thing only, which is something going wrong"*. A document therefore cannot announce
itself with colour. New York is a system face, so Dynamic Type and every accessibility setting keep
working, and it separates *document* from *chrome* without spending the one thing that is reserved.
Headings, code and UI stay on the system sans and mono faces already in use.

---

## 7. Preserving the reader's place has no existing machinery

FR-015 wants the scroll position kept when a file changes on disk. Today `FolderWatch` fires,
`reloadFile` reassigns `probe` unconditionally (`FilesPane.swift:232`), `FileLines` is rebuilt from a
new string, and the view jumps to the top. A grep finds four `ScrollViewReader`s in the whole app and
no `ScrollPosition`, no `scrollTargetLayout`, no `defaultScrollAnchor`.

**Decision**, in two parts:

1. **Do not reload when nothing changed.** `FileProbe` is `Equatable`. `FolderWatch` watches the
   whole of `agent.cwd`, so most of what it reports has nothing to do with the open file. Comparing
   before assigning turns the common case into no work at all, which is the cheapest possible way to
   preserve a scroll position.
2. **When it did change, restore by block.** Blocks get a stable positional identity, the scroll
   position is bound to the top visible block's id via `.scrollPosition(id:anchor:.top)` over a
   `.scrollTargetLayout()`, and after a reparse the view returns to the nearest surviving id.

Part 2 needs the identity fix anyway: `MarkdownBlock.id` currently returns `"hr"` for every rule
(`:47`), so any document with two horizontal rules already feeds `ForEach` duplicate IDs. One fix,
two requirements.

---

## 8. A line number and a rendered page do not mix

Not in the spec, found in the code. An agent can call `show_file` with a line
(`AgentsKit/Model/ShownFile.swift`), and the source view exists partly to serve it — `FileLines`
draws a numbered gutter and scrolls to the named row, with the doc comment *"an agent that says
'line 412' is naming something the reader has to be able to find"*.

A rendered page has no line 412.

**Decision**: when a file is opened with a line target (`state.openLine != nil`), it opens in source
view, whatever the reader's saved mode. The mode preference is not changed by this — go back and
open the same file yourself and it renders. This is a rule about what was asked for, not a mode
switch behind the reader's back.

---

## 9. Where the code goes, and what can be tested

`Package.swift` states the architecture outright: *"AgentsKit holds everything that decides anything.
The app target is a window and a menu bar"*. There is one test target, `AgentsKitTests`, Swift
Testing throughout, no app test target, no UI or snapshot tests anywhere.

So everything that decides goes in `AgentsKit` and gets tested — which document type a file is, the
parse, front matter stripping, checkbox extraction, link classification, image path resolution, and
the measure-and-padding arithmetic as a pure function of width. What is left in `App/Sources` is
views that read those answers and draw them.

The two properties most worth a test, because they are what the feature rests on: **every one of the
twelve block kinds maps to something** (a total switch, the same shape as 004's "grouping is total
over `AgentState.allCases`"), and **a link is classified in-folder or out**, because that is the one
place this feature could send a reader somewhere they did not ask to go.

---

## Open, and deliberately not resolved here

**Selection across blocks.** FR-014 wants a drag across a paragraph to copy readable prose. A
rendered document is many SwiftUI `Text` views, and `.textSelection(.enabled)` is applied per view.
Whether a drag spans them on macOS 27 is a thing to find out by running the app, not by reading. It
is not a blocker: chat has had exactly this shape since 002, so the pane is no worse than the surface
next to it, and FR-007's source toggle gives a whole-file selection in one view whenever the rendered
one falls short. Recorded in `quickstart.md` as the first thing to check with the app open.
