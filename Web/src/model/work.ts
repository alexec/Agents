// Work (#3119, spec 3100): every issue and pull request across the person's folders and forges, from
// forge/issues and forge/pulls on each machine, one row per ref, with what lineage knows about it
// (reports/nodes: cost, sessions, lead time) on top. Milestones and releases come from reports/nodes
// alone in v1. As WorkList has it on the window.
import type { ForgeCheck, ForgeItem, ForgeLabel, ForgeListError, LineageCostRollup, LineageLink, LineageNode, ReportNode } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { costWords, nodeName, spent } from "./value";
import { lineageUrl } from "./lineage";
import { timeWords } from "./time";

/** Work's lists, in the order of its tabs, by the lineage kind each holds. */
export type WorkKind = "issue" | "pr" | "milestone" | "release";
export const workKinds: readonly WorkKind[] = ["issue", "pr", "milestone", "release"];
export const workKindTitle: Record<WorkKind, string> = {
  issue: "Issues", pr: "Pull requests", milestone: "Milestones", release: "Releases",
};

/** Whether a kind's list is read from the forges (issues and PRs), not only from lineage. */
export const fromForge = (kind: WorkKind) => kind === "issue" || kind === "pr";

export type WorkState = "open" | "closed" | "merged" | "all";
export type WorkSort = "updated" | "newest" | "cost";
export const workSortTitle: Record<WorkSort, string> = { updated: "Last updated", newest: "Newest", cost: "Cost" };

/** One row of a list: the item as its forge says it, or as lineage resolved it, and its lineage. */
export interface WorkRow {
  node: LineageNode;
  title: string;
  /** open, closed or merged; empty when nothing says. */
  state: string;
  labels: ForgeLabel[];
  /** The ref's repo or tracker: github:alexec/Agents, linear. */
  repo: string;
  author?: string | undefined;
  assignees: string[];
  milestone?: string | undefined;
  /** Seconds since 1970, for sorting; 0 when not known. */
  updated: number;
  url?: string | undefined;
  /** The machine the forge read came from, to read the item again on. */
  host?: string | undefined;
  draft?: boolean | undefined;
  lineage?: ReportNode | undefined;
}

/** The repo or tracker of a ref: "github:alexec/Agents" of "github:alexec/Agents#12", "linear" of "linear:ENG-4". */
export function repoOf(ref: string): string {
  const scheme = /^([a-z][a-z0-9-]*):(.*)$/.exec(ref);
  if (!scheme) return ref;
  const [, forge, id = ""] = scheme;
  if (forge === "linear" || forge === "jira") return forge!;
  const cut = id.search(/[#!]|\/milestone\/|\/release\//);
  return cut < 0 ? ref : `${forge}:${id.slice(0, cut)}`;
}

/** "alexec/Agents" of "github:alexec/Agents", for a row's repo column. */
export const repoName = (repo: string) => repo.replace(/^[a-z][a-z0-9-]*:/, "");

/** An issue's or PR's number in its repo, for Newest; 0 for one without. */
export function refNumber(ref: string): number {
  const m = /[#!-](\d+)$/.exec(ref);
  return m ? Number(m[1]) : 0;
}

/** "#12", "!45", "ENG-4", "milestone 2" or "v0.14.0": a row's short name in its repo. */
export function shortRef(ref: string): string {
  const m = /([#!]\d+)$/.exec(ref) ?? /\/(milestone\/.+)$/.exec(ref) ?? /\/release\/(.+)$/.exec(ref);
  return m ? m[1]!.replace("milestone/", "milestone ") : nodeName({ kind: "", ref });
}

/** Whether a row's title says its short name already, as a milestone lineage could not resolve does. */
export const titleSaysRef = (row: Pick<WorkRow, "title" | "node">) => row.title.endsWith(shortRef(row.node.ref));

const unix = (at: number) => fromWireDate(at as never).getTime() / 1000;

/** A row from the forge's item, with its lineage when there is any. */
export function forgeRow(item: ForgeItem, host: string, lineage?: ReportNode): WorkRow {
  return {
    node: item.node, title: item.title, state: item.state, labels: item.labels, repo: repoOf(item.node.ref),
    author: item.author, assignees: item.assignees, milestone: item.milestone, updated: unix(item.updatedAt),
    url: item.url, host, draft: item.draft, lineage,
  };
}

/** A row lineage alone knows: a milestone, a release, or an item no forge listed. */
export function lineageRow(n: ReportNode): WorkRow {
  return {
    node: n.node, title: n.resolved?.title ?? nodeName(n.node), state: n.resolved?.state ?? (n.outcome === "merged" ? "merged" : ""),
    labels: (n.resolved?.labels ?? []).map((name) => ({ name })), repo: n.project ?? repoOf(n.node.ref), assignees: [],
    updated: unix(n.lastAt), url: lineageUrl(n.node), lineage: n,
  };
}

/** The items of every machine, one row per ref (the last updated copy), each with its lineage by ref. */
export function mergeForge(lists: readonly { host: string; items: readonly ForgeItem[] }[], lineage: readonly ReportNode[]): WorkRow[] {
  const byRef = new Map(lineage.map((n) => [n.node.ref, n]));
  const rows = new Map<string, WorkRow>();
  for (const { host, items } of lists) {
    for (const item of items) {
      const had = rows.get(item.node.ref);
      const row = forgeRow(item, host, byRef.get(item.node.ref));
      if (!had || row.updated > had.updated) rows.set(item.node.ref, row);
    }
  }
  return [...rows.values()];
}

/** What a list is narrowed to. Empty text, repo, label or assignee is any. */
export interface WorkFilter {
  state: WorkState;
  repo: string;
  label: string;
  assignee: string;
  text: string;
}

export const anyFilter: WorkFilter = { state: "open", repo: "", label: "", assignee: "", text: "" };

/** Whether a row is in the state asked: closed is closed without a merge when merged is its own choice. */
export function stateMatches(row: WorkRow, state: WorkState): boolean {
  if (state === "all") return true;
  if (state === "closed") return row.state === "closed" || (row.node.kind !== "pr" && row.state === "merged");
  return row.state === state;
}

export function filterRows(rows: readonly WorkRow[], f: WorkFilter): WorkRow[] {
  const words = f.text.trim().toLowerCase().split(/\s+/).filter(Boolean);
  return rows.filter((r) => {
    if (!stateMatches(r, f.state)) return false;
    if (f.repo && r.repo !== f.repo) return false;
    if (f.label && !r.labels.some((l) => l.name === f.label)) return false;
    if (f.assignee && !r.assignees.includes(f.assignee)) return false;
    if (words.length === 0) return true;
    const hay = `${r.title} ${r.node.ref} ${r.labels.map((l) => l.name).join(" ")}`.toLowerCase();
    return words.every((w) => hay.includes(w));
  });
}

/** The total cost in one figure, for sorting: the sum of its currencies. */
const costOf = (r: WorkRow) => Object.values(r.lineage?.cost.total.cost ?? {}).reduce((a, b) => a + b, 0);

export function sortRows(rows: readonly WorkRow[], sort: WorkSort): WorkRow[] {
  const out = [...rows];
  const tie = (a: WorkRow, b: WorkRow) => b.updated - a.updated || a.node.ref.localeCompare(b.node.ref);
  switch (sort) {
    case "updated": return out.sort(tie);
    // A forge numbers its items as they are made, so the highest number is the newest.
    case "newest": return out.sort((a, b) => refNumber(b.node.ref) - refNumber(a.node.ref) || tie(a, b));
    // With no lineage last; among those, the last updated first.
    case "cost": return out.sort((a, b) => costOf(b) - costOf(a) || Number(!!b.lineage) - Number(!!a.lineage) || tie(a, b));
  }
}

/** The choices of a filter's menu, from the rows read: their repos, labels and assignees, sorted. */
export function choices(rows: readonly WorkRow[]): { repos: string[]; labels: string[]; assignees: string[] } {
  const sorted = (s: Set<string>) => [...s].sort((a, b) => a.localeCompare(b));
  return {
    repos: sorted(new Set(rows.map((r) => r.repo))),
    labels: sorted(new Set(rows.flatMap((r) => r.labels.map((l) => l.name)))),
    assignees: sorted(new Set(rows.flatMap((r) => r.assignees))),
  };
}

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** Lead time in days and hours: "1d 4h", "3h 10m". */
export function leadWords(seconds: number): string {
  const days = Math.floor(seconds / 86_400);
  if (days === 0) return timeWords(seconds);
  const hours = Math.floor((seconds % 86_400) / 3600);
  return hours === 0 ? `${days}d` : `${days}d ${hours}h`;
}

/** What lineage knows about a row: "3 sessions · $4.10 · waste $0.60 · lead time 1d 4h"; undefined with none. */
export function lineageWords(n: ReportNode | undefined): string | undefined {
  if (!n) return undefined;
  const parts: string[] = [];
  if (n.sessions > 0) parts.push(plural(n.sessions, "session"));
  if (spent(n.cost.total)) parts.push(costWords(n.cost.total));
  if (spent(n.cost.waste)) parts.push(`waste ${costWords(n.cost.waste)}`);
  if (n.leadTimeSeconds !== undefined) parts.push(`lead time ${leadWords(n.leadTimeSeconds)}`);
  return parts.length === 0 ? undefined : parts.join(" · ");
}

/** A forge that could not be read: "GitHub on Studio: not connected". */
export function errorWords(e: ForgeListError, machine: string | undefined): string {
  const forge = forgeTitle[e.forge] ?? e.forge;
  return `${forge}${machine ? ` on ${machine}` : ""}: ${e.message}`;
}

export const forgeTitle: Record<string, string> = { github: "GitHub", gitlab: "GitLab", linear: "Linear", jira: "Jira" };

/** "Open on GitHub", by the ref's forge. */
export function openOnWords(ref: string): string {
  const forge = /^([a-z][a-z0-9-]*):/.exec(ref)?.[1] ?? "";
  return `Open on ${forgeTitle[forge] ?? "the forge"}`;
}

/** The text colour that reads on a label's colour (#2956): black on a light one, white on a dark one. */
export function labelInk(color: string | undefined): string | undefined {
  const m = /^#?([0-9a-f]{6})$/i.exec(color ?? "");
  if (!m) return undefined;
  const v = parseInt(m[1]!, 16);
  const [r, g, b] = [(v >> 16) & 255, (v >> 8) & 255, v & 255];
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6 ? "#1f2328" : "#ffffff";
}

/** A label's colour as CSS: "#d73a4a" of "d73a4a"; undefined when the forge gave none. */
export const labelColor = (color: string | undefined) => labelInk(color) ? `#${color!.replace(/^#/, "")}` : undefined;

export const noAgentYet = "No agent yet";
export const noWork = (kind: WorkKind) => kind === "milestone" ? "No milestones that an agent worked on yet."
  : kind === "release" ? "No releases that an agent worked on yet."
  : `No ${workKindTitle[kind].toLowerCase()} match.`;
export const lineageOnlyNote = "Lineage lists a milestone or a release once an agent works on one of its issues or pull requests.";
export const noForgeHere = "No machine reads issues and pull requests yet. Update Agents on a machine to see them.";

// The page of one issue, PR, milestone or release (#3119): its links grouped by relation, its checks,
// its review and its cost.

/** A relation's heading, from this node's side: a PR "Fixes" an issue, the issue is "Fixed by" the PR. */
const relWords: Record<string, [from: string, to: string]> = {
  "works-on": ["Works on", "Worked on by"], opens: ["Opens", "Opened by"], fixes: ["Fixes", "Fixed by"],
  started: ["Started", "Started by"], reviews: ["Reviews", "Reviewed by"], closes: ["Closes", "Closed by"],
  "part-of": ["Part of", "Parts"],
};
const relOrder = ["Fixes", "Fixed by", "Closes", "Closed by", "Part of", "Parts", "Opens", "Opened by", "Reviews", "Reviewed by",
  "Works on", "Worked on by", "Started", "Started by"];

export interface LinkGroup { title: string; rows: { node: LineageNode; ended: boolean }[] }

/** The node's links by relation, each other node once a group (an active link over an ended one), the
 * groups in a fixed order and any relation not known after them. */
export function linkGroups(here: LineageNode, links: readonly LineageLink[]): LinkGroup[] {
  const groups = new Map<string, Map<string, { node: LineageNode; ended: boolean }>>();
  for (const l of links) {
    const fromHere = l.from.kind === here.kind && l.from.ref === here.ref;
    const toHere = l.to.kind === here.kind && l.to.ref === here.ref;
    if (fromHere === toHere) continue;
    const words = relWords[l.rel] ?? [l.rel.replaceAll("-", " "), `${l.rel.replaceAll("-", " ")} by`];
    const title = fromHere ? words[0] : words[1];
    const other = fromHere ? l.to : l.from;
    const group = groups.get(title) ?? new Map();
    const had = group.get(other.ref);
    const ended = l.endedAt !== undefined;
    if (!had || (had.ended && !ended)) group.set(other.ref, { node: other, ended });
    groups.set(title, group);
  }
  const rank = (t: string) => { const i = relOrder.indexOf(t); return i < 0 ? relOrder.length : i; };
  return [...groups].sort(([a], [b]) => rank(a) - rank(b) || a.localeCompare(b))
    .map(([title, rows]) => ({ title, rows: [...rows.values()] }));
}

/** Whether a node has a page of its own in Work: an issue, a PR, a milestone or a release. */
export const hasPage = (n: LineageNode): n is LineageNode & { kind: WorkKind } => (workKinds as readonly string[]).includes(n.kind);

/** A PR's checks: "14 passing, 1 failing, 2 running"; undefined with none. */
export function checksWords(checks: readonly ForgeCheck[] | undefined, summary?: string): string | undefined {
  if (!checks || checks.length === 0) return summary && summary !== "none" ? `Checks ${summary}` : undefined;
  const count = (s: string) => checks.filter((c) => c.state === s).length;
  const parts = [["passing", count("passing")], ["failing", count("failing")], ["running", count("running")], ["skipped", count("skipped")]]
    .filter(([, n]) => (n as number) > 0).map(([w, n]) => `${n} ${w}`);
  return `Checks: ${parts.join(", ")}`;
}

const reviewTitle: Record<string, string> = {
  approved: "Approved", changes_requested: "Changes requested", review_required: "Review required",
};
export const reviewWords = (review: string | undefined) => review ? `Review: ${reviewTitle[review] ?? review.replaceAll("_", " ")}` : undefined;

/** The cost line of a page: "Own $1.20 · total $3.40 · waste $0.30 · 2 failed checks"; undefined with nothing banked. */
export function pageCostWords(r: LineageCostRollup): string | undefined {
  if (!spent(r.total) && r.failedChecks === 0) return undefined;
  const parts = [`Own ${costWords(r.own)}`, `total ${costWords(r.total)}`];
  if (spent(r.waste)) parts.push(`waste ${costWords(r.waste)}`);
  if (r.total.workingSeconds > 0) parts.push(`${timeWords(r.total.workingSeconds)} working`);
  if (r.failedChecks > 0) parts.push(plural(r.failedChecks, "failed check"));
  return parts.join(" · ");
}

/** The people line of a page: "by alexec · assigned to bob · milestone 0.14". */
export function peopleWords(item: Pick<ForgeItem, "author" | "assignees" | "milestone">): string {
  const parts = [...item.author ? [`by ${item.author}`] : [], ...item.assignees.length > 0 ? [`assigned to ${item.assignees.join(", ")}`] : [],
    ...item.milestone ? [`milestone ${item.milestone}`] : []];
  return parts.join(" · ");
}

export const noAgentOnIt = "No agent has worked on this yet.";
export const notReadHere = "No machine could read this from its forge.";
