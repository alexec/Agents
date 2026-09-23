# Quickstart: Live Artifacts, A Proof Of Concept

How each slice is run and seen. Nothing here is a unit test; those are listed in
[plan.md](./plan.md). This is the walk.

## Prerequisites

```sh
xcodegen generate
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
swift test --package-path Packages/AgentsKit
```

Run the built app beside the ordinary one so nothing here touches real agents:

```sh
open -n build/DD/Build/Products/Debug/Agents.app --args --root /tmp/agents-022
```

Make a scratch project folder, add it in the app, and start a Claude agent in it. Have a
second agent on Grok or Copilot ready for Slice F.

## Slice A — the page follows the agent

1. Ask the agent: *"Write /tmp/scratch/notes.md in four separate steps: a title and one
   paragraph; then a section 'Plan' with three bullets; then rewrite the first paragraph;
   then a section 'Open questions' at the end. Call show_file on it before you start."*
2. Open the sidebar on Files if the agent's call did not open it.
3. **Seen**: the page renders on paper; each step appears within a second; the changed
   passage is tinted and the tint fades; the view is on the newest change, including the
   jump back to the first paragraph on step 3. Screenshot each step.
4. Drag the sidebar to its widest. **Seen**: the page centres at its measure. Note in
   findings whether it wants a window of its own.

## Slice B — attention

1. Ask: *"Show me the 'Plan' section of notes.md."*
   **Seen**: the agent names a line; the page stays a page, scrolls to the passage holding
   that line and marks it; the agent's reply says the line it opened at.
2. Ask: *"Show me line 400 of notes.md."* (a line past the end) **Seen**: the page is at
   its last passage, marked; nothing is blank and no source view appears.
3. In a fresh conversation, ask for a new document *without* mentioning `show_file`.
   Record in findings whether the page opened by itself. Repeat once per runtime.

## Slice C — typing on the page

1. With the agent idle, click into the first paragraph on the page. **Seen**: an editor in
   the same face and width, caret where you clicked.
2. Type a sentence, stop, count two seconds, then `cat /tmp/scratch/notes.md`.
   **Seen**: the sentence is in the file; the page shows it rendered once you click away.
3. Click a heading, change a word, press Escape. **Seen**: rendered, saved.

## Slice D — the merge

1. Click into the last passage and start typing. While typing, ask the agent (from the
   chat, mid-sentence): *"Rewrite the first paragraph of notes.md."*
   **Seen**: the first paragraph changes and is tinted; your editor stays open, caret
   where it was, the view does not move. `cat` the file after pausing: both changes there.
2. Click into the 'Plan' bullets and type. Ask the agent: *"Replace the Plan bullets with
   two new ones."* **Seen**: your editor keeps your text; a card appears under it with the
   agent's two bullets and a button to take them; the file holds yours. Press the button.
   **Seen**: the agent's version replaces yours on the page and on disk.
3. Edit the file in another editor and save. **Seen**: the page updates and marks it, and
   does not scroll if you were typing.

## Slice E — pictures

1. Ask: *"Add a section 'Shape' to notes.md with a diagram of three boxes joined by
   arrows, drawn as an SVG file beside it."*
   **Seen**: the SVG draws as a picture at its reference and is marked as it arrives.
2. Ask: *"Make the boxes in the diagram round."* **Seen**: the picture changes and is
   marked, and the view goes to it; the document's text did not change.
3. Delete the SVG file in the terminal. **Seen**: the alternative text in its place; the
   page carries on.
4. In a fresh conversation, ask for a document *with a graph of five numbers* and do not
   say how. Record in findings what the agent wrote: an SVG, Mermaid, a table, ASCII.
   Repeat once per runtime — this is the Mermaid measurement.

## Slice F — telling the agent

1. Rewrite the first paragraph on the page. Pause. Ask the agent: *"Continue the document
   with one more section."* **Seen**: its write keeps your paragraph. Check the daemon
   log for the turn's outgoing blocks to confirm the note went and read as in
   [contracts/daemon-api.md](./contracts/daemon-api.md).
2. Repeat with a paragraph edit made *while* the agent is mid-turn on the same file.
   Record what each runtime did: refused its own stale edit and re-read, overwrote, or
   something else.

## Slice G — findings

Walk A–F with a second runtime. Fill every row of the table in
[findings.md](./findings.md). The PoC is done when no row is blank.
