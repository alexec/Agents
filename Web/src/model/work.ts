// Work (#3119, spec 3100): every issue and pull request across the person's folders and forges, from
// forge/issues and forge/pulls on each machine, one row per ref, with what lineage knows about it
// (reports/nodes: cost, sessions, lead time) on top. Milestones and releases come from reports/nodes
// alone in v1. As WorkList has it on the window.
import type {
  ForgeCheck, ForgeDone, ForgeItem, ForgeItemDetail, ForgeLabel, ForgeListError, ForgeListRequest, ForgeMergeMethod,
  LineageNode, ProjectBoard, ReportNode,
} from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { costWords, nodeName, spent } from "./value";
import { lineageUrl } from "./lineage";
import { timeWords } from "./time";
import { folderPathOf } from "./projectSettings";

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
  /** The tracker's own name for its step (a Jira status, #3260), shown in place of state. */
  status?: string | undefined;
  labels: ForgeLabel[];
  /** The ref's repo or tracker: github:alexec/Agents, linear:ENG (a Linear team, #3311), jira. */
  repo: string;
  author?: string | undefined;
  assignees: string[];
  milestone?: string | undefined;
  /** Seconds since 1970, for sorting; 0 when not known. */
  updated: number;
  url?: string | undefined;
  /** The machine the forge read came from, to read the item again on. */
  host?: string | undefined;
  /** The folder on host the forge read was for (#3283): its project is the row's. */
  folder?: string | undefined;
  draft?: boolean | undefined;
  lineage?: ReportNode | undefined;
}

/** The repo or tracker of a ref: "github:alexec/Agents" of "github:alexec/Agents#12", the team "linear:ENG" of
 * "linear:ENG-4" (#3311), "jira" of "jira:PROJ-1". */
export function repoOf(ref: string): string {
  const scheme = /^([a-z][a-z0-9-]*):(.*)$/.exec(ref);
  if (!scheme) return ref;
  const [, forge, id = ""] = scheme;
  if (forge === "linear") return /^([A-Z][A-Z0-9]*)-\d+$/.test(id) ? `linear:${id.replace(/-\d+$/, "")}` : "linear";
  if (forge === "jira") return forge;
  const cut = id.search(/[#!]|\/milestone\/|\/release\//);
  return cut < 0 ? ref : `${forge}:${id.slice(0, cut)}`;
}

/** "alexec/Agents" of "github:alexec/Agents", for a row's repo column; "Linear · ENG" of a Linear team (#3311); a tracker
 * (jira, #3260) by its own name; "Azure Boards · acme/web" of an Azure Boards project (#3815). */
export function repoName(repo: string): string {
  if (repo.startsWith("linear:")) return `Linear · ${repo.slice("linear:".length)}`;
  if (repo.startsWith("azureboards:")) return `Azure Boards · ${repo.slice("azureboards:".length)}`;
  return repo.includes(":") ? repo.replace(/^[a-z][a-z0-9-]*:/, "") : forgeTitle[repo] ?? repo;
}

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
    node: item.node, title: item.title, state: item.state, status: item.status, labels: item.labels, repo: repoOf(item.node.ref),
    author: item.author, assignees: item.assignees, milestone: item.milestone, updated: unix(item.updatedAt),
    url: item.url, host, folder: item.folder, draft: item.draft, lineage,
  };
}

/** A lineage node's repo: lineage says "linear" for every Linear issue, Work its team (#3311). */
const repoOfNode = (n: ReportNode) => n.repo && n.repo !== "linear" ? n.repo : repoOf(n.node.ref);

/** A row lineage alone knows: a milestone, a release, or an item no forge listed. */
export function lineageRow(n: ReportNode): WorkRow {
  return {
    node: n.node, title: n.resolved?.title ?? nodeName(n.node), state: n.resolved?.state ?? (n.outcome === "merged" ? "merged" : ""),
    labels: (n.resolved?.labels ?? []).map((name) => ({ name })), repo: repoOfNode(n), assignees: [],
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

/** A project in Work's Project filter (#3283): New Session's (newSessionProjects), a folder that names none a
 * project of its own, and its folders on each machine as workFolderKeys. As WorkList.Project on the window. */
export interface WorkProject { id: string; name: string; folders: ReadonlySet<string> }

/** A project and the repos and trackers its folders read. */
export interface WorkProjectRepos { project: WorkProject; repos: ReadonlySet<string> }

/** The Project filter's first choice (#3283), as Work lists everything. */
export const allProjects = "All projects";

/** An item's project on its page (#3283). */
export const projectWords = (name: string) => `Project ${name}`;

/** A folder as Work matches it to a forge item's (#3283): host|path, with no slash at the end. A folder's own
 * record names it by its file URL, a forge item by its path. */
export function workFolderKey(host: string, folder: string): string {
  return `${host}|${(folder.startsWith("file:") ? folderPathOf(folder) : folder).replace(/(.)\/+$/, "$1")}`;
}

/** Each project's repos and trackers (#3283): those of the items its folders read, on every machine, before the
 * copies of one ref are merged, so a repo two projects read is in both. The projects in their order, without
 * the ones whose folders read nothing. */
export function projectRepos(projects: readonly WorkProject[], lists: readonly { host: string; items: readonly ForgeItem[] }[]): WorkProjectRepos[] {
  const read = new Map<string, Set<string>>();
  for (const { host, items } of lists) {
    for (const item of items) {
      if (!item.folder) continue;
      const key = workFolderKey(host, item.folder);
      const repos = read.get(key) ?? new Set<string>();
      repos.add(repoOf(item.node.ref));
      read.set(key, repos);
    }
  }
  return projects.flatMap((project) => {
    const repos = new Set([...project.folders].flatMap((f) => [...read.get(f) ?? []]));
    return repos.size === 0 ? [] : [{ project, repos }];
  });
}

/** The project of the folder a forge item was read for on host (#3283), for its page; undefined when the folder is in
 * none of them. */
export function projectOfFolder(folder: string | undefined, host: string, projects: readonly WorkProject[]): WorkProject | undefined {
  if (!folder) return undefined;
  const key = workFolderKey(host, folder);
  return projects.find((p) => p.folders.has(key));
}

/** What a list is narrowed to. Empty text, project, repo, label, assignee or board is any. The board (a board's url,
 * #3282) is the machines' to narrow, as the state is: the rows read are the board's already. */
export interface WorkFilter {
  state: WorkState;
  /** A WorkProject's id (#3283): the rows of the repos its folders read. */
  project: string;
  repo: string;
  label: string;
  assignee: string;
  text: string;
  board: string;
}

export const anyFilter: WorkFilter = { state: "open", project: "", repo: "", label: "", assignee: "", text: "", board: "" };

/** A board's url on a request, when one is chosen (#3282); the request as it was with none. */
export function withBoard<T extends object>(request: T, board: string): T & { board?: string } {
  return board ? { ...request, board } : request;
}

/** forge/issues' and forge/pulls' request: the state, a page of 100, the board when one is chosen, the next page's cursor. */
export function forgeListRequest(state: string, board: string, cursor?: string): ForgeListRequest {
  return withBoard({ state, limit: 100, ...cursor ? { cursor } : {} }, board);
}

/** The boards of several machines (forge/boards, #3282) as one list: each once, by url, in the order first read,
 * with the name the first machine gave it. */
export function mergeBoards(lists: readonly (readonly ProjectBoard[])[]): ProjectBoard[] {
  const by = new Map<string, ProjectBoard>();
  for (const b of lists.flat()) if (!by.has(b.url)) by.set(b.url, b);
  return [...by.values()];
}

/** The Board menu's choices, by url: the boards read, and the chosen one when no machine lists it now. */
export function boardChoices(boards: readonly ProjectBoard[], chosen: string): string[] {
  const urls = boards.map((b) => b.url);
  return chosen && !urls.includes(chosen) ? [...urls, chosen] : urls;
}

/** A board's name in the menu, by its url; the url for one no machine lists now. */
export function boardName(boards: readonly ProjectBoard[], url: string): string {
  return boards.find((b) => b.url === url)?.name ?? url;
}

/** Whether a row is in the state asked: closed is closed without a merge when merged is its own choice. */
export function stateMatches(row: WorkRow, state: WorkState): boolean {
  if (state === "all") return true;
  if (state === "closed") return row.state === "closed" || (row.node.kind !== "pr" && row.state === "merged");
  return row.state === state;
}

/** The rows f asks for. projects is projectRepos: a project picked that read nothing has no rows. */
export function filterRows(rows: readonly WorkRow[], f: WorkFilter, projects: readonly WorkProjectRepos[] = []): WorkRow[] {
  const words = f.text.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const repos = f.project ? projects.find((p) => p.project.id === f.project)?.repos ?? new Set<string>() : undefined;
  return rows.filter((r) => {
    if (!stateMatches(r, f.state)) return false;
    if (repos && !repos.has(r.repo)) return false;
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

/** Where an item's page stands in the list it was opened from (#3257): the refs above and below it,
 * and its place, counted from 1. As WorkList.Neighbours on the window. */
export interface Neighbours { previous?: string | undefined; next?: string | undefined; position: number; count: number }

/** The item's neighbours in `rows`, the list as it is filtered and sorted; undefined when the ref is not in it. */
export function neighbours(ref: string, rows: readonly WorkRow[]): Neighbours | undefined {
  const i = rows.findIndex((r) => r.node.ref === ref);
  if (i < 0) return undefined;
  return { previous: rows[i - 1]?.node.ref, next: rows[i + 1]?.node.ref, position: i + 1, count: rows.length };
}

/** "3 of 42"; "3 of 42+" while the list has more pages to read. */
export function positionWords(n: Neighbours, more: boolean): string {
  return `${n.position} of ${n.count}${more ? "+" : ""}`;
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

export const forgeTitle: Record<string, string> = { github: "GitHub", gitlab: "GitLab", linear: "Linear", jira: "Jira",
  azureboards: "Azure Boards" };

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

// The page of one issue, PR, milestone or release (#3119): its checks and its review.

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

/** The people line of a page: "by alexec · assigned to bob · milestone 0.14". */
export function peopleWords(item: Pick<ForgeItem, "author" | "assignees" | "milestone">): string {
  const parts = [...item.author ? [`by ${item.author}`] : [], ...item.assignees.length > 0 ? [`assigned to ${item.assignees.join(", ")}`] : [],
    ...item.milestone ? [`milestone ${item.milestone}`] : []];
  return parts.join(" · ");
}

export const notReadHere = "No machine could read this from its forge.";

// Actions (#3130), as WorkList's on the Mac.

/** A merge method's button, as GitHub says it. */
export const mergeTitle: Record<ForgeMergeMethod, string> = { merge: "Create a merge commit", squash: "Squash and merge", rebase: "Rebase and merge" };

/** The merge button's words: its method, and "when checks pass" while some still run, as the merge then waits for them. */
export const mergeButton = (method: ForgeMergeMethod | undefined, waits: boolean) =>
  (method ? mergeTitle[method] : "Merge") + (waits ? " when checks pass" : "");

/** Whether a merge waits for checks still running: auto-merge, as the forge does it. */
export const mergeWaits = (d: ForgeItemDetail) => d.item.checks === "running" || (d.checks ?? []).some((c) => c.state === "running");

/** The failed checks, which Rerun runs again and whose logs a person reads. */
export const failedChecks = (d: ForgeItemDetail) => (d.checks ?? []).filter((c) => c.state === "failing");

/** What a write did, for the line under the actions. */
export function doneWords(method: string, done: ForgeDone, reopened = false, moved = false): string {
  switch (method) {
    case "forge/comment": return "Commented.";
    case "forge/label": return "Labels changed.";
    case "forge/merge": return done.auto ? "Auto-merge is on: it merges when its checks pass." : "Merged.";
    case "forge/approve": return "Approved.";
    case "forge/add-child": return "Child added.";
    case "forge/blocked-by": return "Blocked by changed.";
    case "forge/close": return moved ? "Status changed." : reopened ? "Reopened." : "Closed.";
    case "forge/rerun": return done.reran === undefined ? "Started again." : done.reran === 1 ? "1 run started again." : `${done.reran} runs started again.`;
    default: return "Done.";
  }
}

/** Close or Reopen, by the item's state. */
export const closeTitle = (state: string) => state === "open" ? "Close" : "Reopen";
