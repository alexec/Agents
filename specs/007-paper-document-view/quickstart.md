# Quickstart: verifying the paper document view

**Feature**: `007-paper-document-view` | **Date**: 2026-09-18

There is no app test target and no snapshot test in this repository, so everything the reader sees
is verified by opening the app and looking. What can be tested is in `AgentsKit`, and step 1 covers
it. Steps 2 onward are the manual pass, ordered so the layout is judged before any depth is built.

## Prerequisites

- macOS 27, Xcode 27, Apple silicon. Same as the rest of the project.
- No new tool, no package to fetch. The feature adds no dependency.
- This repository is its own test corpus: 1,634 Markdown files, 224 with front matter, 2,212 task
  checkboxes, nesting to depth 9. Point an agent at the repo root and the files pane has everything.

```sh
swift test --package-path Packages/AgentsKit
xcodegen generate     # only if project.yml changed
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

---

## 1. The kit, before the app

```sh
swift test --package-path Packages/AgentsKit
```

**Expected**: green, including the 19 existing cases in `Unit/MarkdownBlockTests.swift`. Those are
the regression suite for replacing the parser's insides — if one of them fails, either the swap lost
something or the case was asserting a behaviour the research proved wrong. Say which, in the commit.

New suites that must be present and green: `FrontMatterTests`, `DocumentKindTests`,
`DocumentLinkTests`, `PageMetricsTests`, and the two cases the plan calls load-bearing — the switch
over the twelve block kinds is total, and a link is classified in-folder or out.

The corpus check is worth running once as a one-off rather than as a committed test, because it
walks the working tree:

**Expected**: 0 parse failures over every `.md` in the tree, mean under 5ms. That is SC-001 and
SC-002 in one run.

---

## 2. The layout, before anything else

Open the app on this repository, open the files pane, select `README.md`.

**Check first, because it decides whether the rest is worth building:**

- Does it read as a document — or as chat messages with a serif font? If the second, stop and fix
  the surface before building decisions 1 to 3 in the plan.
- Drag across two paragraphs and press ⌘C. **Does the selection span blocks?** This is the open
  question in research section 9. If it does not, the feature still ships — FR-007's toggle gives a
  whole-file selection — but record what actually happened, because the plan currently guesses.
- Drag the pane's resize handle from 280 to 900 and back. The text measure must grow, then stop at
  500pt and centre. Nothing should jump or reflow jerkily; `PageMetrics.forPane` being monotonic is
  what guarantees that, so a jump means the arithmetic is wrong, not the view.

**Expected against SC-003**: at the default 380pt width, a full line of prose is 60–65 characters.
Count one. The measurement says 61 at 12pt, and this is the spec number that did not survive `.body`.

---

## 3. Markdown, on files chosen to break it

| Open this | Expected | Covers |
|---|---|---|
| `specs/007-paper-document-view/spec.md` | Renders. Nested bullets indent by level. Tables line up with their column alignment. No `---` rule at the top and **no missing first heading** | US1, FR-003, front matter |
| `specs/005-mobile-remotes/tasks.md` | Checkboxes draw as checkboxes, not as `[ ]` text. They are not clickable | FR-003, read-only |
| `specs/007-paper-document-view/checklists/requirements.md` | Same, and the ticked ones read as ticked | FR-003 |
| Any file with a fenced code block | Monospaced, in its own block, with the language label. Long lines scroll sideways inside the block without widening the page | FR-020 |
| `README.md` | Relative links to files in the repo are live. `https://` links are not opened by the pane | FR-012 |

Then the deliberate awkward cases:

- **A file over 128 KB.** The truncation notice must be visible **below the rendered page**, not only
  in source view (FR-016). Find or make one; `FileProbe.prefixLimit` is the boundary.
- **A `.md` file that is actually binary.** Must show the icon-and-description view, not an empty
  page (FR-002).
- **A file saved with CRLF line endings.** Must not gain a blank line between every line. This is a
  bug the current parser has and the new one must not.

---

## 4. The toggle

1. With a document open, use the control at the trailing end of the header bar. Source appears, with
   the numbered gutter, exactly as today.
2. Go back, open a different `.md`. **It also opens in source** — the choice carried (FR-008).
3. Toggle back to rendered. Open a `.swift` file. **No toggle is shown** and it looks exactly as it
   does on `main` (FR-009).
4. Have an agent call `show_file` with a line number. **The file opens in source, scrolled to the
   line**, and going back and opening it yourself renders it — the saved mode was not changed
   (plan decision 5).

---

## 5. HTML

Put a generated HTML report in the folder. One with a table, a relative image, a relative link, an
`https://` link, a `<script>` that would write text into the page, and a remote `<img>`.

- The prose renders on the same surface with the same margins as Markdown (US3).
- **The script's text is absent.** Nothing it would have written appears (FR-011).
- **No network request is made.** Watch the remote image: it must not load, and the page must not
  show a broken-image glyph (FR-011, FR-013). Confirm with Charles or Console rather than by eye if
  there is any doubt — this is a security requirement, not a cosmetic one.
- The relative image appears. The relative link opens that file in the pane. The `https://` link does
  not navigate the pane.
- An HTML file whose body is built entirely by script says so in prose rather than showing an empty
  page (FR-018).

---

## 6. While it changes underneath

1. Open a Markdown document and scroll to the middle.
2. Have an agent edit an **unrelated** file in the same tree. **Nothing moves.** The probe was equal,
   so nothing reloaded (plan decision 6).
3. Have it edit the open file. The page updates and the reader stays roughly where they were
   (FR-015).
4. Have it delete the open file. The existing "is not there any more" prose appears, as today.

---

## 7. Appearance and accessibility

- Switch the system between light and dark. Legible in both; no colour literal should exist to go
  wrong (FR-019).
- Raise the system text size. The page follows, and the measure narrows in characters rather than
  clipping — every face is a semantic or relative style, so this is the check that no fixed point
  size crept in.
- Increase contrast, then reduce transparency. Nothing should disappear.

---

## Definition of done

Every box in `checklists/requirements.md` still passes, `swift test` is green, sections 2 through 7
have been walked with the app open, and the one open question in section 2 — whether selection spans
blocks — has an answer written into `research.md` rather than a guess.
