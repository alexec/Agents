// A session's Lineage pane (#2940), as LineageList has it on the window: the nodes the session is
// linked to, from lineage/walk (depth 2), each with its links and, for an issue or a PR, what
// lineage/cost says was banked on it.
import type { LineageCostRollup, LineageGraph, LineageLink, LineageNode } from "../protocol/generated";
import { timeWords } from "./time";
import { costWords, nodeName, nodeUrl, spent } from "./value";

/** How far the pane walks: issue, its sessions, their PRs. */
export const lineageDepth = 2;

export const sessionNode = (id: string): LineageNode => ({ kind: "session", ref: `session:${id}` });

const key = (n: LineageNode) => `${n.kind}\n${n.ref}`;
const same = (a: LineageNode, b: LineageNode) => a.kind === b.kind && a.ref === b.ref;

export interface LineageRow {
  node: LineageNode;
  /** "alexec/agents#12", or the session's title. */
  name: string;
  /** One line per link to it: "This session works on it · from the branch". */
  links: string[];
  /** "$4.00 · 12m working · merged", for an issue or a PR whose cost has come. */
  cost?: string | undefined;
  /** The session it is, for a session node. */
  session?: string | undefined;
  /** Where a GitHub issue, PR or milestone is, as LineageList.Row.url has it. */
  url?: string | undefined;
}


/** A node's address on GitHub: a PR's is its /pull/ page. */
export function lineageUrl(n: LineageNode): string | undefined {
  const url = nodeUrl(n);
  return url && n.kind === "pr" ? url.replace("/issues/", "/pull/") : url;
}

/** Whether a node's cost is asked for. */
export const costed = (n: LineageNode) => n.kind === "issue" || n.kind === "pr";

const sourceWords: Record<string, string> = {
  start: "when it started", branch: "from the branch", "pr-body": "from the PR's text", helper: "as a helper",
  agent: "by the agent", person: "by a person",
};

/** "This session works on it · from the branch", or "Fixes alexec/agents#12 · from the PR's text · ended". */
export function linkLine(link: LineageLink, of: LineageNode, session: LineageNode, name: (n: LineageNode) => string): string {
  const verb = link.rel.replaceAll("-", " ");
  const parts = [same(link.to, of) ? `${name(link.from)} ${verb} it` : `${verb.charAt(0).toUpperCase()}${verb.slice(1)} ${same(link.to, session) ? "this session" : name(link.to)}`];
  parts.push(sourceWords[link.source] ?? `from ${link.source}`);
  if (link.endedAt !== undefined) parts.push("ended");
  return parts.join(" · ");
}

/** "$4.00 · 12m working · 1 merged, 1 closed", or for a PR "… · merged". No cost or tokens when nothing
 * was spent: "0 tokens" says nothing. */
export function costLine(r: LineageCostRollup): string {
  const parts = spent(r.total) ? [costWords(r.total)] : [];
  if (r.total.workingSeconds > 0) parts.push(`${timeWords(r.total.workingSeconds)} working`);
  if (r.node.kind === "pr") {
    const outcome = r.parts.find((p) => same(p.node, r.node))?.outcome;
    parts.push(outcome === undefined ? "open" : outcome === "merged" ? "merged"
      : outcome === "closed" ? "closed without a merge: waste" : outcome === "reverted" ? "reverted: waste" : outcome);
  } else if (r.node.kind === "issue") {
    const ends: string[] = [];
    if (r.prsMerged > 0) ends.push(`${r.prsMerged} merged`);
    if (r.prsClosed > 0) ends.push(`${r.prsClosed} closed`);
    if (ends.length > 0) parts.push(ends.join(", "));
    if (spent(r.waste)) parts.push(`${costWords(r.waste)} wasted`);
  }
  return parts.length === 0 ? "Nothing banked yet" : parts.join(" · ");
}

/** A row for each node the walk reached, once, in the walk's order, the session itself left out. */
export function lineageRows(session: LineageNode, graph: LineageGraph, costs: ReadonlyMap<string, LineageCostRollup>,
  title: (n: LineageNode) => string | undefined): LineageRow[] {
  const seen = new Set<string>();
  const nodes = graph.nodes.filter((n) => !same(n, session) && !seen.has(key(n)) && (seen.add(key(n)), true));
  const name = (n: LineageNode) => same(n, session) ? "This session" : title(n) ?? nodeName(n);
  const rows: LineageRow[] = nodes.map((n) => {
    const rollup = costs.get(key(n));
    return {
      node: n, name: name(n),
      links: graph.links.filter((l) => same(l.from, n) || same(l.to, n)).map((l) => linkLine(l, n, session, name)),
      cost: rollup && costLine(rollup),
      session: n.kind === "session" ? n.ref.slice("session:".length) : undefined,
      url: lineageUrl(n),
    };
  });
  return rows;
}

// The pane as a graph of boxes and lines (#3019), as LineageLayout has it on the window: this
// session and the nodes it is linked to, a line for every link. The links are not a tree: a session
// that works on an issue and on the PR that fixes it makes a triangle.

/** The row for this session itself, a box of the graph. */
export const hereRow = (session: LineageNode): LineageRow => ({ node: session, name: "This session", links: [] });

/** Each node's links, either way, in the order the walk gave them. */
function neighbours(graph: LineageGraph): Map<string, LineageNode[]> {
  const next = new Map<string, LineageNode[]>();
  const add = (a: LineageNode, b: LineageNode) => { const list = next.get(key(a)) ?? []; list.push(b); next.set(key(a), list); };
  for (const l of graph.links) { add(l.from, l.to); add(l.to, l.from); }
  return next;
}

/** One box of the graph, its top-left corner in pixels. */
export interface GraphNode {
  row: LineageRow; x: number; y: number; here: boolean;
  /** The box's second line: "Issue · $4.00 · 12m working · merged". */
  detail: string;
}
/** One line of the graph: a link, from one box to another (by ref), named by its verb. */
export interface GraphEdge { from: string; to: string; label: string; ended: boolean }
export interface LineageGraphLayout { nodes: GraphNode[]; edges: GraphEdge[]; width: number; height: number }

/** A box's size and the room between them, as LineageLayout's. */
export const box = { width: 180, height: 52, tierGap: 56, gap: 16, margin: 16, arc: 40 } as const;

const kindWords: Record<string, string> = {
  issue: "Issue", pr: "Pull request", session: "Session", "workflow-run": "Workflow run", workflow: "Workflow", milestone: "Milestone",
};

/** "Issue", "Pull request": the first words of a box's second line. */
export const kindWord = (kind: string) => kindWords[kind] ?? kind;

export interface Point { x: number; y: number }
/** A cubic curve, and the point halfway along it. */
export interface Curve { start: Point; c1: Point; c2: Point; end: Point; mid: Point }

/** Where an edge's line goes: from the bottom or top of one box to the top or bottom of the other, or below a
 * tier for two boxes in it, with `mid` the point halfway for its label. */
export function curve(g: LineageGraphLayout, edge: GraphEdge): Curve | undefined {
  const a = g.nodes.find((n) => n.row.node.ref === edge.from), b = g.nodes.find((n) => n.row.node.ref === edge.to);
  if (!a || !b) return undefined;
  const ax = a.x + box.width / 2, bx = b.x + box.width / 2;
  let start: Point, end: Point, c1: Point, c2: Point;
  if (a.y === b.y) {
    start = { x: ax, y: a.y + box.height }; end = { x: bx, y: b.y + box.height };
    c1 = { x: ax, y: start.y + box.arc }; c2 = { x: bx, y: end.y + box.arc };
  } else {
    const down = a.y < b.y;
    start = { x: ax, y: down ? a.y + box.height : a.y }; end = { x: bx, y: down ? b.y : b.y + box.height };
    const dy = (end.y - start.y) / 2;
    c1 = { x: ax, y: start.y + dy }; c2 = { x: bx, y: end.y - dy };
  }
  const mid = { x: (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8, y: (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8 };
  return { start, c1, c2, end, mid };
}

/** The graph's tier for a kind, so it reads top to bottom: milestone, issue, session, PR. */
function tier(kind: string): number {
  switch (kind) {
    case "milestone": case "workflow": return 0;
    case "issue": case "workflow-run": return 1;
    case "session": return 2;
    case "pr": return 3;
    default: return 4;
  }
}

/** The graph: a tier per kind, top to bottom, empty tiers left out, each tier in the order of the boxes it links
 * to above it, so fewer lines cross. Tiers are centred on the widest. Top to bottom, so that it fits the files
 * pane: a walk has few tiers and few boxes in each. */
export function lineageGraph(session: LineageNode, walked: LineageGraph, costs: ReadonlyMap<string, LineageCostRollup>,
  title: (n: LineageNode) => string | undefined): LineageGraphLayout {
  const rows = lineageRows(session, walked, costs, title);
  if (rows.length === 0) return { nodes: [], edges: [], width: 0, height: 0 };
  const all = [hereRow(session), ...rows];
  const next = neighbours(walked);
  const index = new Map<string, number>();
  const tiers = [...new Set(all.map((r) => tier(r.node.kind)))].sort((a, b) => a - b).map((t) => {
    const ordered = all.flatMap((row, i) => tier(row.node.kind) === t ? [{ row, i }] : []).map(({ row, i }) => {
      const above = (next.get(key(row.node)) ?? []).flatMap((n) => index.has(key(n)) ? [index.get(key(n))!] : []);
      return { row, i, at: above.length === 0 ? Infinity : above.reduce((a, b) => a + b, 0) / above.length };
    }).sort((a, b) => (a.at === b.at ? 0 : a.at < b.at ? -1 : 1) || a.i - b.i).map(({ row }) => row);
    ordered.forEach((row, i) => { index.set(key(row.node), i); });
    return ordered;
  });
  const span = (n: number) => n * (box.width + box.gap) - box.gap;
  const wide = span(Math.max(...tiers.map((t) => t.length)));
  const nodes = tiers.flatMap((row, t) => row.map((r, i) => ({
    row: r, x: box.margin + (wide - span(row.length)) / 2 + i * (box.width + box.gap), y: box.margin + t * (box.height + box.tierGap),
    here: same(r.node, session), detail: [kindWord(r.node.kind), ...r.cost ? [r.cost] : []].join(" · "),
  })));
  const seen = new Set<string>();
  const edges = walked.links.flatMap((l) => {
    const id = `${l.from.ref}\n${l.rel}\n${l.to.ref}`;
    if (!index.has(key(l.from)) || !index.has(key(l.to)) || seen.has(id)) return [];
    seen.add(id);
    return [{ from: l.from.ref, to: l.to.ref, label: l.rel.replaceAll("-", " "), ended: l.endedAt !== undefined }];
  });
  // A line below the last tier needs room for its bend.
  const last = tiers.at(-1)!;
  const bends = edges.some((e) => [e.from, e.to].every((ref) => last.some((r) => r.node.ref === ref)));
  return { nodes, edges, width: 2 * box.margin + wide,
    height: 2 * box.margin + tiers.length * box.height + (tiers.length - 1) * box.tierGap + (bends ? box.arc : 0) };
}

export const costKey = key;

export const noLineage = "No links yet. A session is linked to an issue when it has a label such as #12, to a pull request when it opens one on its branch, and to the helpers and workflow runs it starts.";
export const lineageNote = "Linked within two steps of this session. An issue’s cost is its own and its pull requests’.";
