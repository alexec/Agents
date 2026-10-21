---
diataxis: reference
devices: [mac, iphone, ipad, web]
description: Which charts and Mermaid diagrams the app draws, where it draws them, and what happens to one it cannot draw.
---

# Charts and diagrams

The app draws charts and Mermaid diagrams itself, on the Mac, iPhone, iPad and the web
page. It does not run Vega-Lite or Mermaid code. It reads only a subset of each, so no
script in a file can run, and the drawing follows the app's theme. The Mac and the Remote
draw charts with Swift Charts and diagrams on a canvas. The web page draws both as SVG.
All three use the same rules and the same layout.

## Where they are drawn

| Where | Charts | Mermaid diagrams |
| --- | --- | --- |
| A file in the Files pane | A Vega-Lite spec, by its name. A CSV or TSV file only after an agent showed it with a `chart` hint. | A file whose name ends in `.mmd` or `.mermaid`. |
| A Markdown page, or a message in the chat | Not drawn. | A ```` ```mermaid ```` fence, in place of its code. |
| The card in the chat for a file an agent showed with `show_file` | A small preview. | A small preview. |

In the Files pane, a chart has **Chart** and **Source** above it, and a diagram has
**Diagram** and **Source**. Choose **Source** to read the text of the file. A grey line
beside them says what was drawn, for example **Bar chart · 12 rows**,
**Flowchart · 5 boxes** or **Sequence diagram · 4 messages**.

The card in the chat shows the kind of file on its grey line, for example **Bar chart**
or **Diagram**. Click or tap the card to open the file in the Files pane, at its line.

While an agent is still typing a Mermaid fence into a message, the fence shows as code.
The diagram is drawn when the fence is finished, so the page does not jump while you
read it.

## Charts

A chart comes from a Vega-Lite spec or from a CSV file.

**A Vega-Lite spec** is a file whose name ends in `.vl.json`, `.vega-lite.json` or `.vl`.
The app draws only this subset:

| Part of the spec | What the app reads |
| --- | --- |
| `mark` | One of `bar`, `line`, `point` or `area`, as a word or as `{"type": ...}`. |
| `encoding` | The `field` of `x` and of `y`, both needed. The `field` of `color` is optional and splits the rows into series, each in its own colour. |
| `encoding.x.type` | `nominal`, `quantitative` or `temporal`. With no type, the app finds it from the values: numbers, ISO 8601 dates, or else names. |
| `data` | `values`, a list of rows in the spec, or `url`, a relative path to a CSV, TSV or JSON file beside the spec. A web address is not fetched. |
| `title` | A string, or `{"text": ...}`. |

**A CSV or TSV file** is drawn as a chart only when an agent shows it with `show_file`
and a `chart` hint. The hint names the `mark`, the `x` and `y` columns, and an optional
`color` column and `title`. The app needs this hint because a CSV file does not say how
to draw its numbers. With no mark in the hint, the app draws bars.

A `point` mark is drawn as a scatter chart. Bars of more than one series stack. A chart
shows the first 5,000 rows; the grey line then says **(first 5000)**. A row whose `y`
is not a number is left out.

## Mermaid diagrams

The app draws two kinds of Mermaid diagram: flowcharts and sequence diagrams.

**Flowcharts** start with `graph` or `flowchart`, with an optional direction: `TD` or
`TB` (down), `BT` (up), `LR` (right) or `RL` (left).

| Part | What the app draws |
| --- | --- |
| Node shapes | `[text]` as a rectangle, `(text)` and `{{text}}` rounded, `([text])` as a stadium, `((text))` as a circle, `{text}` as a diamond. `[[text]]`, `[(text)]`, `[/text/]`, `[\text\]` and `>text]` are drawn as rectangles. |
| Links | `-->`, `---`, `-.->` (dashed), `==>` (thick), `<-->`, and ends `x` and `o`, such as `--x`. `~~~` places two nodes without a line. |
| Link text | `-->|text|` and `-- text -->`. |
| Several nodes at once | `A & B --> C`, and chains such as `A --> B --> C`. |
| Text | Quoted text, and `<br>` for a new line. |
| Ignored | `classDef`, `class`, `style`, `linkStyle`, `click` and `:::class`. The app uses its own colours. |
| Not drawn | `subgraph`. |

A link that would cross a box goes round its side.

**Sequence diagrams** start with `sequenceDiagram`.

| Part | What the app draws |
| --- | --- |
| Participants | `participant` and `actor`, with `as` for a shown name. A name used in a message adds a participant too. |
| Messages | `->`, `-->`, `->>`, `-->>`, `-x`, `--x`, `-)`, `--)`, `<<->>` and `<<-->>`, with text after a colon. The two-dash kinds are dashed. A `+` or `-` before the receiver is read, but activations are not drawn. |
| Notes | `Note left of A`, `Note right of A`, and `Note over A` or `Note over A,B`. |
| Frames | `loop`, `alt`, `opt`, `par`, `critical`, `break` and `rect`, with `else`, `and` or `option` inside, closed by `end`. |
| Numbers | `autonumber` puts a number before each message. |
| Ignored | `activate`, `deactivate`, `title`, `accTitle:` and `accDescr:`. |
| Not drawn | `box`, `create`, `destroy`, `link`, `links`, `properties` and `details`. |

Comments (`%%`), directives and front matter between `---` lines are left out. A
diagram can have up to 400 boxes and 800 links, or 40 participants and 800 messages,
notes and frames.

## What happens when it cannot be drawn

A chart or a diagram outside the subset is not drawn. In its place the app shows a grey
line that says why, and the source under it, so you can still read it. For example:

- **The app draws flowcharts and sequence diagrams, not pie. Its source is below.**
- **This diagram uses subgraphs, which the app does not draw. Its source is below.**
- **This chart uses layer, which the app does not draw. Its source is below.** A spec
  with `layer`, `hconcat`, `vconcat`, `concat`, `facet`, `repeat` or `transform` gets this
  line, and so does a mark that is not one of the four.
- **Line 3 does not read as Mermaid:** and the line's text.
- **This diagram is too big to draw here. Its source is below.**
- **There is no column called** and the column's name, for a chart.

On the card in the chat, the same line takes the place of the preview. A Markdown fence
that cannot be drawn shows the line above its code.

On the Mac and the Remote, a file too big to read whole in the Files pane shows as its
source, not as a chart or a diagram. On the web page, a chart is drawn from the start
of such a file, under **Only the start of** and the file's name, and a diagram shows as
its source.

## See also

- [Tools the app gives agents](agent-tools.md)
- [Follow a live document](../how-to/follow-a-live-document.md)
- [Read a chat](../how-to/read-a-chat.md)
