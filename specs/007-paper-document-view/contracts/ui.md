# Contract: what the pane does, and when

**Feature**: `007-paper-document-view`

The pane's behaviour, stated as rules so the acceptance scenarios in `spec.md` have something exact
to check against. No app test target exists in this repository, so these are verified by running the
app — [quickstart.md](../quickstart.md) walks them.

---

## Choosing what to show

Evaluated in order when a file is opened. The first rule that matches wins.

| # | Condition | Result | Requirement |
|---|---|---|---|
| 1 | `probe.kind == .binary` | The icon-and-description view, unchanged | FR-002 |
| 2 | `DocumentKind.of(...) == nil` | `FileLines`, unchanged | FR-009 |
| 3 | `state.openLine != nil` | `FileLines`, scrolled to the line. The saved mode is **not** changed | plan decision 5 |
| 4 | `frame.documentMode == .source` | `FileLines` | FR-007 |
| 5 | Rendering failed | `FileLines` plus one line of prose saying why | FR-017 |
| 6 | otherwise | The rendered document | FR-006 |

Rule 3 is the one that will look surprising in use, so it is worth stating plainly: an agent saying
"look at line 412" gets the numbered view, because a rendered page has no line 412, and the reader's
own preference is left alone.

---

## The toggle

- Lives at the trailing edge of the existing header bar in `FilesPane`, where there is a `Spacer()`
  and nothing after it today.
- Shown only when rules 1 and 2 above did not match — a `.c` file has nothing to toggle.
- One control, two states, icon-only, matching the `.borderless` chevrons already in that bar.
- Writes `SidebarFrame.documentMode`, so the next document opened in this window follows (FR-008).
- Does **not** appear or change state because of rule 3. A line target overrides the view, not the
  preference.

---

## The reading surface

- Width comes from the pane; `PageMetrics.forPane` turns it into a measure and a padding.
- The measure is centred when the pane is wider than `measure + 2 × padding`.
- No border, no shadow, no drawn sheet edge (FR-004, settled during specify).
- No colour literal anywhere on it. Contrast and hierarchy come from `.secondary`, `.tertiary`,
  `.quaternary` and type (FR-019, and the house rule that colour means something is wrong).
- Prose is `.system(.callout, design: .serif)`. Headings step through the existing semantic sans
  styles. Code stays monospaced. Every one is relative, so Dynamic Type works.

Block-by-block, the twelve kinds and what each draws, is `MarkdownText`'s job and is covered by the
totality test rather than restated here.

---

## Links and images

| The reader clicks | What happens |
|---|---|
| `DocumentLink.file` | The pane opens it, exactly as selecting it in the listing would. The back chevron returns to the listing, not to the previous document |
| `DocumentLink.web` | Handed to `BrowserPolicy`. The pane does not navigate |
| `DocumentLink.refused` | Nothing. No alert, no flash — a link that goes nowhere is not an error the reader caused |

Images resolve against the document's own directory. An image that cannot be resolved, or is remote,
shows its alt text in place (FR-013). Remote images are never fetched — that is the same rule as
FR-011, applied to Markdown.

---

## HTML

- Scripts never run: `allowsContentJavaScript = false`.
- No network request is ever made: a compiled `WKContentRuleList` blocks every load, and the
  navigation delegate refuses anything that is not the `file:` URL being shown.
- Loaded with `loadFileURL(_:allowingReadAccessTo:)` scoped to the browsable folder, so relative
  images and links resolve and nothing outside it can be read.
- The stylesheet is injected at document start and built from `PageMetrics`.
- Link clicks are intercepted by the navigation delegate and routed through `DocumentLink`, the same
  three outcomes as above.
- The webview is held outside the view tree, keyed like `BrowserPane`'s, so switching panes does not
  reload the document.
- A document that renders to nothing — a script-built page, with scripts off — says so in prose
  rather than showing an empty page (FR-018).

---

## While the file changes underneath

1. `FolderWatch` fires. `FileProbe.read` runs.
2. If the new probe equals the old one, **stop**. No reparse, no view change, no scroll movement.
   This is the common case, because the watch covers the whole of `agent.cwd`.
3. Otherwise reparse, and restore the scroll position to the nearest surviving block id.
4. The truncation notice, if any, is drawn below the document in both modes — lifted out of the
   `.text` branch where it lives today (FR-016).

---

## What the pane still refuses to do

Read-only, completely (FR-017). No selection of text turns into an edit, no link writes anything, the
webview cannot navigate itself, and no control this feature adds writes to a project's directory.
