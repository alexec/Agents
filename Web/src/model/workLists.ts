// Each Work list's state (#3257), as the window's WorkListState: its filters, sort, the rows read and
// the cursors to the next pages, kept per kind for the tab's life. An item's page goes through the list
// it was opened from (Previous and Next, j and k), and Back finds the list as it was left.
import { signal, type Signal } from "@preact/signals";
import type { ForgeItem, ForgeListError, ProjectBoard, ReportNode, ReportNodesSort } from "../protocol/generated";
import type { Store } from "./store";
import { Capability } from "../protocol/capabilities.generated";
import { CallFailed } from "../wire/link";
import { describe } from "./errors";
import { hostAnswers } from "./capabilities";
import {
  anyFilter, filterRows, forgeListRequest, fromForge, lineageRow, mergeBoards, mergeForge, neighbours, projectRepos, sortRows,
  type Neighbours, type WorkFilter, type WorkKind, type WorkProject, type WorkProjectRepos, type WorkRow, type WorkSort, type WorkState,
} from "./work";

/** How many pages of reports/nodes a list reads for its lineage: at most 500 nodes. */
const lineagePages = 5;

/** A machine's page of a forge list, and the cursor to its next. */
export interface HostList { host: string; items: ForgeItem[]; cursor?: string | undefined; errors: ForgeListError[] }

export interface WorkListState {
  kind: WorkKind;
  filter: Signal<WorkFilter>;
  /** The person's projects (#3283), as the view last said them, for the Project filter. */
  projects: Signal<readonly WorkProject[]>;
  sort: Signal<WorkSort>;
  lists: Signal<HostList[] | null>;
  lineage: Signal<ReportNode[]>;
  lineageCursor: Signal<string | undefined>;
  problem: Signal<string | null>;
  more: Signal<boolean>;
  asked: Signal<number>;
  /** The row whose page was opened last, which the list scrolls to when it is shown again. */
  opened: Signal<string | undefined>;
  /** What the rows were read for; the list reads them again only when that changes. */
  read: string | undefined;
}

const lists = new Map<WorkKind, WorkListState>();

/** The page opened from its list (#3257), "kind ref"; a page opened from a link or an address is not it. */
export const fromList = signal<string | undefined>(undefined);
export const placeKey = (kind: WorkKind, ref: string) => `${kind} ${ref}`;

export function workList(kind: WorkKind): WorkListState {
  let l = lists.get(kind);
  if (!l) {
    l = {
      kind, filter: signal(anyFilter), projects: signal([]), sort: signal<WorkSort>("updated"), lists: signal(null), lineage: signal([]),
      lineageCursor: signal(undefined), problem: signal(null), more: signal(false), asked: signal(0), opened: signal(undefined),
      read: undefined,
    };
    lists.set(kind, l);
  }
  return l;
}

export const forgeState = (s: WorkState) => s === "open" ? "open" : s === "all" ? "all" : "closed";

/** An issue's or a PR's lineage is joined by ref, in any order; a milestone's or a release's list is lineage's own. */
export const nodesSort = (l: WorkListState): ReportNodesSort => !fromForge(l.kind) && l.sort.value === "cost" ? "cost" : "newest";

export const forgeHosts = (store: Store) => store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.forge1));

/** The machines that know boards (#3282): only they are asked for a board's list, as one that does not would list it all. */
export const boardHosts = (store: Store) => forgeHosts(store).filter((h) => store.has(h.id, Capability.forgeBoards1));

/** The machines a list is read from: with a board chosen, those that know boards. */
export const listHosts = (store: Store, board: string) => board ? boardHosts(store) : forgeHosts(store);

/** The boards of the machines' projects (forge/boards, #3282), for Issues' and Features' Board menu. */
export const boards = signal<ProjectBoard[]>([]);
let boardsRead: string | undefined;

/** Read the boards from each machine that knows them, unless they were read from those already; `again` reads them anyway. */
export async function loadBoards(store: Store, again = false): Promise<void> {
  const hosts = boardHosts(store);
  const mine = hosts.map((h) => h.id).join(",");
  if (boardsRead === mine && !again) return;
  boardsRead = mine;
  const got = await Promise.all(hosts.map((h) => store.link.call("forge/boards", {}, h.id).then((b) => b.boards, () => [])));
  if (boardsRead === mine) boards.value = mergeBoards(got);
}

/** Every row read, one per ref. */
export function allRows(l: WorkListState): WorkRow[] {
  return fromForge(l.kind) ? mergeForge(l.lists.value ?? [], l.lineage.value) : l.lineage.value.map(lineageRow);
}

/** Each project with the repos its folders read (#3283); none for milestones and releases, which lineage alone
 * lists, with no folder. */
export function listProjects(l: WorkListState): WorkProjectRepos[] {
  return fromForge(l.kind) ? projectRepos(l.projects.value, l.lists.value ?? []) : [];
}

/** The rows as the list shows them: filtered and sorted. Milestones and releases have no state in v1. */
export function shownRows(l: WorkListState): WorkRow[] {
  return sortRows(filterRows(allRows(l), fromForge(l.kind) ? l.filter.value : { ...l.filter.value, state: "all" }, listProjects(l)),
    l.sort.value);
}

export const hasMore = (l: WorkListState) => fromForge(l.kind) ? (l.lists.value ?? []).some((h) => h.cursor) : !!l.lineageCursor.value;

/** The lineage of a kind, at most `lineagePages` pages of it; none when the control plane does not list nodes. */
async function readLineage(store: Store, kind: WorkKind, sort: ReportNodesSort, cursor?: string): Promise<{ nodes: ReportNode[]; cursor?: string | undefined }> {
  const nodes: ReportNode[] = [];
  let next = cursor;
  for (let i = 0; i < lineagePages; i++) {
    const page = await store.link.call("reports/nodes", { kind, sort, limit: 100, ...next ? { cursor: next } : {} });
    nodes.push(...page.nodes);
    next = page.cursor;
    if (!next || !fromForge(kind)) break;
  }
  return { nodes, cursor: next };
}

/** What the list is read for: its state, board, sort, machines and Refresh. */
export function askKey(store: Store, l: WorkListState): string {
  const { state, board } = l.filter.value;
  return [forgeState(state), board, nodesSort(l), listHosts(store, board).map((h) => h.id).join(","), l.asked.value].join("|");
}

/** Read the list for what it is asked, unless it was read for that already. */
export async function loadList(store: Store, l: WorkListState): Promise<void> {
  const mine = askKey(store, l);
  if (l.read === mine && l.lists.peek() !== null) return;
  l.read = mine;
  const current = () => l.read === mine;
  const { kind } = l;
  const sort = nodesSort(l);
  const { state, board } = l.filter.peek();
  const hosts = listHosts(store, board);
  l.lists.value = null;
  l.lineage.value = [];
  l.problem.value = null;
  // Lineage first, so the rows come with their figures; a control plane that does not list nodes gives none.
  const known = await readLineage(store, kind, sort).catch((e: unknown) => {
    if (current() && !(e instanceof CallFailed && e.code === -32601) && !fromForge(kind)) l.problem.value = describe(e);
    return { nodes: [] as ReportNode[], cursor: undefined };
  });
  if (!current()) return;
  l.lineage.value = known.nodes;
  l.lineageCursor.value = known.cursor;
  if (!fromForge(kind)) { l.lists.value = []; return; }
  const method = kind === "issue" ? "forge/issues" : "forge/pulls";
  const read = await Promise.all(hosts.map(async (h): Promise<HostList> => {
    try {
      const got = await store.link.call(method, forgeListRequest(forgeState(state), board), h.id);
      return { host: h.id, items: got.items, cursor: got.cursor, errors: got.errors ?? [] };
    } catch (e) {
      return { host: h.id, items: [], errors: [{ forge: "", message: describe(e) }] };
    }
  }));
  if (current()) l.lists.value = read;
}

/** More: the next page of each machine's list, or of lineage's. */
export async function loadMore(store: Store, l: WorkListState): Promise<void> {
  l.more.value = true;
  try {
    if (fromForge(l.kind)) {
      const method = l.kind === "issue" ? "forge/issues" : "forge/pulls";
      const { state, board } = l.filter.peek();
      l.lists.value = await Promise.all((l.lists.peek() ?? []).map(async (h) => {
        if (!h.cursor) return h;
        const got = await store.link.call(method, forgeListRequest(forgeState(state), board, h.cursor), h.host);
        return { ...h, items: [...h.items, ...got.items], cursor: got.cursor, errors: got.errors ?? [] };
      }));
    } else if (l.lineageCursor.peek()) {
      const next = await readLineage(store, l.kind, nodesSort(l), l.lineageCursor.peek());
      l.lineage.value = [...l.lineage.peek(), ...next.nodes];
      l.lineageCursor.value = next.cursor;
    }
  } catch (e) {
    l.problem.value = describe(e);
  } finally {
    l.more.value = false;
  }
}

/** Previous and Next for an item's page opened from its list; undefined for one opened another way. */
export function pageNeighbours(kind: WorkKind, ref: string): Neighbours | undefined {
  if (fromList.value !== placeKey(kind, ref)) return undefined;
  return neighbours(ref, shownRows(workList(kind)));
}

/** The ref after `ref`, reading the next page first (as More does) when `ref` is the last row read. */
export async function nextAfter(store: Store, kind: WorkKind, ref: string): Promise<string | undefined> {
  const l = workList(kind);
  let next = neighbours(ref, shownRows(l))?.next;
  while (!next && hasMore(l) && !l.more.peek()) {
    const before = shownRows(l).length;
    await loadMore(store, l);
    next = neighbours(ref, shownRows(l))?.next;
    if (shownRows(l).length === before || l.problem.peek()) break;
  }
  return next;
}
