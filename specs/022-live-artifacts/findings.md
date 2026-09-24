# Findings: Live Artifacts, A Proof Of Concept

**Feature**: `022-live-artifacts` | **Status**: not yet walked

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
