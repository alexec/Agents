# Findings: Live Artifacts, A Proof Of Concept

**Feature**: `022-live-artifacts` | **Status**: not yet walked

This is the proof of concept's actual output (FR-017). Each row is a capability the agent
used, needed, or was missing, with the observation behind it. A row is not deleted when a
capability turns out to be unnecessary; it is marked so, with why, so it is not proposed
again.

## Runtimes walked

| Runtime | Date | Slices |
|---|---|---|
| Claude | 2026-09-23 | A (page seen, follow not yet), B measurement |
| Grok | 2026-09-23 | B measurement |

## Capabilities

| Capability | Status | Observation | Verdict for the real feature |
|---|---|---|---|
| `show_file` called unasked at the start of a document | measured 2026-09-23 | From the description alone, with the new paragraph in it: Claude 0/1, Grok 0/1 — neither called it. With one sentence in the briefing (`Briefing.liveDocument`): Claude 1/1, Grok 1/1, both before their first write, and both were told the page was open empty and would fill. | The sentence stays. The description alone does not make it happen; the briefing does, as it did for suggestions. |
| `show_file` with a line, landing on the right passage | partly measured 2026-09-23 | Asked "show me the Plan section of notes.md", Claude read the file and pasted the section into its reply; no `show_file` call at all (0/1). The briefing sentence covers starting a document, not pointing at one. The landing itself is not yet seen on screen. | "Show me X" is a second moment the briefing may need to name, or the reply text is enough and the page is for writing. Decide after the on-screen walk. |
| The page following whole-file writes (line diff) | | | |
| Marks placed on the right passage | | | |
| The person's edit surviving an agent write elsewhere | | | |
| The collision card | | | |
| The turn note reaching the agent, next turn | | | |
| The agent respecting the note (not restoring its text) | | | |
| Mid-turn edit: runtime's own stale-file guard | | | |
| A "what changed since I wrote" tool, callable mid-turn | not built | | |
| Passage-level editing as the shape of editing | | | |
| The sidebar as the page's home vs a window of its own | | | |
| Finer-grained agent edits (replace section, append) | not built | | |
| SVG images beside the document, drawn and marked on change | | | |
| A graph asked for: what the agent drew it as | | | |
| Mermaid written by an agent unasked (a renderer would be needed) | not built | | |
| Inserting an image from the page | not built | | |

## Things that grated

- A document begun from the project page is written before anyone can watch: the
  conversation is not the one on screen, so the page waits for it (FR-009). The first
  turn of the very thing this feature is for happens off-screen. (Slice A walk.)
- `show_file` on a file that did not exist yet was refused, so "show it first, then write"
  could not work until the daemon learned that a Markdown file may be shown before its
  first write. Fixed in Slice B; recorded because the spec's edge case was right and the
  daemon was not.
- "Show me the Plan section" got the section pasted into the chat, not shown on the page.

## What the real feature needs

- 
