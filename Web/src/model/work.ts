// Work (#3119, spec 3100): every issue and pull request across the person's folders and forges, from
// forge/issues and forge/pulls on each machine, one row per ref, with what lineage knows about it
// (reports/nodes: cost, sessions, lead time) on top. Releases come from reports/nodes alone in v1. As
// WorkList has it on the window.
import type {
  ForgeCheck, ForgeComment, ForgeDone, ForgeEvent, ForgeItem, ForgeItemDetail, ForgeLabel, ForgeListError, ForgeListRequest, ForgeMergeMethod,
  LineageNode, ProjectBoard, ReportNode,
} from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { costWords, nodeName, spent } from "./value";
import { lineageUrl } from "./lineage";
import { timeWords } from "./time";
import { folderPathOf } from "./projectSettings";
import { ago } from "./connectorSetup";
import { legacyRef } from "../protocol/ref";

/** Work's lists, in the order of its tabs, by the lineage kind each holds. */
export type WorkKind = "issue" | "pr" | "release";
export const workKinds: readonly WorkKind[] = ["issue", "pr", "release"];
export const workKindTitle: Record<WorkKind, string> = {
  issue: "Issues", pr: "Pull requests", release: "Releases",
};

/** Whether a kind's list is read from the forges (issues and PRs), not only from lineage. */
export const fromForge = (kind: WorkKind) => kind === "issue" || kind === "pr";

export type WorkState = "open" | "closed" | "merged" | "all";
export type WorkSort = "updated" | "newest" | "cost";
export const workSortTitle: Record<WorkSort, string> = { updated: "Last updated", newest: "Newest", cost: "Cost" };

/** The sorts a list offers: a release's Newest is its version, the highest first (#4421), and it has no Last updated. */
export const workSorts = (kind: WorkKind): WorkSort[] => fromForge(kind) ? ["updated", "newest", "cost"] : ["newest", "cost"];

/** The sort a list opens with: a release's is Newest. */
export const defaultSort = (kind: WorkKind): WorkSort => kind === "release" ? "newest" : "updated";

/** One row of a list: the item as its forge says it, or as lineage resolved it, and its lineage. */
export interface WorkRow {
  node: LineageNode;
  title: string;
  /** open, closed or merged; empty when nothing says. */
  state: string;
  /** Why a closed issue closed (completed, not_planned or duplicate), where the forge says it (#4365). */
  stateReason?: string | undefined;
  /** The tracker's own name for its step (a Jira status, #3260), shown in place of state. */
  status?: string | undefined;
  labels: ForgeLabel[];
  /** The ref's repo or tracker: github:alexec/Agents, linear:ENG (a Linear team, #3311), jira. */
  repo: string;
  author?: string | undefined;
  /** The author's picture, a URL that only forge/image reads (#4363). */
  avatar?: string | undefined;
  assignees: string[];
  /** Seconds since 1970, for sorting; 0 when not known. */
  updated: number;
  /** When it opened, and when it closed or merged, in seconds since 1970, where the forge says them (#4373). */
  created?: number | undefined;
  closed?: number | undefined;
  url?: string | undefined;
  /** The machine the forge read came from, to read the item again on. */
  host?: string | undefined;
  /** The folder on host the forge read was for (#3283): its project is the row's. */
  folder?: string | undefined;
  draft?: boolean | undefined;
  /** The forge's comment count, its checks' summary and its review (a PR's); none from lineage alone. */
  comments?: number | undefined;
  checks?: string | undefined;
  review?: string | undefined;
  lineage?: ReportNode | undefined;
}

/** The repo or tracker of a ref: "github:alexec/Agents" of "github:alexec/Agents#12", the team "linear:ENG" of
 * "linear:ENG-4" (#3311), "jira" of "jira:PROJ-1". */
export function repoOf(ref: string): string {
  ref = legacyRef(ref);
  const scheme = /^([a-z][a-z0-9-]*):(.*)$/.exec(ref);
  if (!scheme) return ref;
  const [, forge, id = ""] = scheme;
  if (forge === "linear") return /^([A-Z][A-Z0-9]*)-\d+$/.test(id) ? `linear:${id.replace(/-\d+$/, "")}` : "linear";
  if (forge === "jira") return forge;
  const cut = id.search(/[#!]|\/release\//);
  return cut < 0 ? ref : `${forge}:${id.slice(0, cut)}`;
}

/** "alexec/Agents" of "github:alexec/Agents", for a row's repo column; "Linear · ENG" of a Linear team (#3311); a tracker
 * (jira, #3260) by its own name; "Azure Boards · acme/web" of an Azure Boards project (#3815). */
export function repoName(repo: string): string {
  repo = legacyRef(repo);
  if (repo.startsWith("linear:")) return `Linear · ${repo.slice("linear:".length)}`;
  if (repo.startsWith("azureboards:")) return `Azure Boards · ${repo.slice("azureboards:".length)}`;
  return repo.includes(":") ? repo.replace(/^[a-z][a-z0-9-]*:/, "") : forgeTitle[repo] ?? repo;
}

/** An issue's or PR's number in its repo, for Newest; 0 for one without. */
export function refNumber(ref: string): number {
  ref = legacyRef(ref);
  const m = /[#!-](\d+)$/.exec(ref);
  return m ? Number(m[1]) : 0;
}

/** "#12", "!45", "ENG-4" or "v0.14.0": a row's short name in its repo. */
export function shortRef(ref: string): string {
  ref = legacyRef(ref);
  const m = /([#!]\d+)$/.exec(ref) ?? /\/release\/(.+)$/.exec(ref);
  return m ? m[1]! : nodeName({ kind: "", ref });
}

/** A version tag's numbers: [0, 42, 0] of "v0.42.0"; undefined for a tag that is not a version. */
export function version(tag: string): number[] | undefined {
  const parts = (tag.startsWith("v") ? tag.slice(1) : tag).split(".");
  return parts.every((p) => /^\d+$/.test(p)) ? parts.map(Number) : undefined;
}

/** Whether tag a is a later version than b; a tag that is not a version is older than one that is. */
export function newer(a: string, b: string): boolean {
  const x = version(a);
  const y = version(b);
  if (!x) return false;
  if (!y) return true;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? -1) - (y[i] ?? -1);
    if (d !== 0) return d > 0;
  }
  return false;
}

/** Whether a row's title says its short name already, as a release lineage could not resolve does. */
export const titleSaysRef = (row: Pick<WorkRow, "title" | "node">) => row.title.endsWith(shortRef(row.node.ref));

const unix = (at: number) => fromWireDate(at as never).getTime() / 1000;

/** A row from the forge's item, with its lineage when there is any. */
export function forgeRow(item: ForgeItem, host: string, lineage?: ReportNode): WorkRow {
  return {
    node: item.node, title: item.title, state: item.state, stateReason: item.stateReason, status: item.status, labels: item.labels,
    repo: repoOf(item.node.ref), author: item.author, avatar: item.authorAvatar, assignees: item.assignees, updated: unix(item.updatedAt),
    created: item.createdAt === undefined ? undefined : unix(item.createdAt), closed: item.closedAt === undefined ? undefined : unix(item.closedAt),
    url: item.url, host, folder: item.folder, draft: item.draft, comments: item.comments, checks: item.checks, review: item.review, lineage,
  };
}

/** A lineage node's repo: lineage says "linear" for every Linear issue, Work its team (#3311). */
const repoOfNode = (n: ReportNode) => n.repo && n.repo !== "linear" ? legacyRef(n.repo) : repoOf(n.node.ref);

/** A row lineage alone knows: a release, named by its tag until the forge names it (#4426), or an item no forge listed. */
export function lineageRow(n: ReportNode): WorkRow {
  return {
    node: n.node, title: n.resolved?.title ?? (n.node.kind === "release" ? shortRef(n.node.ref) : nodeName(n.node)), state: n.resolved?.state ?? (n.outcome === "merged" ? "merged" : ""),
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
    // A forge numbers its items as they are made, so the highest number is the newest; a release's version says it (#4421).
    case "newest": return out.sort((a, b) => {
      if (a.node.kind === "release" && b.node.kind === "release") {
        const [x, y] = [shortRef(a.node.ref), shortRef(b.node.ref)];
        return newer(x, y) ? -1 : newer(y, x) ? 1 : tie(a, b);
      }
      return refNumber(b.node.ref) - refNumber(a.node.ref) || tie(a, b);
    });
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
  // A forge's message can name the forge already: "Forgejo: Get …".
  const message = forge && e.message.startsWith(`${forge}: `) ? e.message.slice(forge.length + 2) : e.message;
  return `${forge}${machine ? ` on ${machine}` : ""}: ${message}`;
}

export const forgeTitle: Record<string, string> = { github: "GitHub", gitlab: "GitLab", linear: "Linear", jira: "Jira",
  azureboards: "Azure Boards", forgejo: "Forgejo", bitbucket: "Bitbucket", azuredevops: "Azure DevOps" };

/** "Open on GitHub", by the ref's forge. */
export function openOnWords(ref: string): string {
  return `Open on ${forgeName(ref)}`;
}

/** "GitHub" of "github:alexec/Agents#12", by the ref's forge; "the forge" of one it does not know. */
export function forgeName(ref: string): string {
  const forge = /^([a-z][a-z0-9-]*):/.exec(legacyRef(ref))?.[1] ?? "";
  return forgeTitle[forge] ?? "the forge";
}

/** The forges whose pull requests have no labels (#3881): Bitbucket's API has none. */
export const forgesWithoutPRLabels = new Set(["bitbucket"]);

/** Whether the item's page offers Labels: not on a pull request of a forge whose pull requests have none (#3881). */
export function takesLabels(node: Pick<LineageNode, "kind" | "ref">): boolean {
  const forge = /^([a-z][a-z0-9-]*):/.exec(legacyRef(node.ref))?.[1] ?? "";
  return !(node.kind === "pr" && forgesWithoutPRLabels.has(forge));
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

export const lineageOnlyNote = "Lineage lists a release once an agent works on one of its issues or pull requests.";
export const noForgeHere = "No machine reads issues and pull requests yet. Update Agent Loops on a machine to see them.";

// The page of one issue, PR or release (#3119): its checks and its review.

/** Whether a node has a page of its own in Work: an issue, a PR or a release. */
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

// The shared parts of Work's look (#4392, specs/4328-work-look/parts.md): the state icon, the row's second
// line, the label chip's colours, the avatar's colour and the empty states, as Shared/UI's (#4391).

/** A row's state glyph (parts.md section 1). A closed issue is done, unless the forge says not planned (#4365). */
export type StateGlyph = "issue-open" | "issue-done" | "issue-dropped" | "pr-open" | "pr-draft" | "pr-merged" | "pr-closed";

export function stateGlyph(kind: string, state: string, draft?: boolean, notPlanned?: boolean): StateGlyph | undefined {
  if (kind === "pr") {
    if (state === "merged") return "pr-merged";
    if (state === "closed") return "pr-closed";
    return state === "open" ? draft ? "pr-draft" : "pr-open" : undefined;
  }
  if (kind !== "issue") return undefined;
  if (state === "open") return "issue-open";
  return state === "closed" ? notPlanned ? "issue-dropped" : "issue-done" : undefined;
}

/** What a screen reader says for a glyph: colour is never the only sign. */
export const stateGlyphWords: Record<StateGlyph, string> = {
  "issue-open": "Open issue", "issue-done": "Closed issue", "issue-dropped": "Closed issue, not planned",
  "pr-open": "Open pull request", "pr-draft": "Draft pull request", "pr-merged": "Merged pull request", "pr-closed": "Closed pull request",
};

/** "2 h", "5 min", "3 d", "now": an age for the phone's short line. */
export function shortAge(seconds: number): string {
  if (seconds < 60) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} h`;
  return `${Math.floor(seconds / 86_400)} d`;
}

/** The time a row's second line says, and its verb: an open item's opening, a closed or merged one's close, where the forge
 * says them (#4373); else the last update. Undefined when nothing says a time. */
function rowTime(row: WorkRow): { verb: string; at: number } | undefined {
  // Lineage's links to a release are at its tag's commit time (#4421).
  if (row.node.kind === "release") return row.updated > 0 ? { verb: "released", at: row.updated } : undefined;
  if (row.state === "open" && row.created !== undefined) return { verb: "opened", at: row.created };
  if ((row.state === "closed" || row.state === "merged") && row.closed !== undefined) return { verb: row.state, at: row.closed };
  return row.updated > 0 ? { verb: "updated", at: row.updated } : undefined;
}

/** A row's second line (parts.md section 2), wide and on a phone: "#12 · In Review · opened 2 hours ago by alexec ·
 * 2 sessions · $0.42" and "#12 · 2 h · alexec · $0.42"; closed, "#12 · closed 5 days ago", and "not planned" at the end
 * for one closed so (lists.md section 2, note 13). A forge that gives no opened or closed time says the last update's.
 * With no lineage the line ends after the author. */
export function rowLine(row: WorkRow, now: number): { wide: string; short: string } {
  const ref = titleSaysRef(row) ? [] : [shortRef(row.node.ref)];
  // A draft says so in grey after its number (lists.md section 2), as its grey glyph does.
  const status = [...row.draft && row.state === "open" ? ["Draft"] : [], ...row.status ? [row.status] : []];
  const time = rowTime(row);
  const age = time ? Math.max(0, now / 1000 - time.at) : undefined;
  // "closed 5 days ago by alexec" would name the closer: the author goes with the opening.
  const by = row.author && (!time || time.verb === "opened" || time.verb === "updated" || time.verb === "released") ? ` by ${row.author}` : "";
  const when = time ? [`${time.verb} ${ago(new Date(time.at * 1000), new Date(now))}${by}`] : row.author ? [`by ${row.author}`] : [];
  const figures = lineageWords(row.lineage);
  const cost = row.lineage && spent(row.lineage.cost.total) ? [costWords(row.lineage.cost.total)] : [];
  const reason = row.node.kind === "issue" && row.state === "closed" && row.stateReason === "not_planned" ? ["not planned"] : [];
  return {
    wide: [...ref, ...status, ...when, ...figures ? [figures] : [], ...reason].join(" · "),
    short: [...ref, ...status, ...age === undefined ? [] : [shortAge(age)], ...row.author ? [row.author] : [], ...cost, ...reason].join(" · "),
  };
}

/** A PR's checks as a glyph on the row: passing, failing or running; none for none. */
export function checksGlyph(checks: string | undefined): { mark: string; words: string; tone: string } | undefined {
  switch (checks) {
    case "passing": return { mark: "✓", words: "Checks passing", tone: "good" };
    case "failing": return { mark: "✗", words: "Checks failing", tone: "bad" };
    case "running": case "pending": return { mark: "●", words: "Checks running", tone: "running" };
    default: return undefined;
  }
}

/** A PR's review as the row's word: only the two that ask for something. */
export const rowReviewWords = (review: string | undefined) =>
  review === "approved" ? "Approved" : review === "changes_requested" ? "Changes requested" : undefined;

/** A scoped label's two parts, "feature" and "work" of "feature:work"; undefined for a plain one. */
export function labelScope(name: string): [string, string] | undefined {
  const at = name.indexOf(":");
  return at > 0 && at < name.length - 1 ? [name.slice(0, at + 1), name.slice(at + 1)] : undefined;
}

type RGB = [number, number, number];
const rgbOf = (hex: string): RGB => { const v = parseInt(hex.replace(/^#/, ""), 16); return [(v >> 16) & 255, (v >> 8) & 255, v & 255]; };
const hexOf = (c: RGB) => `#${c.map((x) => Math.round(Math.min(255, Math.max(0, x))).toString(16).padStart(2, "0")).join("")}`;
const mix = (a: RGB, b: RGB, t: number): RGB => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const luminance = (c: RGB) => {
  const [r, g, b] = c.map((x) => { const s = x / 255; return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4; }) as RGB;
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
/** WCAG's contrast of two colours, 1 to 21. */
export function contrast(a: RGB, b: RGB): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x) as [number, number];
  return (hi + 0.05) / (lo + 0.05);
}

/** The light and dark grounds a chip sits on: the Paper palette's raised colours. */
const grounds: Record<"light" | "dark", RGB> = { light: [255, 255, 255], dark: [38, 40, 44] };

/** A label chip's colours on a ground (parts.md section 3): the fill at 18 %, the border at 60 %, and the text the
 * colour darkened (light) or lightened (dark) until it has 4.5:1 to the fill. Undefined for a label with no colour. */
export function chipColours(color: string | undefined, scheme: "light" | "dark"): { fill: string; border: string; ink: string } | undefined {
  const css = labelColor(color);
  if (!css) return undefined;
  const c = rgbOf(css), ground = grounds[scheme];
  const fill = mix(ground, c, 0.18);
  const toward: RGB = scheme === "light" ? [0, 0, 0] : [255, 255, 255];
  let ink = c;
  for (let t = 0.05; contrast(ink, fill) < 4.5 && t <= 1; t += 0.05) ink = mix(c, toward, t);
  return { fill: hexOf(fill), border: hexOf(mix(ground, c, 0.6)), ink: hexOf(ink) };
}

/** An avatar's colour with no image (parts.md section 6), picked from the login so one person keeps one colour. */
export function avatarHue(login: string): number {
  let h = 0;
  for (const ch of login) h = (h * 31 + ch.codePointAt(0)!) % 360;
  return h;
}

/** Whether a filter other than State is set, so an empty list says "match" and offers Clear filters. */
export const filtered = (f: WorkFilter) => !!(f.project || f.repo || f.label || f.assignee || f.text.trim() || f.board);

/** The filters cleared, keeping the State. */
export const clearedFilter = (f: WorkFilter): WorkFilter => ({ ...anyFilter, state: f.state });

/** An empty list's words (parts.md section 7): with a filter, "No issues match"; with none, "No open issues" and
 * where they come from. */
export function emptyWords(kind: WorkKind, state: WorkState, filter: boolean, repos: readonly string[]): { title: string; line?: string } {
  if (kind === "release") return { title: filter ? "No releases match" : "No releases yet" };
  const things = workKindTitle[kind].toLowerCase();
  if (filter) return { title: `No ${things} match` };
  const word = state === "all" ? "" : `${state} `;
  const where = repos.length === 1 ? repoName(repos[0]!) : "your forges";
  return { title: `No ${word}${things}`, line: `${workKindTitle[kind]} on ${where} show here.` };
}

/** The filters that are set, as an empty list says them (lists.md section 5): "Label: bug · Assignee: alexec"; the
 * project's and the board's names when given. Undefined when nothing narrows. */
export function setFilters(f: WorkFilter, project?: string, board?: string): string | undefined {
  const text = f.text.trim();
  const parts = [
    ...text ? [`“${text}”`] : [],
    ...f.project ? [`Project: ${project ?? f.project}`] : [],
    ...f.repo ? [`Repo: ${repoName(f.repo)}`] : [],
    ...f.label ? [`Label: ${f.label}`] : [],
    ...f.assignee ? [`Assignee: ${f.assignee}`] : [],
    ...f.board ? [`Board: ${board ?? f.board}`] : [],
  ];
  return parts.length === 0 ? undefined : parts.join(" · ");
}

/** One item of a kind, or many: "1 issue", "128 issues", "50+ issues" while more pages are there (lists.md section 5). */
export function countWords(kind: WorkKind, n: number, more = false): string {
  const noun = workKindTitle[kind].toLowerCase();
  return `${n}${more ? "+" : ""} ${n === 1 && !more ? noun.slice(0, -1) : noun}`;
}

/** The footer while the next page loads: "Loading more… · 50 shown"; "Loading more… · 50 of 128 shown" with the forge's
 * total (#4396). */
export const loadingMore = (shown: number, total?: number) => `Loading more… · ${shown}${total === undefined ? "" : ` of ${total}`} shown`;

/** The end of the list: "128 issues", the forge's total where it gives one (#4396); with none, "50+ issues" while more
 * pages are there, else the rows read. */
export const endWords = (kind: WorkKind, shown: number, more: boolean, total?: number) =>
  total === undefined ? countWords(kind, shown, more) : countWords(kind, total);

/** The forge's total for a list as the person sees it, or undefined: only from one machine's read (two machines read the
 * same repos, so their counts overlap), and only while no filter narrows it here (the forge counts what it was asked: the
 * state and the board). */
export function listTotal(totals: readonly (number | undefined)[], f: WorkFilter): number | undefined {
  if (totals.length !== 1) return undefined;
  return filtered({ ...f, board: "" }) ? undefined : totals[0];
}

/** A page after the first that did not load: one line at the end, and Try again. */
export const couldNotLoadMore = "Could not load more.";

/** The middle of a list that read nothing: "Could not read issues", then what the forge said. */
export const couldNotRead = (kind: WorkKind) => `Could not read ${workKindTitle[kind].toLowerCase()}`;

/** Whether what a forge said is about its credential, so the error offers Settings ▸ Connectors too. */
export function credentialProblem(message: string): boolean {
  const m = message.toLowerCase();
  return ["401", "403", "bad credentials", "unauthorized", "not connected", "token", "sign in", "signed in"].some((w) => m.includes(w));
}

/** The filters and the sort in the address (lists.md section 4), "project=agents&label=bug&sort=newest", so a link or a
 * reload keeps them: only what is not the default. */
export function workQuery(f: WorkFilter, sort: WorkSort, kind: WorkKind = "issue"): string {
  const q = new URLSearchParams();
  if (f.text.trim()) q.set("q", f.text);
  if (f.project) q.set("project", f.project);
  if (f.state !== anyFilter.state) q.set("state", f.state);
  if (f.repo) q.set("repo", f.repo);
  if (f.label) q.set("label", f.label);
  if (f.assignee) q.set("assignee", f.assignee);
  if (f.board) q.set("board", f.board);
  if (sort !== defaultSort(kind)) q.set("sort", sort);
  return q.toString();
}

/** The filters and the sort an address says; what it leaves out is the default. A word it does not know is left out. */
export function parseWorkQuery(query: string, kind: WorkKind): { filter: WorkFilter; sort: WorkSort } {
  const q = new URLSearchParams(query);
  const state = q.get("state");
  const states: readonly string[] = kind === "pr" ? ["open", "merged", "closed", "all"] : ["open", "closed", "all"];
  const sort = q.get("sort");
  return {
    filter: {
      state: state && states.includes(state) ? state as WorkState : anyFilter.state,
      project: q.get("project") ?? "", repo: q.get("repo") ?? "", label: q.get("label") ?? "", assignee: q.get("assignee") ?? "",
      text: q.get("q") ?? "", board: kind === "issue" ? q.get("board") ?? "" : "",
    },
    sort: sort && workSorts(kind).includes(sort as WorkSort) ? sort as WorkSort : defaultSort(kind),
  };
}

export const connectForge = (kind: WorkKind) => `Connect a forge to see ${kind === "pr" ? "pull requests" : "issues"}`;

// The issue page in the Work look (#4402, specs/4328-work-look/issue.md), as the window's WorkItemPage (#4400).

/** The state line's words, wide and narrow: "alexec opened this 3 days ago · closed yesterday · 4 comments" and "alexec ·
 * 3 d · 4 comments". With no opened time from the forge (#4373), the last update's: "alexec opened this · updated 2 hours
 * ago". */
export function pageStateWords(p: {
  author?: string | undefined; state?: string | undefined; updated?: Date | undefined; created?: Date | undefined; closed?: Date | undefined;
  comments: number;
}, now: Date = new Date()): { wide: string; short: string } {
  const comments = p.comments > 0 ? [p.comments === 1 ? "1 comment" : `${p.comments} comments`] : [];
  const opened = p.created ? ` ${ago(p.created, now)}` : "";
  const closed = p.state === "closed" && p.closed ? [`closed ${ago(p.closed, now)}`] : [];
  const age = !p.created && p.updated ? ago(p.updated, now) : undefined;
  const short = p.created ?? p.updated;
  return {
    wide: [...p.author ? [`${p.author} opened this${opened}`] : [], ...closed,
      ...age ? [age === "just now" ? "updated just now" : `updated ${age}`] : [], ...comments].join(" · "),
    short: [...p.author ? [p.author] : [], ...short ? [shortAge(Math.max(0, (now.getTime() - short.getTime()) / 1000))] : [], ...comments].join(" · "),
  };
}

// An issue's timeline events (#4373), as WorkLook's on the window (#4397).

/** An event as one grey line: "alexec added the label bug", "alexec closed this in #4331". Undefined for a kind this
 * client does not know: it draws nothing. */
export function eventWords(e: ForgeEvent): string | undefined {
  const who = e.actor ?? "Someone";
  const source = e.source ? ` in ${shortRef(e.source.ref)}` : "";
  switch (e.kind) {
    case "labeled": return e.label ? `${who} added the label ${e.label.name}` : undefined;
    case "unlabeled": return e.label ? `${who} removed the label ${e.label.name}` : undefined;
    case "assigned": return !e.assignee ? undefined : e.assignee === e.actor ? `${who} self-assigned this` : `${who} assigned ${e.assignee}`;
    case "unassigned": return !e.assignee ? undefined : e.assignee === e.actor ? `${who} removed their assignment` : `${who} unassigned ${e.assignee}`;
    case "closed": return `${who} closed this${source}`;
    case "reopened": return `${who} reopened this`;
    case "referenced": return e.source ? `${who} mentioned this in ${shortRef(e.source.ref)}` : undefined;
    default: return undefined;
  }
}

export type TimelineEntry = { comment: ForgeComment; at: number } | { event: ForgeEvent; words: string; at: number };

/** The comments and the events in time order (#4373). While older comments are still to read (`older`), the events before
 * the first comment read wait with them, so the timeline never shows an event out of its place. An event no words say is
 * left out. */
export function timelineEntries(comments: readonly ForgeComment[], events: readonly ForgeEvent[] | undefined, older: boolean): TimelineEntry[] {
  const from = older && comments.length > 0 ? Math.min(...comments.map((c) => unix(c.at))) : undefined;
  const all: TimelineEntry[] = comments.map((c) => ({ comment: c, at: unix(c.at) }));
  for (const e of events ?? []) {
    const words = eventWords(e);
    const at = unix(e.at);
    if (words !== undefined && (from === undefined || at >= from)) all.push({ event: e, words, at });
  }
  // A stable sort: a comment and an event at one time keep the comment first.
  return all.map((x, i) => [x, i] as const).sort((a, b) => a[0].at - b[0].at || a[1] - b[1]).map(([x]) => x);
}

/** Whether the forge gave the item's own events with its close: the page then draws its close from them. */
export const eventsSayClose = (events: readonly ForgeEvent[] | undefined) => events?.some((e) => e.kind === "closed") ?? false;

/** "3/42" (and "3/42+" while more can load): where the page stands, on a 390 px page's bar. */
export function shortPositionWords(n: Neighbours, more: boolean): string {
  return `${n.position}/${n.count}${more ? "+" : ""}`;
}

/** The Lineage section's first line: "$0.42 · 1 session"; empty when it knows neither. */
export function lineageCountWords(cost: string | undefined, sessions: number): string {
  return [...cost ? [cost] : [], ...sessions === 0 ? [] : [sessions === 1 ? "1 session" : `${sessions} sessions`]].join(" · ");
}
