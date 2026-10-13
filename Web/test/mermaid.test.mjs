// Mermaid diagrams (#853): the port of MermaidDiagram.swift, held to the same cases as
// MermaidDiagramTests.swift, and the same sizes, so the three clients lay a diagram out alike.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const mermaid = await load("src/model/mermaid.ts");
const shown = await load("src/model/shownFile.ts");

const diagram = (text) => {
  const result = mermaid.read(text);
  assert.ok("diagram" in result, "diagram" in result ? "" : mermaid.problemWords(result.problem));
  return result.diagram;
};
const problem = (text) => {
  const result = mermaid.read(text);
  return "problem" in result ? mermaid.problemWords(result.problem) : null;
};
const words = (d) => d.labels.flatMap((l) => l.lines);

test("a file or a fence is Mermaid by its name", () => {
  assert.equal(mermaid.isMermaid("/r/flow.mmd"), true);
  assert.equal(mermaid.isMermaid("/r/Flow.Mermaid"), true);
  assert.equal(mermaid.isMermaid("/r/flow.md"), false);
  assert.equal(mermaid.isFence("mermaid"), true);
  assert.equal(mermaid.isFence("swift"), false);
  assert.equal(mermaid.isFence(undefined), false);
});

test("a flowchart has a box per node and a line per link", () => {
  const chart = diagram(`%% a comment
flowchart TD
    A[Start] --> B{Is it?}
    B -->|Yes| C(Do it)
    B -- No --> D([Stop])
    C --> D`);
  assert.equal(chart.kind, "flowchart");
  assert.deepEqual(chart.boxes.map((b) => b.shape), ["rectangle", "diamond", "rounded", "stadium"]);
  assert.equal(chart.lines.length, 4);
  assert.ok(chart.lines.every((l) => l.heads.length === 1 && l.heads[0].filled));
  assert.deepEqual(new Set(words(chart)), new Set(["Start", "Is it?", "Yes", "No", "Do it", "Stop"]));
  assert.equal(chart.summary, "Flowchart · 4 boxes");
  const ys = chart.boxes.map((b) => b.y + b.height / 2);
  assert.ok(ys[0] < ys[1] && ys[1] < ys[2] && ys[2] < ys[3]);
  // The same size as MermaidDiagramTests.theLayoutIsTheSameOnEveryClient.
  assert.equal(chart.width, 151);
  assert.equal(chart.height, 334.5);
});

test("left to right puts ranks side by side", () => {
  const chart = diagram("graph LR; A --> B; B --> C");
  const xs = chart.boxes.map((b) => b.x);
  assert.ok(xs[0] < xs[1] && xs[1] < xs[2]);
  assert.equal(new Set(chart.boxes.map((b) => b.y)).size, 1);
});

test("links take their strokes and ends", () => {
  const chart = diagram(`graph TD
A --- B
B -.-> C
C ==> D
D --x E
E <--> F
F ~~~ G
G -. maybe .-> H`);
  assert.deepEqual(chart.lines.map((l) => l.stroke), ["solid", "dashed", "thick", "solid", "solid", "dashed"]);
  assert.deepEqual(chart.lines.map((l) => l.heads.length), [0, 1, 1, 2, 2, 1]);
  assert.ok(words(chart).includes("maybe"));
  assert.equal(chart.boxes.length, 8);
});

test("ampersands and chains make every link", () => {
  assert.equal(diagram("graph TD\nA & B --> C --> D").lines.length, 3);
});

test("a cycle is drawn without looping the ranks", () => {
  const chart = diagram("graph TD\nA --> B\nB --> C\nC --> A\nC --> C");
  assert.equal(chart.boxes.length, 3);
  assert.equal(chart.lines.length, 4);
  assert.equal(chart.lines[3].points.length, 4);
});

test("a link that would cross a box goes round it", () => {
  const chart = diagram("graph TD\nA --> B\nB --> C\nA --> C");
  assert.deepEqual(chart.lines.map((l) => l.points.length), [2, 2, 4]);
  const lane = chart.lines[2].points[1].x;
  assert.ok(chart.boxes.every((b) => b.x + b.width < lane));
});

test("quoted text, breaks and styles are read", () => {
  const chart = diagram(`graph TD
A["One; two<br>three"]:::hot --> B
classDef hot fill:#f00
style B fill:#0f0`);
  assert.ok(words(chart).includes("One; two"));
  assert.ok(words(chart).includes("three"));
});

test("a sequence diagram has participants, messages and notes", () => {
  const chart = diagram(`sequenceDiagram
    autonumber
    participant A as Alice
    actor B as Bob
    A->>+B: Hello
    B-->>-A: Hi
    Note over A,B: Both
    loop Every minute
        A-)B: Ping
        alt Busy
            B-xA: No
        else
            B->>B: Think
        end
    end`);
  assert.equal(chart.kind, "sequence");
  assert.equal(chart.summary, "Sequence diagram · 5 messages");
  const all = words(chart);
  assert.equal(all.filter((w) => w === "Alice").length, 2);
  assert.ok(all.includes("1. Hello"));
  assert.ok(all.includes("5. Think"));
  assert.ok(all.includes("loop [Every minute]"));
  assert.ok(all.includes("alt [Busy]"));
  assert.equal(chart.boxes.filter((b) => b.shape === "frame").length, 2);
  assert.equal(chart.boxes.filter((b) => b.shape === "note").length, 1);
  assert.equal(chart.lines.length, 8);
  assert.equal(chart.lines.filter((l) => l.stroke === "dashed").length, 4);
  // The same size as MermaidDiagramTests.theLayoutIsTheSameOnEveryClient.
  assert.equal(chart.width, 307);
  assert.equal(chart.height, 473);
});

test("a message is wide enough for its words", () => {
  const long = "word ".repeat(20);
  const chart = diagram(`sequenceDiagram\nA->>B: ${long}`);
  const arrow = chart.lines[2];
  assert.ok(arrow.points[1].x - arrow.points[0].x >= long.trim().length * mermaid.characterWidth);
});

test("outside the subset says why, in the window's words", () => {
  assert.equal(problem(""), "There is no diagram here.");
  assert.equal(problem("%% only a comment"), "There is no diagram here.");
  assert.equal(problem("classDiagram\nA <|-- B"), "The app draws flowcharts and sequence diagrams, not classDiagram. Its source is below.");
  assert.equal(problem("graph TD\nsubgraph one\nA-->B\nend"), "This diagram uses subgraphs, which the app does not draw. Its source is below.");
  assert.equal(problem("graph TD\nA -> B"), "Line 2 does not read as Mermaid: A -> B");
  assert.equal(problem("graph XY"), "Line 1 does not read as Mermaid: graph XY");
  assert.equal(problem("sequenceDiagram\nbox Aqua Group\nend"), "This diagram uses boxes around participants, which the app does not draw. Its source is below.");
  assert.equal(problem("sequenceDiagram\nend"), "Line 2 does not read as Mermaid: end");
  assert.equal(problem("sequenceDiagram\nA B"), "Line 2 does not read as Mermaid: A B");
});

test("front matter is left out", () => {
  assert.equal(diagram("---\ntitle: Flow\n---\ngraph TD\nA-->B").boxes.length, 2);
});

test("a diagram too big shows its source", () => {
  const links = Array.from({ length: mermaid.elementLimit + 1 }, (_, i) => `N${i} --> N${i + 1}`).join("\n");
  assert.equal(problem(`graph TD\n${links}`), "This diagram is too big to draw here. Its source is below.");
});

test("a shown Mermaid file is a diagram on its card", () => {
  assert.equal(shown.look({ path: "/r/flow.mmd" }), "diagram");
  assert.equal(shown.lookWords({ path: "/r/flow.mmd" }), "Diagram");
});
