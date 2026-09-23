# Data Model: Live Artifacts, A Proof Of Concept

**Feature**: `022-live-artifacts` | **Date**: 2026-09-21

Everything here is derived from the file on disk except one list in the daemon's memory.
Nothing is persisted by this feature.

## Passage (AgentsKitCore)

One run of source lines, the unit of everything on the page.

| Field | Type | Meaning |
|---|---|---|
| `source` | `String` | The lines, joined, without the trailing blank line |
| `lines` | `ClosedRange<Int>` | Where it sits in the document, counted from one |
| `isHeading` | `Bool` | First line is an ATX heading, or the passage is a setext heading; used for nothing but the page's spacing |

**Rules**
- `Passage.split(_:)` splits on one or more blank lines. A fenced block (```` ``` ```` or
  `~~~`) is never split; a blank line inside it belongs to it.
- Splitting then joining with single blank lines round-trips the *passages*; it does not
  promise to round-trip the exact blank-line count. The daemon writes whole documents the
  page hands it, so the page is responsible for reassembling with the document's original
  separators. Implementation: keep the separator run beside each passage.
- `Passage.join(_:)` reassembles a document.
- `Passage.index(containing line: Int, in: [Passage]) -> Int?` gives the passage whose
  `lines` holds the line, or the last passage when the line is past the end, or nil for an
  empty document. This is what a `show_file` line becomes on the page.
- Identity for the page's `ForEach` is index, as `MarkdownText` does for blocks.

## PassageChange (AgentsKitCore)

What differs between two versions of a document, said in passages of the new one.

| Field | Type | Meaning |
|---|---|---|
| `changedLines` | `ClosedRange<Int>?` | First to last changed line in the new text, nil when identical |
| `changed` | `IndexSet` | Indices of new passages that intersect `changedLines` |
| `first` | `Int?` | The passage to scroll to |

`PassageChange.between(old:new:)` is pure. Whole-file replacement (nothing in common)
marks every passage and scrolls to the top.

## PassageMerge (AgentsKitCore)

```
enum Result {
    case merged(text: String, passageIndex: Int)
    case collided(text: String, passageIndex: Int, theirs: String)
}
static func apply(base: String, theirs: String, mine: Passage, edited: String) -> Result
```

- `mine` is the passage as it was in `base`; `edited` is what the person has typed for it.
- Merged when `mine.source`'s lines occur contiguously in `theirs`; the edit is spliced there.
- Collided otherwise; the edit is placed where the corresponding lines now are (the
  passage in `theirs` that contains the first line of `mine`'s old range, clamped to the
  document), and `theirs` carries the agent's passage at that place.
- Never returns text in which `edited` does not appear (FR-015).

## ImageStamps (App, view-local)

| Field | Type | Meaning |
|---|---|---|
| `stamps` | `[Int: Stamp]` | Passage index → resolved file URL, modification date, size, and a reload token |

Rebuilt when the passages change; re-read on every folder event. A passage whose stamp
differs is marked and its token bumped, which is what makes `Image` load the file again.

## ShownFile (AgentsKitCore, existing, unchanged)

Not extended. `path` and `line` are what an agent sends today and what it sends after. On a
Markdown file the page reads `line` as a passage; on anything else `FileLines` reads it as
it always has.

## ArtifactEdit (AgentsKit, daemon memory only)

| Field | Type | Meaning |
|---|---|---|
| `path` | `String` | The file the person changed |
| `lines` | `ClosedRange<Int>` | The edited passage's lines in the written document |
| `text` | `String` | The passage as written, for the note |
| `at` | `Date` | When |

Held as `[UUID: [ArtifactEdit]]` on `DaemonCore`. Appended on `artifact/write`. Drained into
the turn note in `beginTurn` for that agent. Not written to disk; a daemon restart forgets
it, and the person's edit is still on disk for the agent to read.

Coalescing: several writes to the same passage before a turn keep only the last; writes to
different passages are all kept, capped at 20 per agent, oldest dropped. Past that the note
says "and more; read the file".

## AgentPaneState (App, existing, unchanged)

`openFile` and `openLine` are enough. `LivePage` reads `openLine` and clears it once it has
scrolled, the way `FileLines` treats it as a one-time place rather than a standing one.

## LivePage state (App, view-local)

| Field | Meaning |
|---|---|
| `passages` | The current split of the text on disk |
| `marked` | Indices with a mark, each with the time it was set; cleared on a timer |
| `images` | `ImageStamps` for the image passages on the page |
| `editing` | `(index, base: String, draft: String)?` — one passage at most |
| `collision` | `(index, theirs: String)?` — the card |
| `lastLoaded` | The text the passages came from; the `base` for the next diff and merge |

**Transitions**
- *folder event, document unchanged* → re-read `images`; mark and follow any passage whose
  image changed, under the same typing rule.
- *disk changed* → `PassageChange.between(lastLoaded, disk)`; if `editing` is nil: replace
  passages, mark, scroll to `first`; else `PassageMerge.apply`, replace, keep editor on the
  new index, mark others, do not scroll; on collision also set `collision`.
- *typed* → update `draft`; restart the 1 s timer.
- *timer or blur* → if `draft != base`, `writeArtifact(Passage.join(with draft at index))`.
- *escape / click elsewhere* → write if dirty, then `editing = nil`.
- *card: use theirs* → `draft = theirs`, write, clear card. *card: dismiss* → clear card.
