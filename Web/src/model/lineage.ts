// A session's Lineage pane (#2940), as LineageList has it on the window: the nodes the session is
// linked to, from lineage/walk (depth 2), each with its links and, for an issue or a PR, what
// lineage/cost says was banked on it.
import type { LineageCostRollup, LineageGraph, LineageLink, LineageNode, LineageResolved } from "../protocol/generated";
import { timeWords } from "./time";
import { costWords, nodeName, nodeUrl, spent } from "./value";

/** How far the pane walks: issue, its sessions, their PRs. */
export const lineageDepth = 2;

/** How many times, a second apart, the pane walks again while the daemon is still resolving titles (#3102). */
export const resolvingAsks = 20;
/** Under the graph while those walks go on (#3154). */
export const readingTitles = "Reading titles…";

export const sessionNode = (id: string): LineageNode => ({ kind: "session", ref: `session:${id}` });

const key = (n: LineageNode) => `${n.kind}\n${n.ref}`;
const same = (a: LineageNode, b: LineageNode) => a.kind === b.kind && a.ref === b.ref;

export interface LineageRow {
  node: LineageNode;
  /** "alexec/agents#12", "#12 Fix the flaky test" once resolved (#3158), or the session's title. */
  name: string;
  /** "alexec/agents#12", for a resolved node whose name is its title: the help shows it. */
  ref?: string | undefined;
  /** One line per link to it: "This session works on it · from the branch". */
  links: string[];
  /** "$4.00 · 12m working · merged", for an issue or a PR whose cost has come. */
  cost?: string | undefined;
  /** "open · bug, area:lineage", its state and labels from its connector (#3089). */
  resolved?: string | undefined;
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
  const parts = [same(link.to, of) ? `${name(link.from)} ${verb} it` : `${verb.charAt(0).toUpperCase()}${verb.slice(1)} ${same(link.to, session) && session.kind === "session" ? "this session" : name(link.to)}`];
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

/** "open · bug, area:lineage", from a node's resolved state and labels; undefined with neither. */
function resolvedLine(r: LineageResolved | undefined): string | undefined {
  if (!r) return undefined;
  const parts = [...r.state ? [r.state] : [], ...r.labels && r.labels.length > 0 ? [r.labels.join(", ")] : []];
  return parts.length === 0 ? undefined : parts.join(" · ");
}

/** A row for each node the walk reached, once, in the walk's order, the start itself left out. The start is
 * "This session" when it is one; any other start (#3087) has its own name. */
export function lineageRows(session: LineageNode, graph: LineageGraph, costs: ReadonlyMap<string, LineageCostRollup>,
  title: (n: LineageNode) => string | undefined): LineageRow[] {
  const seen = new Set<string>();
  const nodes = graph.nodes.filter((n) => !same(n, session) && !seen.has(key(n)) && (seen.add(key(n)), true));
  const name = names(session, graph, title);
  return nodes.map((n) => row(n, graph, costs, name, session));
}

/** The row for the start itself, a box of the graph: "This session", or the issue's or PR's name, its cost and
 * where it is (#3087). */
export function startRow(start: LineageNode, graph: LineageGraph, costs: ReadonlyMap<string, LineageCostRollup>,
  title: (n: LineageNode) => string | undefined): LineageRow {
  return { ...row(start, graph, costs, names(start, graph, title), start), links: [] };
}

function names(start: LineageNode, graph: LineageGraph, title: (n: LineageNode) => string | undefined) {
  return (n: LineageNode) => {
    if (same(n, start) && n.kind === "session") return "This session";
    const own = title(n);
    if (own !== undefined) return own;
    const resolved = graph.resolved?.[n.ref]?.title;
    return resolved ? `${refNumber(nodeName(n))} ${resolved}` : nodeName(n);
  };
}

/** "#12" from "alexec/agents#12"; a ref with no number, such as "ENG-4", as it is (#3158). */
function refNumber(ref: string): string {
  const hash = ref.lastIndexOf("#");
  return hash < 0 ? ref : ref.slice(hash);
}

function row(n: LineageNode, graph: LineageGraph, costs: ReadonlyMap<string, LineageCostRollup>, name: (n: LineageNode) => string,
  start: LineageNode): LineageRow {
  const rollup = costs.get(key(n));
  return {
    node: n, name: name(n),
    ref: graph.resolved?.[n.ref]?.title && name(n) !== nodeName(n) ? nodeName(n) : undefined,
    links: graph.links.filter((l) => same(l.from, n) || same(l.to, n)).map((l) => linkLine(l, n, start, name)),
    cost: rollup && costLine(rollup),
    resolved: resolvedLine(graph.resolved?.[n.ref]),
    session: n.kind === "session" ? n.ref.slice("session:".length) : undefined,
    url: lineageUrl(n),
  };
}

// The pane, and the Lineage page (#3087), as a graph of boxes and lines (#3019), as LineageLayout has it on
// the window: the start and the nodes it is linked to, a line for every link. The links are not a tree: a session
// that works on an issue and on the PR that fixes it makes a triangle.

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
  release: "Release",
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

/** The graph's tier for a kind, so it reads top to bottom: milestone, issue, session, PR,
 * release (#3023: what shipped it, last). */
function tier(kind: string): number {
  switch (kind) {
    case "milestone": case "workflow": return 0;
    case "issue": case "workflow-run": return 1;
    case "session": return 2;
    case "pr": return 3;
    case "release": return 4;
    default: return 5;
  }
}

/** The graph: a tier per kind, top to bottom, empty tiers left out, each tier in the order of the boxes it links
 * to above it, so fewer lines cross. Tiers are centred on the widest. Top to bottom, so that it fits the files
 * pane: a walk has few tiers and few boxes in each. */
export function lineageGraph(session: LineageNode, walked: LineageGraph, costs: ReadonlyMap<string, LineageCostRollup>,
  title: (n: LineageNode) => string | undefined): LineageGraphLayout {
  const rows = lineageRows(session, walked, costs, title);
  if (rows.length === 0) return { nodes: [], edges: [], width: 0, height: 0 };
  const all = [startRow(session, walked, costs, title), ...rows];
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
    here: same(r.node, session), detail: [kindWord(r.node.kind), ...r.cost ? [r.cost] : [], ...r.resolved ? [r.resolved] : []].join(" · "),
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

/** The Lineage page's note (#3087), for any start. */
export const lineagePageNote = "Linked within two steps. Click a box to start from it. An issue’s cost is its own and its pull requests’.";
/** The Lineage page with nothing to start from yet. */
export const noLineageHere = "No links from here yet. Start from another session, or type an issue’s, a pull request’s, a milestone’s or a release’s address.";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The start a person typed on the Lineage page (#3087), as LineageList.node(typed:) has it: a GitHub address of
 * an issue, a pull request, a milestone or a release; "owner/repo#12" (an issue, or the pull request of
 * typedPullRequest); "github:owner/repo#12"; or a session's id. Undefined for anything else. */
export function typedNode(text: string): LineageNode | undefined {
  text = text.trim();
  const id = text.startsWith("session:") ? text.slice("session:".length) : text;
  if (uuid.test(id)) return sessionNode(id.toUpperCase());
  let url: URL | undefined;
  try { url = /^https?:/i.test(text) ? new URL(text) : undefined; } catch { url = undefined; }
  if (url) {
    if (url.hostname.toLowerCase() !== "github.com" && url.hostname.toLowerCase() !== "www.github.com") return undefined;
    const parts = url.pathname.split("/").filter((p) => p !== "");
    if (parts.length < 4) return undefined;
    const repo = `${parts[0]}/${parts[1]}`;
    const number = /^\d+$/.test(parts[3]!);
    if (parts[2] === "issues" && number) return { kind: "issue", ref: `github:${repo}#${parts[3]}` };
    if (parts[2] === "pull" && number) return { kind: "pr", ref: `github:${repo}#${parts[3]}` };
    if (parts[2] === "milestone") return { kind: "milestone", ref: `github:${repo}/milestone/${parts[3]}` };
    if (parts[2] === "releases" && parts[3] === "tag" && parts.length >= 5) {
      return { kind: "release", ref: `github:${repo}/release/${parts.slice(4).join("/")}` };
    }
    return undefined;
  }
  const bare = text.startsWith("github:") ? text.slice("github:".length) : text;
  return /^[^/#\s]+\/[^/#\s]+#\d+$/.test(bare) ? { kind: "issue", ref: `github:${bare}` } : undefined;
}

/** The pull request that "owner/repo#12" may be (#3148), as LineageList.pullRequest(typed:) has it: GitHub gives
 * issues and pull requests one number space, so the bare form is either. The page walks it when the issue has no
 * links. Undefined for any other start. */
export function typedPullRequest(text: string): LineageNode | undefined {
  text = text.trim();
  if (text.includes("://")) return undefined;
  const node = typedNode(text);
  return node?.kind === "issue" ? { kind: "pr", ref: node.ref } : undefined;
}

/** Where the Lineage page's walk starts (#3087), and the starts before and after it, as a browser's Back and
 * Forward, as LineageHistory has it on the window. */
export interface LineageHistory<P> { places: readonly P[]; at: number }

/** How many starts a history keeps: the oldest go first. */
export const mostStarts = 50;

export const emptyHistory = <P>(): LineageHistory<P> => ({ places: [], at: -1 });

export const currentStart = <P>(h: LineageHistory<P>): P | undefined => h.places[h.at];

/** Start from a place: the starts after this one are dropped, as a browser drops them. */
export function goTo<P>(h: LineageHistory<P>, place: P, same: (a: P, b: P) => boolean): LineageHistory<P> {
  const now = currentStart(h);
  if (now !== undefined && same(now, place)) return h;
  const places = [...h.places.slice(0, h.at + 1), place].slice(-mostStarts);
  return { places, at: places.length - 1 };
}

export const goBack = <P>(h: LineageHistory<P>): LineageHistory<P> => h.at > 0 ? { ...h, at: h.at - 1 } : h;
export const goForward = <P>(h: LineageHistory<P>): LineageHistory<P> => h.at + 1 < h.places.length ? { ...h, at: h.at + 1 } : h;
