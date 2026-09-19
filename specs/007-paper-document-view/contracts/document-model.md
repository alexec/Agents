# Contract: the `AgentsKit` surface the views read

**Feature**: `007-paper-document-view`

This app has no external API to version. Its contracts are the boundary between the kit, which
decides, and the app target, which draws. Everything below is `public` in `AgentsKit` and reachable
from `swift test`. Shapes are in [data-model.md](../data-model.md); this is what each promises.

---

## `MarkdownBlock.parse(_ markdown: String) -> [MarkdownBlock]`

*Changed. The signature is the same; chat keeps compiling.*

**Promises.**

1. **Total.** Never throws. Never returns a partial document. Every run Foundation produces reaches
   a block — including runs with no presentation intent, which become `.code(language: nil, …)`.
   `MarkdownBlockTests.nothingIsLost` already asserts this for HTML and keeps asserting it.
2. **Front matter is gone.** A leading `---` block is stripped before parsing (`FrontMatter.strip`).
   A `---` anywhere else is `.rule`.
3. **Nesting is preserved to any depth.** `.list` items hold blocks; `.quote` holds blocks. Depth 9
   occurs in this repository and must round-trip.
4. **Ordinals are real.** `.list(ordered: true, start:)` carries the author's first number. The
   current renderer renumbers from 1 and will stop.
5. **Checkboxes are structure, not text.** An item beginning `[ ] `, `[x] ` or `[X] ` has that
   prefix removed and `checked` set. Any other bracket text is left alone.
6. **Ids are unique within one call** and stable for the same input. Positional, not content-derived.
7. **CRLF is one line break.** `\r\n` does not produce a blank line.
8. **Inline marks arrive once.** Payloads are `AttributedString` carrying emphasis, code spans and
   link destinations from the same parse. No consumer should re-parse a payload.

**Does not promise**: reference-style link resolution, footnotes, definition lists, or anything else
outside the twelve `PresentationIntent` kinds the research enumerated. Those arrive as text and are
shown as text.

**Breaking for existing callers**: `.bullets`, `.numbered` and `.quote(String)` are gone;
`App/Sources/Chat/MarkdownText.swift` is the only consumer and changes with them.

---

## `DocumentKind.of(_ url: URL, probe: FileProbe) -> DocumentKind?`

**Promises.**

1. `nil` whenever `probe.kind` is `.binary`, whatever the extension says.
2. Extension match is case-insensitive.
3. Pure. No file system access — the caller already has the probe.

**Contract with `FilesPane`**: `nil` means render nothing new. The file takes the path it takes
today, unchanged, which is FR-009's whole content.

---

## `DocumentLink.of(_ raw: String, in document: URL, folder: URL) -> DocumentLink`

**Promises.**

1. **No escape.** `.file` is returned only when the resolved, standardised URL is inside the
   standardised `folder`. The check is on the resolved path, never on the raw string.
2. **No guessing.** A path that resolves inside the folder but is not a readable regular file is
   `.refused`, not `.file`. Being told a link goes nowhere beats a pane that empties.
3. **`.web` decides nothing.** The URL is handed to `BrowserPolicy.decide`, which already allows
   `http`, `https`, `about` and `file` and is already tested. This feature does not get its own
   scheme list.
4. Pure except for one `isReadableFile` check.

**This is the security boundary of the feature.** A rendered document is content the app did not
write, containing links the app did not choose. `.refused` is the default for anything unrecognised.

---

## `PageMetrics.forPane(width: Double) -> PageMetrics`

**Promises.**

1. `measure <= measureCap` (500) always.
2. `padding` is `widePadding` (20) when that leaves at least 200pt of measure, `tightPadding` (12)
   otherwise.
3. Monotonic: a wider pane never yields a narrower measure. This is what keeps the page still while
   the resize handle is dragged.
4. Pure, and the same values feed both renderers.

**Contract with the stylesheet**: `HTMLDocumentView` builds its CSS from this struct — `max-width`
from `measure`, `padding` from `padding` — so "the same reading surface" is a shared function rather
than two sets of numbers.

---

## `FrontMatter.strip(_ source: String) -> String`

**Promises.**

1. Strips only from the first line. `---` on line 2 or later is untouched.
2. Returns the input unchanged when there is no closing `---`. A document that opens with a rule and
   never closes is a document with a rule, not a broken header.
3. Never throws, never returns nil, never drops content after the closing marker.

---

## What is not in this contract

No daemon method. No notification. No new `DaemonAPI` entry, no change to `ShownFile`, no change to
`FileProbe`, `DirectoryReader`, `FolderWatch` or `TouchedPaths`. This feature reaches the daemon
nowhere, which is why it has no wire contract to break.
