# Data Model: Paper Document View

**Feature**: `007-paper-document-view` | **Date**: 2026-09-18

Nothing here is persisted except one preference. There is no file on disk, no record, no schema and
no migration. These are the values that pass between the parse and the page.

---

## `DocumentKind`

*New. `Packages/AgentsKit/Sources/AgentsKit/Files/DocumentKind.swift`*

Which of the two renderable formats a file is, or neither. The spec's "Document type" entity.

| Case | Extensions |
|---|---|
| `.markdown` | `md`, `markdown`, `mdown`, `mkd` |
| `.html` | `html`, `htm`, `xhtml` |
| `nil` | everything else |

```
static func of(_ url: URL, probe: FileProbe) -> DocumentKind?
```

Two rules, both from the spec:

- A file the probe calls binary is never a document, whatever it is named. FR-002 says everything
  the pane classifies as binary keeps the behaviour it has, and a `.md` file full of NUL bytes is
  not a document because someone named it one.
- The extension is matched case-insensitively. `README.MD` is a document.

`FileProbe` is not changed. It answers "can this be read at all", which is a different question, and
its nine tests should keep meaning what they mean. `DocumentKind` sits beside it and reads the URL.

**Validation**: extension lookup only. No content sniffing — an HTML file whose body is built by
script is still an HTML file, and FR-018 is what covers the reader being told there is nothing in it.

---

## `MarkdownBlock`

*Changed. `Packages/AgentsKit/Sources/AgentsKit/Model/MarkdownBlock.swift`*

The same enum chat already renders, grown to carry what Foundation's parser sees. Contract detail
in [contracts/document-model.md](./contracts/document-model.md); the shape:

```
enum MarkdownBlock: Hashable, Sendable, Identifiable
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, start: Int, items: [Item])
    case quote([MarkdownBlock])
    case code(language: String?, text: String)
    case table(Table)
    case image(source: String, alt: String)
    case rule

    struct Item: Hashable, Sendable
        var blocks: [MarkdownBlock]
        var checked: Bool?        // nil unless the item began [ ], [x] or [X]
```

What changed and why is in plan decision 1. The three that matter for anyone reading the model:

- **`items` hold blocks, not strings.** That is what nesting is. Measured depth in this repository
  is 9.
- **Payloads are `AttributedString`.** Inline emphasis, code spans and links come out of the one
  parse. Today `MarkdownText.inline` re-parses each paragraph separately, which is a second parse
  that can disagree with the first.
- **`id` is positional**, assigned on the way out of `parse`, not derived from content. Two identical
  paragraphs are two blocks, and `.rule` stops returning `"hr"` for all of them.

**Relationships**: `Item.blocks` is recursive, and so is `.quote`. `Table` is unchanged from today —
`header`, `columns` of `.leading`/`.centre`/`.trailing`, `rows` — because Foundation gives the same
per-column alignment the current parser reads from the delimiter row.

**Validation**: `parse` is total. It never throws and never drops a run: anything Foundation returns
with no presentation intent becomes `.code(language: nil, …)`, which is how raw HTML inside Markdown
keeps the promise `MarkdownBlockTests.nothingIsLost` already makes.

---

## `FrontMatter`

*New. `Packages/AgentsKit/Sources/AgentsKit/Model/FrontMatter.swift`*

```
static func strip(_ source: String) -> String
```

Removes a leading `---` line, everything up to the next `---` line, and the blank line after it.
Returns the source unchanged if the first line is not exactly `---`, or if no closing `---` is found.

**Validation**, and the whole reason this exists: the rule is positional. A `---` anywhere but the
first line is a thematic break and must stay one. Research section 3a has both probes — the leading
case swallows the heading that follows it, the mid-document case parses correctly and must not be
touched.

The stripped text is discarded, not returned. Front matter is metadata for tooling; the reader
opened a document.

---

## `DocumentLink`

*New. `Packages/AgentsKit/Sources/AgentsKit/Files/DocumentLink.swift`*

Where a link inside a rendered document goes. The one place this feature could send a reader
somewhere they did not ask to go, so it is a value with tests rather than a branch in a view.

```
enum DocumentLink: Hashable, Sendable
    case file(URL)      // open it in the pane
    case web(URL)       // hand to BrowserPolicy
    case refused        // neither

static func of(_ raw: String, in document: URL, folder: URL) -> DocumentLink
```

| Input | Result |
|---|---|
| `./other.md`, `sub/thing.md` | `.file` — resolved against the document's own directory, then standardised |
| `https://…`, `http://…`, `mailto:…` | `.web` |
| `#anchor` | `.refused` for now — there is no outline to jump to |
| `../../../etc/passwd` | `.refused` — resolves outside `folder` |
| A path that is not a readable regular file | `.refused` |

**Validation**: resolution is `URL(string:relativeTo:)` then `.standardizedFileURL`, and the result
must be prefixed by the standardised `folder`. The check is on the resolved path, not the raw string,
because `a/../../b` is only visible as an escape after resolving. `folder` is the browsable root the
pane is showing, not the document's directory — a link may go up a level within the project and
still be legitimate.

`.web` does not open anything itself. It hands the URL to `BrowserPolicy.decide`, which is the
existing, already-tested home for that decision, and which allows `http`, `https`, `about` and
`file`.

---

## `PageMetrics`

*New. `Packages/AgentsKit/Sources/AgentsKit/Files/PageMetrics.swift`*

The reading surface as arithmetic, so the SwiftUI view and the webview stylesheet cannot drift, and
so the numbers in research section 6 are held by a test rather than by a comment.

```
struct PageMetrics: Hashable, Sendable
    var measure: Double     // maximum text width in points
    var padding: Double     // horizontal, each side

    static func forPane(width: Double) -> PageMetrics
    static let measureCap: Double = 500
    static let widePadding: Double = 20
    static let tightPadding: Double = 12
```

| Pane width | padding | measure | characters at 12pt |
|---|---|---|---|
| 280 (minimum) | 12 | 256 | 46 |
| 380 (default) | 20 | 340 | 61 |
| 620 | 20 | 500 (capped) | 90 |
| 900 (maximum) | 20 | 500 (capped) | 90 |

**Validation**: `measure` never exceeds `measureCap`; `padding` never leaves less than 200pt of
measure; `forPane` is monotonic in width, which is the property that stops the page jumping about
while the reader drags the resize handle.

Type sizes are not in this struct. They are semantic SwiftUI styles — `.system(.callout,
design: .serif)` for prose, the existing sans for headings and chrome, mono for code — because fixed
points would break Dynamic Type, which FR-019 requires. The stylesheet mirrors them with the
resolved point sizes at render time.

---

## `DocumentMode`

*New, stored. `App/Sources/Sidebar/SidebarState.swift`, on `SidebarFrame`*

```
enum DocumentMode: String { case rendered, source }
```

The reader's rendered-or-source choice. **On `SidebarFrame`, not `AgentPaneState`** — FR-008 says the
choice carries to the next document opened in the session, and `AgentPaneState` is per agent, per
window and not persisted, so a choice made there would be forgotten on the next agent. `SidebarFrame`
is the window-level, `UserDefaults`-backed object that already holds the pane width and the selected
pane.

Default `.rendered` (FR-006). One new key; nothing else about the window's stored state changes.

**Not stored**: which mode a particular file is showing. A `show_file` line target forces source view
for that opening (plan decision 5) without writing anything, so the reader's saved choice survives an
agent pointing at a line.
