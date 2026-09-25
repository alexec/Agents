# Data Model: Code That Reads Like Code (041)

All of this lives in the app process (Mac and phone), in `Packages/CodeText`, except `CodeInk`
(`Shared/UI`). Nothing is stored or sent over the wire. The daemon's `DiffLine` and
`ReportedEdit` (035) are inputs, unchanged.

## CodeLanguage

One of the 20 languages in research R2, or none.

| Field | Type | Notes |
|---|---|---|
| `id` | enum case | `swift, c, cpp, python, javascript, typescript, tsx, json, go, rust, java, ruby, bash, yaml, toml, html, css, markdown, dockerfile, make` |
| `extensions` | Set<String> | lower-cased, without the dot |
| `fileNames` | Set<String> | exact names: `Dockerfile`, `Makefile`, `Gemfile`, `.zshrc`, … |
| `interpreters` | Set<String> | matched against a `#!` first line's program or `env` argument |
| `fenceTags` | Set<String> | lower-cased: `swift`; `py`, `python`; `ts`, `typescript`; `sh`, `bash`, `zsh`, `shell`; `yml`, `yaml`; `objc`, `objective-c` → `c`; … |

**Rules**
- `detect(path:firstLine:)` tries, in order: exact file name, extension, `#!` interpreter. The
  first match wins; otherwise nil.
- `fence(tag:)` lower-cases the tag, drops anything after the first space or `{`, and looks it
  up. Otherwise nil.
- nil means plain (FR-005). It is never guessed from content beyond the `#!` line.

## CodeRole

`keyword | string | comment | number | type | function | property | punctuation | plain`

**Rules**: `role(forCapture:)` maps a capture name (`keyword.return`, `string.special`,
`function.method`, …) by its first component, through a fixed table. `constant.*` and
`boolean` go to number, `attribute` to property, `operator` to punctuation,
`variable.builtin` to keyword, and anything else to plain. It is total: every string maps to
some role.

## CodeSpan

| Field | Type | Notes |
|---|---|---|
| `range` | Range<Int> | UTF-16 offsets **within one line** |
| `role` | CodeRole | never `plain`, which is simply the absence of a span |

**Rules** (FR-006)
- Spans on a line don't overlap. Where captures nest, the more specific (later) one wins over
  its range, as `highlights()` sorts them.
- Applying spans never changes the line's characters. A test checks every sample in every
  language: the `AttributedString`'s characters equal the line.

## CodeDocument  *(@Observable, one per shown text)*

| Field | Type | Notes |
|---|---|---|
| `lines` | [Substring] | split once, as `FileLines` does today |
| `language` | CodeLanguage? | |
| `plainBecause` | PlainReason? | `.tooLarge`, `.lineTooLong` or nil (FR-018) |
| `windows` | [Int: [[CodeSpan]]] | window index (line / 200) → spans per line in it |

**States**: `plain` (no language or past a limit), then `parsing`, then `ready`. When the text
changes, it goes back to `reparsing` (it keeps the old windows until new ones replace them),
then `ready`.

**Rules**
- `spans(line:)` returns the spans of that line's window, or none if it hasn't arrived yet. The
  row draws plain until it has.
- `appear(line:)` asks for that line's window, and the next one, if not already there or asked
  for.
- A text change edits the tree (research R7) and drops only the windows that overlap the
  changed lines.

## DiffRow

| Field | Type | Notes |
|---|---|---|
| `kind` | `.context \| .removed \| .added` | |
| `text` | Substring | |
| `newLine` | Int? | in the file as it now stands, when known (Whole file); nil for edits (FR-013) |
| `changed` | [Range<Int>] | UTF-16 ranges of changed words; empty if unpaired or past a limit |

**Rules** (research R5)
- `LineDiff.rows(old:new:)`: context rows appear once. In each change block, removed rows come
  before added rows, in the order they fall.
- In a change block, removed *i* pairs with added *i*. A pair gets `changed` ranges on both
  sides unless fewer than a third of its tokens are shared, a line is over 1,000 characters, or
  the block is over 200 pairs.
- An edit that made a file (no old text) is all `.added`, with no `changed` and no folds
  (US2 AS4).
- `LineDiff.rows(whole: [DiffLine])` turns the daemon's lines into rows and adds `changed` by the
  same pairing.

## Fold

| Field | Type | Notes |
|---|---|---|
| `range` | Range<Int> | indices into the rows it hides |
| `isOpen` | Bool | view state, starts closed |

**Rules**: `Folds.of(rows, context: 3, minimum: 8)` gives a fold for every run of context rows
longer than 8, leaving 3 visible at each end that touches a change. A run at the start or end
of the text keeps 3 only on its change side. Opening a fold is local view state, lost when the
view goes away.

## Change stops (Whole file)

`[Int]` holds the row index of the first row of each change block. Next and previous move
between them (FR-012), opening a fold if the target is inside one.

## CodeInk  *(Shared/UI)*

For each `CodeRole` except plain: `Color(light:dark:)`, plus a weight (keyword semibold) and a
style (comment italic).

For diff marks:
- `removedWash`: neutral, about 6% ink.
- `changedWash`: neutral, about 14% ink.
- The mark column (`+`, `−`).
- Removed text keeps its strikethrough and tertiary opacity; added text keeps its weight (035).

**Rules**: no role within 30° of hue 0° (red) at over 40% saturation. Every role is at 4.5:1 or
better against `Paper.ground` and `Paper.well` in both appearances (SC-007).
