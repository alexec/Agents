# Research: Live Artifacts, A Proof Of Concept

**Feature**: `022-live-artifacts` | **Date**: 2026-09-21

Everything below was checked against the code as it stands on `main` at `faeee46`, not
recalled. File paths are given so each claim can be re-read.

---

## 1. The page already exists; do not build a second one

**Decision**: The artifact page is `FilesPane` showing a new `LivePage` where it now shows
`DocumentView` — for `.md` files, with or without a named line. `DocumentView` stays as the
read-only renderer inside it.

**Rationale**: `App/Sources/Sidebar/FilesPane.swift` already: watches the agent's whole
folder with `FolderWatch` and re-reads the open file on any event; opens the file an agent
named via `state.openFile`/`openLine`; renders `.md` through `DocumentView` on
`PageMetrics`. Three of the spec's requirements (FR-002, FR-003, FR-008, FR-009) are met by
code that is already there. A new pane would copy all of it to change one view.

**Alternatives considered**: A new sidebar tab `.artifacts` — exists already
(`ArtifactsPane`) but means something else: things a runtime *handed over* as
`resource_link`s. Overloading it would confuse two features. A separate window — possibly
right, and exactly the kind of thing to decide by running the pane first; the sidebar can
already be dragged to 900 points (`SidebarFrame.maximumWidth`), which is wider than the
500-point measure the page caps at.

## 2. A passage is a run of source lines, not a parsed block

**Decision**: `Passage.split(_ text: String) -> [Passage]` splits on blank lines, keeping a
fenced code block whole, and each passage carries its source and its line range. Each
passage is rendered on its own by `MarkdownText(markdown: passage.source)`.

**Rationale**: `MarkdownBlock.parse` is built on `AttributedString(markdown:)`
(`Packages/AgentsKit/Sources/AgentsKitCore/Model/MarkdownBlock.swift`), and Foundation's
parser returns intents and text but **no source ranges**. A block cannot be mapped back to
the lines it came from, so it cannot be edited in place or named in a note to the agent.
Splitting the source first and parsing each piece gives the mapping for free, and
`MarkdownText` already accepts any string.

**What this costs**: a list whose items are separated by blank lines becomes several
passages, each a one-item list; a table is one passage (no blank lines inside it) and so is
a quote. Numbered lists restart at their own `start`, which `MarkdownBlock` already reads,
so `3.` stays `3.`. Front matter is one passage. Acceptable for a PoC and recorded as a
finding if it grates.

**Alternatives considered**: a whole-document `TextEditor` over an `AttributedString` styled
from the source (the Bear/Typora hybrid). One text view, trivially consistent with disk, and
the insertion point survives external replacement with an offset adjustment. Rejected for
the PoC because it is not a rendered page — the `#` and `**` stay visible — and the spec's
stated choice was the rendered page. It is the fallback if passage editing proves worse to
use, and is noted in findings either way.

## 3. What changed is a line diff, mapped to passages

**Decision**: `PassageChange.between(old: String, new: String) -> PassageChange` uses
`CollectionDifference` over lines, folds insertions and removals into a changed line range,
and returns the indices of the new passages that intersect it, plus the first. The page
marks those passages with a tint that fades over about two seconds and scrolls the first
into view.

**Rationale**: The agent's edit and write tools rewrite the file, so the disk only ever shows
before and after. ACP tool calls do carry `diff` content with a path — `TouchedPaths`
reads it — but that arrives on the transcript, not in step with the file, and Grok's writes
come through the daemon's own `fs/write_text_file` with no diff at all. A diff of the two
texts works for every writer and needs nothing from the runtime.

**Alternatives considered**: using the transcript's `diff` blocks to know the region. Cheaper
and more precise for Claude and Copilot, useless for Grok and for the person's other editor.
Could be layered on later; a finding if the line diff misplaces marks.

## 4. Attention is `show_file` as it is; a line becomes a passage

**Decision**: the `show_file` schema does not change. Its description gains one sentence:
a Markdown file opens as a live page that follows the agent's edits, so show it once when
you begin. A `line` named on a Markdown file goes to the passage that contains it —
`Passage.index(containing:)` over the ranges `Passage.split` already carries — and marks
it. `FilesPane` stops falling back to `FileLines` for `.md` when a line is named.

**Rationale**: FR-007 now says nothing the agent is given changes but a sentence. The
earlier draft added a `heading` argument on the reasoning in `FilesPane`'s own comment that
"a rendered page has no line 412". With passages carrying line ranges, it does: line 412 is
in some passage, and that is where the view goes. Agents already know line numbers from
their own edit tools; a heading they would have to quote exactly. `showFile` in
`DaemonCore+AppTools.swift` already checks the token, the scope and existence and
broadcasts `agent/showFile`; `ContentView.showWhatWasAskedFor` already applies it only to
the conversation on screen (FR-009). Nothing there changes.

**Alternatives considered**: a `heading` argument (the earlier draft) — one more field on
`ShownFile`, the schema, the daemon's lookup and the pane's state, to let an agent say a
thing it can already say with a number. Dropped by Alex on 2026-09-21. A `passage` index —
meaningless to an agent, which never sees the split.

**Open, to be measured in Slice B**: whether any runtime calls `show_file` when it *starts*
a document rather than when it is done. `Briefing.swift`'s comment records that no runtime
called `suggest_next_prompts` from the description alone. Expect the same; the fix is one
sentence in the briefing, added only once the measurement says so.

## 5. The person's edit is written by the daemon and remembered there

**Decision**: New request `artifact/write { agentID, path, text }`. The daemon checks the
path against `agent.folderScope`, writes atomically, and appends `ArtifactEdit(path, lines)`
to a per-agent, in-memory list. `beginTurn` (`DaemonCore+Commands.swift:631`) appends a
text block after the person's words — the same slot the briefing uses at line 659 — saying
which passages changed and what they now say, then clears the list. Nothing goes in the
transcript, as with the briefing.

**Rationale**: The README's rule that the daemon is the only writer is about its own store,
but the daemon is also what already writes project files on an agent's behalf
(`ACPSession.swift:550`) and what already knows the folder scope. Going through it makes
FR-016 possible with no second channel: the fact that the person edited is recorded at the
moment of the write. It also survives the window closing, so an edit made at the Mac and a
prompt sent from the phone still meet.

**Mid-turn**: an edit that lands while the agent is mid-turn cannot be told to the agent by
this path until its next turn. What protects it is the runtime's own stale-file guard —
Claude's edit tool refuses to edit a file changed since it last read it. Whether Grok,
Copilot and Cursor have one is precisely a finding (Slice F), and the single most likely
reason a real tool — "what changed in this document since I last wrote it", callable
mid-turn — is needed.

**Alternatives considered**: the app writing the file directly with `Data.write(to:options:
.atomic)`. Simpler, but then the daemon learns of the edit only by being told separately,
and two calls that can disagree replace one that cannot.

## 6. The merge is three strings and one moving part

**Decision**: `PassageMerge.apply(base: String, theirs: String, mine: Passage) ->
PassageMerge.Result` where `mine` is the person's edited passage with its line range *in
base*. It finds the passage's original lines in `theirs`; if they are present and contiguous,
the result is `.merged(text)` with the person's source spliced in at that place and the new
line range. If they are not — the agent changed those lines — the result is
`.collided(text, theirs: String)` where `text` has the person's passage put where the
agent's replacement for those lines now sits, and `theirs` is the agent's version for the
card.

**Rationale**: The person can only have one passage in flight, so the general three-way
problem collapses to "did the other side touch my lines". Line-exact matching is enough for
a PoC and is what makes the function testable in a dozen cases. The collision rule is what
FR-014 says: the person's text is kept and written, the agent's is shown, nothing vanishes.

**What the page does with it**: `.merged` replaces the page's passages, keeps the editor
open on the same passage at its new index, and does not scroll (FR-012, FR-013). `.collided`
does the same and raises a card under the editor with the agent's version and one button to
take it instead.

**Alternatives considered**: a CRDT or operational transform. Nothing here is concurrent in
the sense those solve — one person, one passage, whole-file writes at second granularity.
A finding if the PoC shows otherwise.

## 7. Images are already drawn; the mark is a stamp per file

**Decision**: `MarkdownText.image(source:alt:)` (`App/Sources/Chat/MarkdownText.swift:150`)
already resolves a relative path against the document and loads it with
`NSImage(contentsOf:)`, which reads SVG on this platform. Nothing is built for rendering.
For the mark, `LivePage` keeps `ImageStamps`: for every image passage, the resolved file
URL and its modification date and size at last load. On any `FolderWatch` event the stamps
are re-read; a passage whose image changed is marked and followed exactly like a changed
text passage, and its `Image` is given a new identity so SwiftUI reloads it.

**Rationale**: a redrawn diagram does not change the document's text, so the line diff
cannot see it. The stamp is the smallest thing that can. FSEvents already fires for the
folder the image is in, because the watch is on the agent's whole folder.

**Alternatives considered**: hashing the image bytes — slower, and modification date plus
size is enough for a file one writer rewrites whole. Re-rendering every image on every
event — cheap for one, wrong for a page of twenty, and loses the mark.

## 8. Graphs are pictures; nothing is drawn from data

**Decision**: a graph in a document is an SVG the agent writes beside it, drawn by decision
7. The page draws nothing from data. Decided by Alex on 2026-09-21 after a chart fence drawn
with Swift Charts was drafted and then dropped: the PoC is about the shared page, and a chart
format is a second thing to learn at once.

**Rationale**: it works today with no code; the agents can draw a passable bar or line chart
as SVG; and the mark from decision 7 covers a redraw.

**Alternatives considered, and kept on file for the real feature**:
- *A fenced block with a kind and CSV rows, drawn natively with Swift Charts.* Editable by the
  person as numbers, no tool needed, no web view. The right shape if graphs turn out to
  matter; the dropped draft was a header of kind, title and axis names, a `---`, then CSV.
- *Mermaid.* What an agent is most likely to write unasked. Needs a JavaScript renderer in a
  web view per block. Not built. **A findings candidate**: the PoC counts how often an agent
  writes a Mermaid fence without being told not to.
- *HTML as the document format, with a web view.* Does everything, including interactive
  charts, but editing a rendered HTML page in place is editable web content — a different and
  larger project than a text editor per passage — and the agent's edits to HTML are heavier
  and less legible in the transcript. It would trade the shared page for a browser.

## 9. Editing on the page is a `TextEditor` per passage

**Decision**: Clicking a rendered passage swaps it for `PassageEditor`, a SwiftUI
`TextEditor` bound to the passage's source, in the page's serif face, on the same
`PageMetrics` width. A 1 s pause or losing focus writes; clicking another passage or
pressing Escape closes it, writing first. Enter inside the editor is a newline; there is no
"done" control.

**Rationale**: macOS 27's `TextEditor` handles selection, undo and the insertion point, and
because the editor holds only one passage's source, an external change never has to replace
text under the caret — the rest of the page re-renders around it. That is what makes FR-012's
"insertion point does not jump" cheap.

**Alternatives considered**: `NSTextView` directly. Not needed until the finding says the
per-passage editor is the wrong shape.
