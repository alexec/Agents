// A session's Lineage pane (#2940), as LineageList has it on the window: the nodes the session is
// linked to, from lineage/walk (depth 2), in groups by kind, each with its links and, for an issue
// or a PR, what lineage/cost says was banked on it.
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

export interface LineageGroup { title: string; rows: LineageRow[] }

const kinds: [string, string][] = [
  ["issue", "Issues"], ["pr", "Pull Requests"], ["session", "Sessions"], ["workflow-run", "Workflow Runs"],
  ["milestone", "Milestones"],
];

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

/** The groups, the session itself left out. `title` names a session node by its title when this page has it. */
export function lineageGroups(session: LineageNode, graph: LineageGraph, costs: ReadonlyMap<string, LineageCostRollup>,
  title: (n: LineageNode) => string | undefined): LineageGroup[] {
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
  const groups = kinds.map(([kind, title]) => ({ title, rows: rows.filter((r) => r.node.kind === kind) })).filter((g) => g.rows.length > 0);
  const rest = rows.filter((r) => !kinds.some(([kind]) => kind === r.node.kind));
  if (rest.length > 0) groups.push({ title: "Other", rows: rest });
  return groups;
}

export const costKey = key;

export const noLineage = "No links yet. A session is linked to an issue when it has a label such as #12, to a pull request when it opens one on its branch, and to the helpers and workflow runs it starts.";
export const lineageNote = "Linked within two steps of this session. An issue’s cost is its own and its pull requests’.";
