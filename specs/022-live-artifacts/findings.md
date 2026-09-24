# Findings: Live Artifacts, A Proof Of Concept

**Feature**: `022-live-artifacts` | **Status**: measured over the socket 2026-09-23 for four runtimes; the on-screen walks (marks, typing, the collision card, the image redraw) are still to be seen

This is the proof of concept's actual output (FR-017). Each row is a capability the agent
used, needed, or was missing, with the observation behind it. A row is not deleted when a
capability turns out to be unnecessary; it is marked so, with why, so it is not proposed
again.

## Runtimes walked

| Runtime | Date | Slices |
|---|---|---|
| Claude | 2026-09-23 | A (page seen, follow not yet), B, F measurements over the socket |
| Copilot | 2026-09-23 | F measurement over the socket |
| Cursor | 2026-09-23 | F measurement over the socket |
| Grok | 2026-09-23 | B and F measurements over the socket, write permissions answered by a script |

## Capabilities

| Capability | Status | Observation | Verdict for the real feature |
|---|---|---|---|
| `show_file` called unasked at the start of a document | measured 2026-09-23 | From the description alone, with the new paragraph in it: Claude 0/1, Grok 0/1 — neither called it. With one sentence in the briefing (`Briefing.liveDocument`): Claude 1/1, Grok 1/1, both before their first write, and both were told the page was open empty and would fill. | The sentence stays. The description alone does not make it happen; the briefing does, as it did for suggestions. |
| `show_file` with a line, landing on the right passage | partly measured 2026-09-23 | Asked "show me the Plan section of notes.md", Claude read the file and pasted the section into its reply; no `show_file` call at all (0/1). The briefing sentence covers starting a document, not pointing at one. The landing itself is not yet seen on screen. | "Show me X" is a second moment the briefing may need to name, or the reply text is enough and the page is for writing. Decide after the on-screen walk. |
| The page following whole-file writes (line diff) | | | |
| Marks placed on the right passage | | | |
| The person's edit surviving an agent write elsewhere | | | |
| The collision card | | | |
| The turn note reaching the agent, next turn | measured 2026-09-23 | Daemon tests show the block goes out after the person's words, once, and not into the transcript. Live, over the scratch socket: a passage of `between-claude.md` replaced by `artifact/write` between turns, then "continue with one more section" — the agent's write kept the edit and added the section (Claude 1/1, Grok 1/1, Copilot 1/1, Cursor 1/1; Grok's write permission answered over the socket). | Works. Whether the agent kept it because of the note or because it re-read the file first is not separable from outside; either is the behaviour wanted. |
| The agent respecting the note (not restoring its text) | measured 2026-09-23 | Claude, Grok, Copilot and Cursor, 1/1 each: the original paragraph did not come back. (Grok asks permission for every write and the first run stalled at `waitingOnUser` until the permission was answered over the socket.) | Holds for both. |
| Mid-turn edit: runtime's own stale-file guard | measured 2026-09-23 | Claude and Grok, each asked to write a file in three separate writes with a `sleep 25` between: a passage replaced by `artifact/write` after the first write was **overwritten** by the second (Claude 0/1, Grok 0/1, Cursor 0/1 survived). All three write the whole file from their own version; no guard fired in any. Copilot is the odd one: after its `sleep` it **viewed the file again** before the next write, then its shell steps failed and it ended the turn without writing more — so the edit "survived" by the turn ending, not by a merge, and whether Copilot would have honoured what it re-read is not known. Grok's write went through the daemon's own `fs/write_text_file`, so the daemon saw the overwrite go by and could have merged; Claude's did not pass through anything of ours. | **This is where a tool would earn its place.** A whole-file write mid-turn cannot know the file moved. Either the agent is told mid-turn (a tool it can call, or a tool result that carries the change), or the daemon merges the person's passages back into the agent's write on the way to disk — which for Grok it could, since it serves the write; for Claude it cannot. |
| A "what changed since I wrote" tool, callable mid-turn | not built | The mid-turn row above is the evidence: with no way to learn of the person's edit inside a turn, Claude overwrote it. Between turns the note suffices. | Needed for the real feature, in one of two shapes: a tool the agent calls before each write, which it will not call unasked (see suggestions and show_file); or the app merging on the way to disk, which needs the write to pass through the app and only Grok's does. The second is the stronger, because it does not depend on the agent remembering. |
| Passage-level editing as the shape of editing | | | |
| The sidebar as the page's home vs a window of its own | | | |
| Finer-grained agent edits (replace section, append) | not built | Not reached for. Every runtime wrote the whole file on every step, even Claude, whose edit tool can replace a passage; the mid-turn overwrite is the cost of that. | Not a tool to give the agent — it has one and does not use it for documents. If anything, the fix is on our side of the write (see the mid-turn row). |
| SVG images beside the document, drawn and marked on change | half measured 2026-09-23 | Asked for a report "with a graph of those five numbers" and nothing about how, Claude wrote `test-counts.svg` beside the document and referenced it as an image; Grok wrote `graph-grok.svg` and did the same (2/2). Both also put the numbers in a table. Whether the picture draws and whether a redraw is marked is not yet seen on screen. | Agents draw SVG unprompted once the description mentions it. The rendering and the mark need the walk. |
| A graph asked for: what the agent drew it as | measured 2026-09-23 | Claude: an SVG file plus a Markdown table. Grok: an SVG file plus a Markdown table. Neither wrote Mermaid or ASCII. | SVG-as-file is what they reach for; a chart format is not missed. |
| Mermaid written by an agent unasked (a renderer would be needed) | measured 2026-09-23 | 0/2 (Claude, Grok), with the description saying to write an SVG for a diagram or graph. Not measured without that sentence. | Not needed while the description says SVG. |
| Inserting an image from the page | not built | Not reached for by anyone; the person cannot, by design. | Out of scope for the PoC; unchanged. |

## Things that grated

- A document begun from the project page is written before anyone can watch: the
  conversation is not the one on screen, so the page waits for it (FR-009). The first
  turn of the very thing this feature is for happens off-screen. (Slice A walk.)
- `show_file` on a file that did not exist yet was refused, so "show it first, then write"
  could not work until the daemon learned that a Markdown file may be shown before its
  first write. Fixed in Slice B; recorded because the spec's edge case was right and the
  daemon was not.
- "Show me the Plan section" got the section pasted into the chat, not shown on the page.
- Grok asks permission for every write. On a live page that is a card per save while the
  person is trying to watch a document take shape; the walk should say whether it is
  bearable, and "accept edits" for Grok is a question for its policy.
- Three lanes in one working tree meant every commit here was staged as blobs and verified
  in a detached worktree; one commit still swept in another lane's staged deletion and had
  to be put back. Not the feature's fault, but it cost an hour.

## What the real feature needs

- **A merge on the way to disk, or a tool the agent calls before each write.** The
  mid-turn measurement is the whole case: three of four runtimes overwrote a passage the
  person had just changed, because a whole-file write cannot know the file moved. Between
  turns the note is enough and every runtime honoured it. For Grok the daemon already
  serves the write and could fold the person's passages back in; for the others the write
  never passes through anything of ours, so the agent would have to ask — and the
  suggestions and show_file measurements say an agent does not call a tool it is only
  offered. Which shape, and whether the briefing can carry a "before each write" rule an
  agent will actually follow, is the first thing the real feature should measure.
- **The page must be on screen when the document begins.** A document started from the
  project page is written entirely off-screen because the conversation is not open. Either
  starting a chat opens it, or a live document's first show is allowed to pull the window
  to the conversation — a deliberate exception to the rule that a file shown in a
  conversation you are not reading waits.
- **"Show me X" as a second moment in the briefing.** Asked to show a section, Claude
  pasted it. If the page is meant for reading as well as writing, the sentence has to say
  so; if it is for writing, the reply text is fine and nothing is needed.
- **Nothing new for editing or drawing.** Every runtime edited with its own tools, drew a
  graph as an SVG beside the document when the description said to, and wrote no Mermaid.
  No tool, no chart format.
- **Still to be seen on screen** before any of the page's own shape is settled: the marks
  landing on the right passage, the follow, the caret holding through a merge, the
  collision card, and whether passage-level editing is the right way to type.

## Success criteria, as far as the socket can see

- SC-001 (change visible within a second): not measurable without the screen; the folder
  watch coalesces at 0.2 s and the file is re-read whole, so nothing in the path is slow.
- SC-002 (final content every time, changes nameable): final content held in every socket
  run; nameable needs the screen.
- SC-003 (typed text on disk within two seconds): the editor waits one second and the
  daemon writes at once; not timed on screen.
- SC-004, SC-005 (alternating edits; collisions): the merge is exhausted in unit tests;
  the fifty-edit walk and the card are not yet seen.
- SC-006 (the agent builds on the edited paragraph): 4/4 runtimes between turns.
- SC-007 (findings usable by someone who did not watch): this file.
- SC-008 (a diagram as an SVG unasked): 2/2 runtimes.

