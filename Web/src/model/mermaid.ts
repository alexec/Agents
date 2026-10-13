// A Mermaid diagram the page draws (#853): the port of MermaidDiagram.swift. A flowchart and
// sequence subset, read and laid out here into boxes, lines and labels, and drawn as an SVG in
// MermaidView.tsx; the window and the Remote draw the same layout with a Canvas. Nothing runs,
// and no Mermaid JavaScript is bundled. Text is measured by a fixed width per character, so the
// three clients lay a diagram out the same way.

export type Kind = "flowchart" | "sequence";
export interface Point { x: number; y: number }
export type Shape = "rectangle" | "rounded" | "stadium" | "circle" | "diamond" | "note" | "frame";
export interface Box { x: number; y: number; width: number; height: number; shape: Shape }
export type Stroke = "solid" | "dashed" | "thick";
/** The end of a line: a filled triangle, or strokes (an open arrow, a cross). */
export interface Head { points: Point[]; filled: boolean }
export interface Line { points: Point[]; stroke: Stroke; heads: Head[] }
/** Words in a rectangle: a line of text per `lineHeight`, centred unless leading. */
export interface Label {
  x: number; y: number; width: number; height: number; lines: string[]; leading: boolean; backed: boolean;
}

export interface MermaidDiagram {
  kind: Kind;
  width: number;
  height: number;
  boxes: Box[];
  lines: Line[];
  labels: Label[];
  /** "Flowchart · 5 boxes". */
  summary: string;
}

/** Why a diagram was not drawn, said above its source. */
export type MermaidProblem =
  | { kind: "empty" }
  | { kind: "unsupportedKind"; what: string }
  | { kind: "unsupported"; what: string }
  | { kind: "unreadable"; line: number; text: string }
  | { kind: "tooBig" };

export type MermaidResult = { diagram: MermaidDiagram } | { problem: MermaidProblem };

export const fontSize = 13;
export const characterWidth = 7;
export const lineHeight = 17;
/** Past this many boxes or messages, the source is shown instead. */
export const elementLimit = 400;

const extensions = new Set(["mmd", "mermaid"]);

export function isMermaid(path: string): boolean {
  const name = path.split("/").filter(Boolean).pop() ?? "";
  const dot = name.lastIndexOf(".");
  return dot > 0 && extensions.has(name.slice(dot + 1).toLowerCase());
}

/** Whether a Markdown fence's tag is Mermaid's. */
export function isFence(language: string | undefined): boolean {
  return language?.toLowerCase() === "mermaid";
}

export function problemWords(problem: MermaidProblem): string {
  switch (problem.kind) {
    case "empty": return "There is no diagram here.";
    case "unsupportedKind":
      return `The app draws flowcharts and sequence diagrams, not ${problem.what || "this"}. Its source is below.`;
    case "unsupported": return `This diagram uses ${problem.what}, which the app does not draw. Its source is below.`;
    case "unreadable": return `Line ${problem.line} does not read as Mermaid: ${problem.text}`;
    case "tooBig": return "This diagram is too big to draw here. Its source is below.";
  }
}

const count = (text: string) => [...text].length;
const trimSpaces = (text: string) => text.replace(/^[ \t]+|[ \t]+$/g, "");

/** The words of a box or a message, a line each, as Mermaid writes a break. */
export function textLines(text: string): string[] {
  return text.replace(/<br\s*\/?>/gi, "\n").split("\n").map(trimSpaces);
}

function measure(lines: string[]): { width: number; height: number } {
  return { width: Math.max(0, ...lines.map(count)) * characterWidth, height: lines.length * lineHeight };
}

function label(centreX: number, centreY: number, lines: string[], backed = false): Label {
  const size = measure(lines);
  return { x: centreX - size.width / 2, y: centreY - size.height / 2, width: size.width, height: size.height,
    lines, leading: false, backed };
}

function leadingLabel(x: number, centreY: number, lines: string[]): Label {
  const size = measure(lines);
  return { x, y: centreY - size.height / 2, width: size.width, height: size.height, lines, leading: true, backed: false };
}

const fail = (problem: MermaidProblem): { problem: MermaidProblem } => ({ problem });

/** The diagram a text describes, or why it is not drawn. */
export function read(text: string): MermaidResult {
  const statements = statementsOf(text);
  const header = statements[0];
  if (!header) return fail({ kind: "empty" });
  const word = header.text.split(/[ \t;]/).filter(Boolean)[0] ?? "";
  switch (word) {
    case "graph":
    case "flowchart": {
      const chart = readFlowchart(statements);
      return "problem" in chart ? chart : { diagram: layOutFlowchart(chart) };
    }
    case "sequenceDiagram": {
      const sequence = readSequence(statements);
      return "problem" in sequence ? sequence : { diagram: layOutSequence(sequence) };
    }
    default:
      return fail({ kind: "unsupportedKind", what: word });
  }
}

/** Everything moved so the nearest edge is the margin from the top and left. */
function framed(kind: Kind, boxes: Box[], lines: Line[], labels: Label[], summary: string): MermaidDiagram {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  const take = (x: number, y: number) => {
    minX = Math.min(minX, x); minY = Math.min(minY, y); maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
  };
  for (const box of boxes) { take(box.x, box.y); take(box.x + box.width, box.y + box.height); }
  for (const line of lines) {
    for (const p of line.points) take(p.x, p.y);
    for (const head of line.heads) for (const p of head.points) take(p.x, p.y);
  }
  for (const l of labels) { take(l.x - 3, l.y); take(l.x + l.width + 3, l.y + l.height); }
  if (minX === Infinity) { minX = 0; minY = 0; maxX = 0; maxY = 0; }
  const margin = 12;
  const dx = margin - minX, dy = margin - minY;
  const move = (p: Point): Point => ({ x: p.x + dx, y: p.y + dy });
  return {
    kind, width: maxX - minX + margin * 2, height: maxY - minY + margin * 2,
    boxes: boxes.map((b) => ({ ...b, x: b.x + dx, y: b.y + dy })),
    lines: lines.map((l) => ({ points: l.points.map(move), stroke: l.stroke,
      heads: l.heads.map((h) => ({ points: h.points.map(move), filled: h.filled })) })),
    labels: labels.map((l) => ({ ...l, x: l.x + dx, y: l.y + dy })),
    summary,
  };
}

type HeadKind = "arrow" | "open" | "cross" | "circle";

/** A line's end at `tip`, pointing away from `from`. */
function head(kind: HeadKind, tip: Point, from: Point): Head[] {
  const dx = tip.x - from.x, dy = tip.y - from.y;
  const length = Math.sqrt(dx * dx + dy * dy);
  if (!(length > 0)) return [];
  const ux = dx / length, uy = dy / length, nx = -uy, ny = ux;
  const at = (back: number, side: number): Point => ({ x: tip.x - ux * back + nx * side, y: tip.y - uy * back + ny * side });
  switch (kind) {
    case "arrow": return [{ points: [at(9, 4.5), tip, at(9, -4.5)], filled: true }];
    case "open": return [{ points: [at(9, 4.5), tip, at(9, -4.5)], filled: false }];
    case "cross": return [{ points: [at(9, 4), at(1, -4)], filled: false }, { points: [at(9, -4), at(1, 4)], filled: false }];
    case "circle": {
      const points: Point[] = [];
      for (let step = 0; step < 8; step++) {
        const angle = step * Math.PI / 4;
        points.push(at(4 + 4 * Math.cos(angle), 4 * Math.sin(angle)));
      }
      return [{ points, filled: true }];
    }
  }
}

interface Statement { line: number; text: string }

/** A diagram's text as statements: comments, directives and front matter left out, a line split at its semicolons. */
function statementsOf(text: string): Statement[] {
  const statements: Statement[] = [];
  let inFrontMatter = false;
  let seenContent = false;
  text.split("\n").forEach((raw, index) => {
    const line = raw.trim();
    if (line === "---" && (!seenContent || inFrontMatter)) {
      inFrontMatter = !inFrontMatter;
      seenContent = true;
      return;
    }
    if (inFrontMatter || line === "" || line.startsWith("%%")) return;
    seenContent = true;
    for (const part of splitSemicolons(line)) {
      const trimmed = trimSpaces(part);
      if (trimmed) statements.push({ line: index + 1, text: trimmed });
    }
  });
  return statements;
}

function splitSemicolons(line: string): string[] {
  const parts: string[] = [];
  let current = "";
  let quoted = false;
  for (const character of line) {
    if (character === "\"") quoted = !quoted;
    if (character === ";" && !quoted) { parts.push(current); current = ""; } else current += character;
  }
  parts.push(current);
  return parts;
}

const firstWord = (text: string) => text.split(" ")[0] ?? "";

// MARK: Flowchart

type Direction = "TD" | "BT" | "LR" | "RL";
interface FlowNode { id: string; lines: string[]; shape: Shape }
interface FlowEdge {
  from: number; to: number; lines: string[];
  /** Null for `~~~`, a link that places the nodes and is not drawn. */
  stroke: Stroke | null; start?: HeadKind | undefined; end?: HeadKind | undefined;
}
interface Flowchart { direction: Direction; nodes: FlowNode[]; edges: FlowEdge[]; index: Map<string, number> }

function readFlowchart(statements: Statement[]): Flowchart | { problem: MermaidProblem } {
  const chart: Flowchart = { direction: "TD", nodes: [], edges: [], index: new Map() };
  for (const [number, statement] of statements.entries()) {
    let text = statement.text;
    if (number === 0) {
      // `graph LR`, and perhaps a first statement after it on the same line.
      const [, , first, rest = ""] = /^(\S+)(?:[ \t]+(\S+))?(?:[ \t]+(.*))?$/.exec(text) ?? [];
      if (first !== undefined) {
        switch (first.toUpperCase()) {
          case "TD": case "TB": chart.direction = "TD"; break;
          case "BT": chart.direction = "BT"; break;
          case "LR": chart.direction = "LR"; break;
          case "RL": chart.direction = "RL"; break;
          default: return fail({ kind: "unreadable", line: statement.line, text });
        }
      }
      text = rest;
      if (!text) continue;
    }
    switch (firstWord(text)) {
      case "classDef": case "class": case "style": case "linkStyle": case "click":
        // How it looks or what a click does: the page draws it in its own colours.
        continue;
      case "subgraph": case "end":
        return fail({ kind: "unsupported", what: "subgraphs" });
      default:
        if (!flowStatement(chart, text)) return fail({ kind: "unreadable", line: statement.line, text });
    }
    if (chart.nodes.length > elementLimit || chart.edges.length > elementLimit * 2) return fail({ kind: "tooBig" });
  }
  if (chart.nodes.length === 0) return fail({ kind: "empty" });
  return chart;
}

/** `A[One] --> B & C -- label --> D`. False when it does not read. */
function flowStatement(chart: Flowchart, text: string): boolean {
  const scanner = new Scanner(text);
  let group = nodeGroup(chart, scanner);
  if (!group) return false;
  for (;;) {
    scanner.skipSpaces();
    if (scanner.atEnd) return true;
    const link = scanner.link();
    if (!link) return false;
    const next = nodeGroup(chart, scanner);
    if (!next) return false;
    for (const from of group) {
      for (const to of next) {
        chart.edges.push({ from, to, lines: link.text === undefined ? [] : textLines(link.text),
          stroke: link.stroke, start: link.start, end: link.end });
      }
    }
    group = next;
  }
}

function nodeGroup(chart: Flowchart, scanner: Scanner): number[] | null {
  const group: number[] = [];
  do {
    scanner.skipSpaces();
    const read = scanner.node();
    if (!read) return null;
    group.push(addNode(chart, read));
    scanner.skipSpaces();
  } while (scanner.take("&"));
  return group;
}

function addNode(chart: Flowchart, read: ReadNode): number {
  const known = chart.index.get(read.id);
  if (known !== undefined) {
    if (read.shape) {
      chart.nodes[known]!.shape = read.shape;
      chart.nodes[known]!.lines = textLines(read.text ?? read.id);
    }
    return known;
  }
  chart.index.set(read.id, chart.nodes.length);
  chart.nodes.push({ id: read.id, lines: textLines(read.text ?? read.id), shape: read.shape ?? "rectangle" });
  return chart.nodes.length - 1;
}

function nodeSize(node: FlowNode): { width: number; height: number } {
  const text = measure(node.lines);
  switch (node.shape) {
    case "diamond": return { width: (text.width + 24) * 1.5, height: (text.height + 16) * 1.5 };
    case "circle": {
      const side = Math.max(text.width + 24, text.height + 24);
      return { width: side, height: side };
    }
    default: return { width: Math.max(text.width + 28, 48), height: text.height + 18 };
  }
}

/** Whether the line from `a` to `b` passes through the box, kept a point inside its edge. */
function crosses(a: Point, b: Point, box: Box): boolean {
  let enter = 0, leave = 1;
  for (const [start, step, low, high] of [[a.x, b.x - a.x, box.x + 1, box.x + box.width - 1], [a.y, b.y - a.y, box.y + 1, box.y + box.height - 1]] as const) {
    if (step === 0) {
      if (start < low || start > high) return false;
    } else {
      const first = (low - start) / step, second = (high - start) / step;
      enter = Math.max(enter, Math.min(first, second));
      leave = Math.min(leave, Math.max(first, second));
      if (enter > leave) return false;
    }
  }
  return true;
}

/** Where a line from the box's centre toward `point` leaves the box. */
function border(box: Box, point: Point): Point {
  const centre = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
  const dx = point.x - centre.x, dy = point.y - centre.y;
  if (dx === 0 && dy === 0) return centre;
  const halfWidth = box.width / 2, halfHeight = box.height / 2;
  let scale: number;
  switch (box.shape) {
    case "diamond": scale = 1 / (Math.abs(dx) / halfWidth + Math.abs(dy) / halfHeight); break;
    case "circle": scale = halfWidth / Math.sqrt(dx * dx + dy * dy); break;
    default: scale = Math.min(dx === 0 ? Infinity : halfWidth / Math.abs(dx), dy === 0 ? Infinity : halfHeight / Math.abs(dy));
  }
  return { x: centre.x + dx * scale, y: centre.y + dy * scale };
}

/** Each node's rank: one below the deepest node with a forward link into it. A link back to a node still being walked closes a cycle, and is left out. */
function ranksOf(chart: Flowchart): number[] {
  const state = chart.nodes.map(() => 0);
  const finished: number[] = [];
  const forward = chart.edges.map(() => true);
  const visit = (node: number) => {
    state[node] = 1;
    chart.edges.forEach((edge, number) => {
      if (edge.from !== node) return;
      if (edge.to === node || state[edge.to] === 1) forward[number] = false;
      else if (state[edge.to] === 0) visit(edge.to);
    });
    state[node] = 2;
    finished.push(node);
  };
  chart.nodes.forEach((_, node) => { if (state[node] === 0) visit(node); });
  const rank = chart.nodes.map(() => 0);
  for (const node of [...finished].reverse()) {
    chart.edges.forEach((edge, number) => {
      if (edge.from === node && forward[number]) rank[edge.to] = Math.max(rank[edge.to]!, rank[node]! + 1);
    });
  }
  return rank;
}

/** Layered, as MermaidFlowchart.laidOut: ranks, a few sweeps to order each rank, then places. */
function layOutFlowchart(chart: Flowchart): MermaidDiagram {
  const { nodes, edges, direction } = chart;
  const sizes = nodes.map(nodeSize);
  const ranks = ranksOf(chart);
  const rankCount = Math.max(0, ...ranks) + 1;
  const layers: number[][] = Array.from({ length: rankCount }, () => []);
  nodes.forEach((_, node) => layers[ranks[node]!]!.push(node));
  const place = nodes.map(() => 0);
  for (const layer of layers) layer.forEach((node, position) => { place[node] = position; });

  const sweep = (order: number[], neighbours: (node: number) => number[]) => {
    for (const rank of order) {
      const keyed = layers[rank]!.map((node) => {
        const around = neighbours(node);
        const key = around.length === 0 ? place[node]! : around.reduce((sum, n) => sum + place[n]!, 0) / around.length;
        return { key, place: place[node]!, node };
      });
      keyed.sort((a, b) => a.key - b.key || a.place - b.place);
      layers[rank] = keyed.map((k) => k.node);
      layers[rank]!.forEach((node, position) => { place[node] = position; });
    }
  };
  const drawn = edges.filter((e) => e.from !== e.to);
  const down = Array.from({ length: Math.max(0, rankCount - 1) }, (_, i) => i + 1);
  const up = Array.from({ length: Math.max(0, rankCount - 1) }, (_, i) => rankCount - 2 - i);
  for (let pass = 0; pass < 4; pass++) {
    sweep(down, (node) => drawn.filter((e) => e.to === node && ranks[e.from]! < ranks[node]!).map((e) => e.from));
    sweep(up, (node) => drawn.filter((e) => e.from === node && ranks[e.to]! > ranks[node]!).map((e) => e.to));
  }

  const sideways = direction === "LR" || direction === "RL";
  const rankGap = sideways ? 64 : 52;
  const nodeGap = sideways ? 22 : 28;
  const along = (s: { width: number; height: number }) => (sideways ? s.width : s.height);
  const across = (s: { width: number; height: number }) => (sideways ? s.height : s.width);
  const spans = layers.map((layer) => layer.reduce((sum, n) => sum + across(sizes[n]!), 0) + nodeGap * Math.max(0, layer.length - 1));
  const widest = Math.max(0, ...spans);
  let centres: Point[] = nodes.map(() => ({ x: 0, y: 0 }));
  let depth = 0;
  layers.forEach((layer, rank) => {
    const thickness = Math.max(0, ...layer.map((n) => along(sizes[n]!)));
    let side = (widest - spans[rank]!) / 2;
    for (const node of layer) {
      const middle = side + across(sizes[node]!) / 2;
      const deep = depth + thickness / 2;
      centres[node] = sideways ? { x: deep, y: middle } : { x: middle, y: deep };
      side += across(sizes[node]!) + nodeGap;
    }
    depth += thickness + rankGap;
  });
  const extent = depth - rankGap;
  if (direction === "BT") centres = centres.map((c) => ({ x: c.x, y: extent - c.y }));
  if (direction === "RL") centres = centres.map((c) => ({ x: extent - c.x, y: c.y }));

  const boxes: Box[] = nodes.map((node, i) => ({
    x: centres[i]!.x - sizes[i]!.width / 2, y: centres[i]!.y - sizes[i]!.height / 2,
    width: sizes[i]!.width, height: sizes[i]!.height, shape: node.shape,
  }));
  const lines: Line[] = [];
  const labels: Label[] = [];
  let lanes = 0;
  for (const edge of edges) {
    if (edge.stroke === null) continue;
    const self = edge.from === edge.to;
    let points: Point[];
    if (self) {
      const box = boxes[edge.from]!;
      const right = box.x + box.width, middle = box.y + box.height / 2;
      points = [{ x: right, y: middle - 8 }, { x: right + 22, y: middle - 8 }, { x: right + 22, y: middle + 8 }, { x: right, y: middle + 8 }];
    } else {
      points = [border(boxes[edge.from]!, centres[edge.to]!), border(boxes[edge.to]!, centres[edge.from]!)];
      const crossed = boxes.some((box, node) => node !== edge.from && node !== edge.to && crosses(points[0]!, points[1]!, box));
      if (crossed) {
        // A straight line would cross another box, as a link back up does: it goes round the side instead, in a lane of its own.
        const low = Math.min(ranks[edge.from]!, ranks[edge.to]!), high = Math.max(ranks[edge.from]!, ranks[edge.to]!);
        const beside = boxes.filter((_, node) => ranks[node]! >= low && ranks[node]! <= high);
        const a = boxes[edge.from]!, b = boxes[edge.to]!;
        if (sideways) {
          const lane = Math.max(0, ...beside.map((x) => x.y + x.height)) + 18 + lanes * 12;
          points = [{ x: a.x + a.width / 2, y: a.y + a.height }, { x: a.x + a.width / 2, y: lane },
            { x: b.x + b.width / 2, y: lane }, { x: b.x + b.width / 2, y: b.y + b.height }];
        } else {
          const lane = Math.max(0, ...beside.map((x) => x.x + x.width)) + 18 + lanes * 12;
          points = [{ x: a.x + a.width, y: a.y + a.height / 2 }, { x: lane, y: a.y + a.height / 2 },
            { x: lane, y: b.y + b.height / 2 }, { x: b.x + b.width, y: b.y + b.height / 2 }];
        }
        lanes++;
      }
    }
    const heads: Head[] = [];
    if (edge.end) heads.push(...head(edge.end, points[points.length - 1]!, points[points.length - 2]!));
    if (edge.start) heads.push(...head(edge.start, points[0]!, points[1]!));
    lines.push({ points, stroke: edge.stroke, heads });
    if (edge.lines.length > 0) {
      // On the middle stretch of the line: the only one, or the lane's.
      const a = points[points.length === 4 ? 1 : 0]!, b = points[points.length === 4 ? 2 : 1]!;
      const centreX = (a.x + b.x) / 2 + (self ? measure(edge.lines).width / 2 + 6 : 0);
      labels.push(label(centreX, (a.y + b.y) / 2, edge.lines, true));
    }
  }
  nodes.forEach((node, i) => labels.push(label(centres[i]!.x, centres[i]!.y, node.lines)));
  return framed("flowchart", boxes, lines, labels, `Flowchart · ${nodes.length} ${nodes.length === 1 ? "box" : "boxes"}`);
}

interface ReadNode { id: string; text?: string | undefined; shape?: Shape | undefined }
interface Link { stroke: Stroke | null; start?: HeadKind | undefined; end?: HeadKind | undefined; text?: string | undefined }

/** Openers, longest first, each with the closers it takes and the shape it makes. */
const shapes: { open: string; close: string[]; shape: Shape }[] = [
  { open: "(((", close: [")))"], shape: "circle" }, { open: "((", close: ["))"], shape: "circle" },
  { open: "([", close: ["])"], shape: "stadium" }, { open: "[[", close: ["]]"], shape: "rectangle" },
  { open: "[(", close: [")]"], shape: "rectangle" }, { open: "[/", close: ["/]", "\\]"], shape: "rectangle" },
  { open: "[\\", close: ["\\]", "/]"], shape: "rectangle" }, { open: "{{", close: ["}}"], shape: "rounded" },
  { open: "{", close: ["}"], shape: "diamond" }, { open: "(", close: [")"], shape: "rounded" },
  { open: "[", close: ["]"], shape: "rectangle" }, { open: ">", close: ["]"], shape: "rectangle" },
];
const linkCharacters = new Set(["-", "=", ".", "~"]);
const isIDCharacter = (c: string | undefined) => c !== undefined && /[\p{L}\p{N}_]/u.test(c);

/** A Markdown string's backquotes left out: "`**bold**`" reads as its words. */
function unquoted(text: string): string {
  return text.length >= 2 && text.startsWith("`") && text.endsWith("`") ? text.slice(1, -1) : text;
}

/** A link's line from its characters: null for `~~~`, which is not drawn; undefined for anything that is not a link. */
function strokeOf(body: string): Stroke | null | undefined {
  const all = (c: string) => [...body].every((x) => x === c);
  if (body.length >= 2 && all("-")) return "solid";
  if (body.length >= 2 && all("=")) return "thick";
  if (body.length >= 3 && all("~")) return null;
  if (body.length >= 3 && body.startsWith("-") && body.endsWith("-") && /^\.+$/.test(body.slice(1, -1))) return "dashed";
  return undefined;
}

/** Reads a flowchart statement a piece at a time. */
class Scanner {
  private readonly characters: string[];
  position = 0;

  constructor(text: string) { this.characters = [...text]; }

  get atEnd(): boolean { return this.position >= this.characters.length; }

  peek(offset = 0): string | undefined { return this.characters[this.position + offset]; }

  has(text: string): boolean {
    const wanted = [...text];
    return wanted.every((c, i) => this.characters[this.position + i] === c);
  }

  take(text: string): boolean {
    if (!this.has(text)) return false;
    this.position += [...text].length;
    return true;
  }

  skipSpaces(): void {
    while (this.peek() === " " || this.peek() === "\t") this.position++;
  }

  private slice(from: number, to = this.position): string { return this.characters.slice(from, to).join(""); }

  /** `id`, `id[text]`, `id("quoted text")`, and a `:::class` after it, left out. */
  node(): ReadNode | null {
    const start = this.position;
    while (isIDCharacter(this.peek())) this.position++;
    if (this.position === start) return null;
    const node: ReadNode = { id: this.slice(start) };
    for (const entry of shapes) {
      if (!this.take(entry.open)) continue;
      const text = this.shapeText(entry.close);
      if (text === null) return null;
      node.text = text;
      node.shape = entry.shape;
      break;
    }
    if (this.take(":::")) while (isIDCharacter(this.peek()) || this.peek() === "-") this.position++;
    return node;
  }

  private shapeText(closers: string[]): string | null {
    this.skipSpaces();
    if (this.peek() === "\"") {
      this.position++;
      const start = this.position;
      while (!this.atEnd && this.peek() !== "\"") this.position++;
      if (this.atEnd) return null;
      const text = this.slice(start);
      this.position++;
      this.skipSpaces();
      for (const closer of closers) if (this.take(closer)) return unquoted(text);
      return null;
    }
    const start = this.position;
    while (!this.atEnd) {
      for (const closer of closers) {
        if (this.has(closer)) {
          const text = trimSpaces(this.slice(start));
          this.position += [...closer].length;
          return unquoted(text);
        }
      }
      this.position++;
    }
    return null;
  }

  /** `-->`, `---`, `-.->`, `==>`, `~~~`, `<-->`, `--x`, `--o`, with `|text|` after or `-- text -->` around its words. */
  link(): Link | null {
    const link: Link = { stroke: "solid" };
    if (this.take("<")) link.start = "arrow";
    const start = this.position;
    while (linkCharacters.has(this.peek() ?? "")) this.position++;
    const body = this.slice(start);
    if ((body === "--" || body === "==" || body === "-.") && this.peek() === " ") {
      const textStart = this.position;
      while (!this.atEnd && !(linkCharacters.has(this.peek() ?? "") && linkCharacters.has(this.peek(1) ?? ""))) this.position++;
      if (this.atEnd) return null;
      link.text = trimSpaces(this.slice(textStart));
      while (linkCharacters.has(this.peek() ?? "")) this.position++;
      link.stroke = body === "==" ? "thick" : body === "-." ? "dashed" : "solid";
    } else {
      const stroke = strokeOf(body);
      if (stroke === undefined) return null;
      link.stroke = stroke;
    }
    const after = this.peek(1);
    if (this.take(">")) {
      link.end = "arrow";
    } else if ((this.peek() === "x" || this.peek() === "o") && (after === undefined || after === " " || after === "|")) {
      link.end = this.peek() === "x" ? "cross" : "circle";
      this.position++;
    }
    if (link.start !== undefined && link.end === undefined) return null;
    if (link.text === undefined) {
      this.skipSpaces();
      if (this.take("|")) {
        const textStart = this.position;
        while (!this.atEnd && this.peek() !== "|") this.position++;
        if (this.atEnd) return null;
        link.text = unquoted(trimSpaces(this.slice(textStart)).replace(/^"+|"+$/g, ""));
        this.position++;
      }
    }
    if (link.text === "") link.text = undefined;
    return link;
  }
}

// MARK: Sequence diagram

type NoteSide = "left" | "right" | "over";
type SequenceEvent =
  | { kind: "message"; from: number; to: number; lines: string[]; dashed: boolean; start?: HeadKind | undefined; end?: HeadKind | undefined }
  | { kind: "note"; a: number; b?: number | undefined; side: NoteSide; lines: string[] }
  | { kind: "open"; frame: string; lines: string[] }
  | { kind: "divider"; lines: string[] }
  | { kind: "close" };
interface Sequence { participants: { id: string; lines: string[] }[]; events: SequenceEvent[]; index: Map<string, number> }

const frames = new Set(["loop", "alt", "opt", "par", "critical", "break", "rect"]);
const dividers = new Set(["else", "and", "option"]);
const ignored = new Set(["activate", "deactivate", "title", "title:", "accTitle:", "accDescr:"]);
const refused = new Map([
  ["box", "boxes around participants"], ["create", "created participants"], ["destroy", "destroyed participants"],
  ["link", "participant links"], ["links", "participant links"], ["properties", "participant properties"],
  ["details", "participant details"],
]);
/** Longest first, so `-->>` is not read as `-->`. */
const arrows: { text: string; dashed: boolean; start?: HeadKind; end?: HeadKind }[] = [
  { text: "<<-->>", dashed: true, start: "arrow", end: "arrow" }, { text: "<<->>", dashed: false, start: "arrow", end: "arrow" },
  { text: "-->>", dashed: true, end: "arrow" }, { text: "->>", dashed: false, end: "arrow" },
  { text: "--x", dashed: true, end: "cross" }, { text: "-x", dashed: false, end: "cross" },
  { text: "--)", dashed: true, end: "open" }, { text: "-)", dashed: false, end: "open" },
  { text: "-->", dashed: true }, { text: "->", dashed: false },
];

function participantOf(sequence: Sequence, id: string): number {
  const known = sequence.index.get(id);
  if (known !== undefined) return known;
  sequence.index.set(id, sequence.participants.length);
  sequence.participants.push({ id, lines: textLines(id) });
  return sequence.participants.length - 1;
}

/** `A->>B: words`, with a `+` or `-` before B for an activation, which is not drawn. */
function messageOf(sequence: Sequence, text: string): SequenceEvent | null {
  for (let position = 0; position < text.length; position++) {
    for (const arrow of arrows) {
      if (!text.startsWith(arrow.text, position)) continue;
      const from = trimSpaces(text.slice(0, position));
      let rest = trimSpaces(text.slice(position + arrow.text.length));
      if (rest.startsWith("+") || rest.startsWith("-")) rest = rest.slice(1);
      const colon = rest.indexOf(":");
      const to = trimSpaces(colon < 0 ? rest : rest.slice(0, colon));
      const words = colon < 0 ? "" : trimSpaces(rest.slice(colon + 1));
      if (!from || !to) return null;
      return { kind: "message", from: participantOf(sequence, from), to: participantOf(sequence, to),
        lines: words ? textLines(words) : [], dashed: arrow.dashed, start: arrow.start, end: arrow.end };
    }
  }
  return null;
}

/** `right of A: words`, `left of A: words`, `over A: words`, `over A,B: words`. */
function noteOf(sequence: Sequence, text: string): SequenceEvent | null {
  const colon = text.indexOf(":");
  if (colon < 0) return null;
  const place = trimSpaces(text.slice(0, colon));
  const words = textLines(trimSpaces(text.slice(colon + 1)));
  const lower = place.toLowerCase();
  let side: NoteSide;
  let names: string;
  if (lower.startsWith("right of ")) { side = "right"; names = place.slice(9); }
  else if (lower.startsWith("left of ")) { side = "left"; names = place.slice(8); }
  else if (lower.startsWith("over ")) { side = "over"; names = place.slice(5); }
  else return null;
  const ids = names.split(",").map(trimSpaces).filter(Boolean);
  if (ids.length === 0 || ids.length > 2) return null;
  const a = participantOf(sequence, ids[0]!);
  const b = ids.length === 2 ? participantOf(sequence, ids[1]!) : undefined;
  return { kind: "note", a, b: side === "over" ? b : undefined, side, lines: words };
}

function readSequence(statements: Statement[]): Sequence | { problem: MermaidProblem } {
  const sequence: Sequence = { participants: [], events: [], index: new Map() };
  let numbered = false;
  let number = 0;
  let depth = 0;
  for (const statement of statements.slice(1)) {
    const text = statement.text;
    const first = firstWord(text);
    const rest = trimSpaces(text.slice(first.length));
    const word = first.toLowerCase();
    const what = refused.get(word);
    if (what !== undefined) return fail({ kind: "unsupported", what });
    if (ignored.has(first)) continue;
    if (word === "autonumber") { numbered = true; continue; }
    const unreadable = () => fail({ kind: "unreadable", line: statement.line, text });
    if (word === "participant" || word === "actor") {
      const parts = rest.split(" as ");
      const id = trimSpaces(parts[0] ?? "");
      if (!id) return unreadable();
      const shown = parts.length > 1 ? trimSpaces(parts.slice(1).join(" as ")) : id;
      const known = sequence.index.get(id);
      if (known !== undefined) sequence.participants[known]!.lines = textLines(shown);
      else {
        sequence.index.set(id, sequence.participants.length);
        sequence.participants.push({ id, lines: textLines(shown) });
      }
      continue;
    }
    if (word === "note") {
      const note = noteOf(sequence, rest);
      if (!note) return unreadable();
      sequence.events.push(note);
      continue;
    }
    if (frames.has(word)) {
      depth++;
      sequence.events.push({ kind: "open", frame: word, lines: word === "rect" ? [] : textLines(rest) });
      continue;
    }
    if (dividers.has(word)) {
      if (depth === 0) return unreadable();
      sequence.events.push({ kind: "divider", lines: textLines(rest) });
      continue;
    }
    if (word === "end") {
      if (depth === 0) return unreadable();
      depth--;
      sequence.events.push({ kind: "close" });
      continue;
    }
    const message = messageOf(sequence, text);
    if (!message || message.kind !== "message") return unreadable();
    if (numbered) {
      number++;
      const lines = message.lines.length === 0 ? [""] : [...message.lines];
      lines[0] = `${number}. ${lines[0]}`;
      message.lines = lines;
    }
    sequence.events.push(message);
    if (sequence.events.length > elementLimit * 2) return fail({ kind: "tooBig" });
  }
  for (let i = 0; i < depth; i++) sequence.events.push({ kind: "close" });
  if (sequence.participants.length === 0) return fail({ kind: "empty" });
  if (sequence.participants.length > elementLimit / 10) return fail({ kind: "tooBig" });
  return sequence;
}

/** Participants in columns spaced so every message's words fit, then a row per message, note and frame. */
function layOutSequence(sequence: Sequence): MermaidDiagram {
  const { participants, events } = sequence;
  const columns = participants.length;
  const headSizes = participants.map((p) => {
    const text = measure(p.lines);
    return { width: Math.max(text.width + 24, 90), height: text.height + 16 };
  });
  const headHeight = Math.max(0, ...headSizes.map((s) => s.height));
  const gaps = Array.from({ length: Math.max(0, columns - 1) }, (_, i) => headSizes[i]!.width / 2 + headSizes[i + 1]!.width / 2 + 30);
  const needs: { low: number; high: number; room: number }[] = [];
  for (const event of events) {
    if (event.kind === "message") {
      const width = measure(event.lines).width;
      if (event.from === event.to) needs.push({ low: event.from, high: event.from + 1, room: width + 44 });
      else needs.push({ low: Math.min(event.from, event.to), high: Math.max(event.from, event.to), room: width + 30 });
    } else if (event.kind === "note") {
      const width = measure(event.lines).width + 16;
      if (event.side === "right") needs.push({ low: event.a, high: event.a + 1, room: width + 20 });
      else if (event.side === "left") needs.push({ low: event.a - 1, high: event.a, room: width + 20 });
      else if (event.b !== undefined) needs.push({ low: Math.min(event.a, event.b), high: Math.max(event.a, event.b), room: width - 50 });
    }
  }
  // Stable, as Swift's sort is for these: by span, then as written.
  const ordered = needs.map((need, i) => ({ need, i })).sort((a, b) => (a.need.high - a.need.low) - (b.need.high - b.need.low) || a.i - b.i);
  for (const { need } of ordered) {
    // Past either end there is nothing to push aside: the frame grows to fit.
    if (need.low >= 0 && need.high < columns && need.high > need.low) {
      const have = gaps.slice(need.low, need.high).reduce((sum, g) => sum + g, 0);
      if (have < need.room) gaps[need.high - 1]! += need.room - have;
    }
  }
  const xs = [0];
  for (const gap of gaps) xs.push(xs[xs.length - 1]! + gap);

  const boxes: Box[] = [];
  const lines: Line[] = [];
  const labels: Label[] = [];
  const frameBoxes: Box[] = [];
  interface OpenFrame { frame: string; lines: string[]; top: number; low: number; high: number; dividers: { y: number; lines: string[] }[] }
  const open: OpenFrame[] = [];
  const reach = (low: number, high: number) => {
    for (const frame of open) { frame.low = Math.min(frame.low, low); frame.high = Math.max(frame.high, high); }
  };

  let y = headHeight + 24;
  for (const event of events) {
    switch (event.kind) {
      case "message": {
        const size = measure(event.lines);
        const stroke: Stroke = event.dashed ? "dashed" : "solid";
        if (event.from === event.to) {
          const x = xs[event.from]!;
          const tall = Math.max(size.height, 24);
          const points = [{ x, y }, { x: x + 30, y }, { x: x + 30, y: y + tall }, { x: x + 2, y: y + tall }];
          const heads = event.end ? head(event.end, points[3]!, points[2]!) : [];
          lines.push({ points, stroke, heads });
          if (event.lines.length > 0) labels.push(leadingLabel(x + 38, y + tall / 2, event.lines));
          reach(x, x + 38 + size.width);
          y += tall + 18;
        } else {
          const middle = (xs[event.from]! + xs[event.to]!) / 2;
          if (event.lines.length > 0) labels.push(label(middle, y + size.height / 2, event.lines));
          const arrowY = y + size.height + 4;
          const a = { x: xs[event.from]!, y: arrowY }, b = { x: xs[event.to]!, y: arrowY };
          const heads: Head[] = [];
          if (event.end) heads.push(...head(event.end, b, a));
          if (event.start) heads.push(...head(event.start, a, b));
          lines.push({ points: [a, b], stroke, heads });
          reach(Math.min(a.x, b.x, middle - size.width / 2), Math.max(a.x, b.x, middle + size.width / 2));
          y = arrowY + 18;
        }
        break;
      }
      case "note": {
        const size = measure(event.lines);
        const width = size.width + 16, height = size.height + 12;
        let left: number;
        let noteWidth = width;
        if (event.side === "right") left = xs[event.a]! + 10;
        else if (event.side === "left") left = xs[event.a]! - 10 - width;
        else if (event.b !== undefined) {
          const low = Math.min(xs[event.a]!, xs[event.b]!) - 25, high = Math.max(xs[event.a]!, xs[event.b]!) + 25;
          noteWidth = Math.max(high - low, width);
          left = (low + high) / 2 - noteWidth / 2;
        } else {
          noteWidth = Math.max(width, 80);
          left = xs[event.a]! - noteWidth / 2;
        }
        boxes.push({ x: left, y, width: noteWidth, height, shape: "note" });
        labels.push(label(left + noteWidth / 2, y + height / 2, event.lines));
        reach(left, left + noteWidth);
        y += height + 14;
        break;
      }
      case "open":
        open.push({ frame: event.frame, lines: event.lines, top: y, low: Infinity, high: -Infinity, dividers: [] });
        y += 28;
        break;
      case "divider":
        open[open.length - 1]!.dividers.push({ y, lines: event.lines });
        y += 28;
        break;
      case "close": {
        const frame = open.pop()!;
        const pad = 12;
        let low = frame.low, high = frame.high;
        if (low === Infinity) {
          low = xs[0]! - headSizes[0]!.width / 2 + pad;
          high = xs[xs.length - 1]! + headSizes[headSizes.length - 1]!.width / 2 - pad;
        }
        const left = low - pad;
        const right = Math.max(high + pad, left + (count(frame.frame) + 3) * characterWidth + measure(frame.lines).width + 12);
        frameBoxes.push({ x: left, y: frame.top, width: right - left, height: y + 2 - frame.top, shape: "frame" });
        if (frame.frame !== "rect") {
          const first = frame.lines[0];
          const title = first === undefined || first === "" ? frame.frame : `${frame.frame} [${first}]`;
          labels.push(leadingLabel(left + 6, frame.top + 4 + lineHeight / 2, [title]));
        }
        for (const divider of frame.dividers) {
          lines.push({ points: [{ x: left, y: divider.y }, { x: right, y: divider.y }], stroke: "dashed", heads: [] });
          const words = divider.lines[0];
          if (words) labels.push(leadingLabel(left + 6, divider.y + 4 + lineHeight / 2, [`[${words}]`]));
        }
        reach(left, right);
        y += 14;
        break;
      }
    }
  }
  const bottom = y + 6;
  const lifelines: Line[] = [];
  participants.forEach((participant, column) => {
    const size = headSizes[column]!;
    for (const top of [0, bottom]) {
      boxes.push({ x: xs[column]! - size.width / 2, y: top + (headHeight - size.height) / 2, width: size.width, height: size.height, shape: "rectangle" });
      labels.push(label(xs[column]!, top + headHeight / 2, participant.lines));
    }
    lifelines.push({ points: [{ x: xs[column]!, y: headHeight }, { x: xs[column]!, y: bottom }], stroke: "dashed", heads: [] });
  });
  const messages = events.filter((e) => e.kind === "message").length;
  return framed("sequence", [...frameBoxes, ...boxes], [...lifelines, ...lines], labels,
    `Sequence diagram · ${messages} ${messages === 1 ? "message" : "messages"}`);
}
