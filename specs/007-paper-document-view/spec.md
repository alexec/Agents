# Feature Specification: Paper Document View

> **Obsolete — 2026-09-20.** Retired by Alex before it was ever tasked. The plan, contracts and data model stay as a record of the thinking; nothing here is to be built.

**Feature Branch**: `007-paper-document-view`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "rendering Markdown (and HTML, other common doc types) in the file-browser on a nice paper format"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Read a Markdown file as a finished document (Priority: P1)

Someone working with an agent opens the files pane, taps a `.md` file — a README, a spec, a plan the agent just wrote — and sees it the way it was meant to be read: headings that look like headings, lists that indent, tables that line up, code in its own block. Not a wall of monospaced hash marks and pipes. The text sits on a page: comfortable margins, a line length short enough to read without losing your place, a surface that reads as paper rather than as a terminal.

**Why this priority**: This is the whole feature. Most of what an agent writes and most of what it is pointed at is Markdown — specs, plans, notes, READMEs. Today reading any of it means either squinting at raw source in a narrow pane or leaving the app entirely. Shipping only this story already removes the reason to leave.

**Independent Test**: Open the files pane on this repository, select `README.md` and then any file under `specs/`. Both render as formatted documents on a paper surface. Nothing else in the pane needs to change for this to be worth having.

**Acceptance Scenarios**:

1. **Given** the files pane is showing a folder containing `README.md`, **When** the reader selects that file, **Then** the pane shows the document rendered — headings, paragraphs, bullet and numbered lists, block quotes, tables, horizontal rules, fenced code blocks, and inline bold, italic, code spans and links — laid out on a page-like surface.
2. **Given** a rendered Markdown document is open, **When** the reader drags across a paragraph and copies, **Then** the copied text is the readable prose, not the source markup.
3. **Given** a rendered Markdown document is open, **When** the agent rewrites that file on disk, **Then** the rendered view updates to the new content and the reader's place in the document is preserved.
4. **Given** a Markdown file longer than the pane can hold, **When** the reader scrolls, **Then** the page scrolls smoothly and headings remain legible at the pane's current width.

---

### User Story 2 - Fall back to the source when the rendering hides something (Priority: P2)

Sometimes the rendered form is the wrong form. The reader wants to see the exact markup — the literal link target, the indentation of a nested list, the front matter, whether that was a tab or four spaces. One control flips the open file between the rendered page and the raw source, and back.

**Why this priority**: Rendering without an escape hatch makes the pane less useful than it is today for anyone checking what a file literally contains. The toggle is what makes rendering-by-default safe to ship.

**Independent Test**: Open any Markdown file, use the toggle, confirm the exact bytes appear as monospaced source, toggle back, confirm the rendered page returns.

**Acceptance Scenarios**:

1. **Given** a rendered document is open, **When** the reader activates the source control, **Then** the pane shows the file's text as monospaced source, exactly as it is on disk.
2. **Given** the reader has switched to source, **When** they open a different renderable file, **Then** that file also opens in source view — the choice persists for the session rather than resetting on every file.
3. **Given** a file whose content cannot be rendered — malformed markup, or a type that turns out not to be a document after all — **When** the reader opens it, **Then** the pane shows the source view with a short, plain notice explaining why, rather than a blank page or an error.

---

### User Story 3 - The same treatment for HTML (Priority: P3)

The folder holds an HTML report an agent generated. It gets the same reading surface Markdown does — same margins, same typographic scale, same source toggle — so the pane has one way of showing a document rather than one special case per format.

**Why this priority**: Real value, but narrower and riskier than Markdown — HTML brings questions about scripts, remote content and fidelity that Markdown does not. It should follow the Markdown story rather than hold it up.

**Independent Test**: Put an HTML file in a folder, open it, and confirm it renders on the same surface with the same margins, typography and toggle behaviour as Markdown.

**Acceptance Scenarios**:

1. **Given** an HTML file in the open folder, **When** the reader selects it, **Then** its content renders as a formatted document, with no scripts executed and no network requests made on its behalf.
2. **Given** an HTML document that references a remote image or stylesheet, **When** it renders, **Then** the document still reads sensibly and the missing remote content is simply absent — the reader is not shown a broken or half-loaded page.

---

### Edge Cases

- **Truncation.** The pane reads only the first portion of a large file. A document cut mid-way can end inside an unclosed code fence, table or list. The rendered page must still render what it has, and the "this file was truncated" notice must remain plainly visible in rendered mode, not only in source mode.
- **Relative links.** A README links to `./CONTRIBUTING.md` and to `https://example.com`. The two need different destinations, and a link pointing outside the folder the reader is browsing must not silently escape it.
- **Relative images.** A document references `./docs/diagram.png`. Either the image resolves and appears, or its alternative text stands in — never a broken-image glyph.
- **Narrow pane.** The sidebar pane is resizable and can be dragged quite narrow. A page with generous margins can leave almost no room for text. Below some width the page has to give up its margins gracefully rather than squeeze the text to a sliver.
- **Wrong extension.** A file named `.md` that is actually binary, or an `.html` file that is a template full of unrendered placeholders.
- **HTML that is not a document.** A single-page application shell, or a file whose entire body is built by script. With scripts off there is nothing to show; the reader needs to be told that rather than handed an empty page.
- **Very wide content.** A table with twenty columns, or a code block with 400-character lines, inside a narrow pane.
- **File disappears** while open — already handled today, and must stay handled in rendered mode.
- **Appearance and text size.** The page must be legible in both light and dark appearance and at the reader's chosen system text size.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST recognise which of the files it can open are documents suitable for rendering, and treat all other files exactly as it does today.
- **FR-002**: The set of renderable document types MUST be Markdown and HTML, and no others. Every other file — plain text, source code, data files, and anything the pane classifies as binary — MUST keep the behaviour it has today.
- **FR-003**: Rendered Markdown MUST present headings by level, paragraphs, bullet and numbered lists, block quotes, fenced code blocks with their language label, tables with column alignment, horizontal rules, and inline emphasis, strong emphasis, code spans and links.
- **FR-004**: Rendered documents MUST be presented on a reading surface that fills the pane's width, with generous internal padding and a text measure capped for comfortable reading rather than running the full width. The surface MUST NOT be drawn as a discrete sheet with visible edges and a surrounding margin — a narrow, resizable pane cannot spare the horizontal room, and the paper quality comes from typography and spacing rather than from a drawn page.
- **FR-005**: As the pane narrows, the reading surface MUST give up its padding progressively rather than squeezing the text measure, so that text stays readable at the narrowest width the pane allows.
- **FR-006**: Rendered documents MUST use a typographic hierarchy — a reading typeface for prose, distinct sizes and weights for heading levels, and a monospaced face only for code — rather than the single monospaced face used for source.
- **FR-007**: Recognised document types MUST open in rendered form by default.
- **FR-008**: Readers MUST be able to switch the open file between rendered and source views with a single action, and switch back.
- **FR-009**: The reader's choice of rendered or source MUST carry across to the next document they open within the session.
- **FR-010**: Files that are not recognised documents MUST continue to open in the existing monospaced source view, unchanged.
- **FR-011**: HTML documents MUST render without executing any script contained in them and without issuing network requests on their behalf.
- **FR-012**: Links within a rendered document that point to another file in the browsable folder MUST open that file in the pane; links pointing elsewhere MUST NOT navigate the pane, and MUST instead be handed to the surface that already handles web addresses.
- **FR-013**: Images referenced relatively from a rendered document MUST resolve against the document's own location and display; when an image cannot be resolved or is remote, its alternative text MUST be shown in its place.
- **FR-014**: Text in a rendered document MUST be selectable, and copying selected text MUST yield the readable prose rather than the underlying markup.
- **FR-015**: When the open file changes on disk, the rendered view MUST update and the reader's scroll position MUST be preserved as closely as the new content allows.
- **FR-016**: When a file's content has been truncated for reading, the rendered view MUST carry the same truncation notice the source view carries.
- **FR-017**: When a document cannot be rendered, the system MUST fall back to the source view and state plainly why, rather than failing silently or showing an empty page.
- **FR-018**: The pane MUST remain strictly read-only — rendering introduces no way to edit a file.
- **FR-019**: Rendered documents MUST be legible in both light and dark appearance and MUST honour the reader's system text size setting.
- **FR-020**: Content wider than the text measure — wide tables, long code lines — MUST be reachable without the surrounding layout breaking.

### Key Entities

- **Document**: A file the pane has read and classified as renderable. Carries its content, its location (needed to resolve relative links and images), its document type, and whether its content was truncated.
- **Document type**: Which of the two renderable kinds a file is — Markdown or HTML — determining how it is rendered. Distinct from the existing text/binary distinction, which only says whether the file can be read at all.
- **View mode**: Rendered or source. A reader-facing choice that persists across files for the session.
- **Reading surface**: The presentation a rendered document sits on — its padding, its text measure, its typographic scale. Shared by both document types so that every rendered file looks like the same publication.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every Markdown file in this repository's `specs/`, `docs/` and root directories renders with no visible layout defects — no raw markup leaking through, no overlapping or clipped text, no collapsed tables.
- **SC-002**: A reader opening a typical document file sees the rendered page within the same moment they see the source view today — no perceptible delay is introduced by rendering.
- **SC-003**: Body text in a rendered document holds a line length in the 60-to-90-character range at the pane's default width.
- **SC-004**: Getting from a rendered document to its exact source, and back, takes one action each way.
- **SC-005**: A reader can read a full specification document end to end inside the pane without opening another application; in trial use, no participant leaves the app to read a Markdown file.
- **SC-006**: Opening a document that cannot be rendered never results in a blank pane or an unexplained failure — every such case shows readable content plus a reason.

## Assumptions

- The files pane stays a single-pane push: selecting a file replaces the folder listing, with a back control. Rendering does not introduce a split preview layout.
- Rendering is a read path only. No editing, no saving, no round-tripping a rendered document back to source.
- The pane continues to read only the leading portion of a file rather than loading arbitrarily large documents into memory; rendering inherits that limit and surfaces it.
- HTML is rendered for reading, not for fidelity to a browser. A document that depends on scripts, remote stylesheets or web fonts to make sense is out of scope; the goal is that its prose reads well.
- The existing Markdown understanding used for agent chat messages is the natural starting point for document rendering, so the two surfaces agree on what Markdown means. Document rendering will need more of Markdown than chat does — nested lists, images, front matter, task lists — so some growth there is expected.
- Plain text, CSV, JSON and source files stay on the existing monospaced source view. They were considered and deliberately left out: widening the set is a later decision, not a gap in this one.
- The reading surface fills the pane rather than being drawn as a discrete sheet. A sheet with visible edges reads most literally as paper but costs horizontal room the sidebar cannot spare; if the pane later gains a wide or detached mode, a sheet becomes worth revisiting.
- Files continue to come from the local file system. Rendering documents held on a remote machine is out of scope and would require capabilities the daemon does not have.
- The feature is macOS-only, matching the app.
- The project constitution is currently an unfilled template, so no project-specific principles constrain this specification.
