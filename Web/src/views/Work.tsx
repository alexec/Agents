// Work ▸ Issues, Pull requests, Milestones and Releases (#3119, spec 3100), as the window's WorkView:
// every issue and pull request from forge/issues and forge/pulls on each machine, one row per ref, with
// what lineage knows (reports/nodes: sessions, cost, lead time) under its title; the milestones and
// releases lineage knows. A row opens its page.
import { useSignal } from "@preact/signals";
import { useEffect, useMemo } from "preact/hooks";
import type {
  ForgeItem, ForgeItemDetail, ForgeLabel, ForgeListError, LineageCostRollup, LineageLink, LineageNode, ReportNode, ReportNodesSort,
} from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { CallFailed } from "../wire/link";
import { describe } from "../model/errors";
import { hostAnswers } from "../model/capabilities";
import {
  anyFilter, checksWords, choices, errorWords, filterRows, fromForge, hasPage, labelColor, labelInk, linkGroups, lineageOnlyNote, lineageRow,
  lineageWords, mergeForge, noAgentOnIt, noAgentYet, noForgeHere, noWork, notReadHere, openOnWords, pageCostWords, peopleWords, repoName,
  reviewWords, shortRef, sortRows, titleSaysRef, workKindTitle, workSortTitle, type WorkFilter, type WorkKind, type WorkRow, type WorkSort, type WorkState,
} from "../model/work";
import { kindWord, lineageUrl, readingTitles, sessionHost } from "../model/lineage";
import { nodeName } from "../model/value";
import { ago } from "../model/connectorSetup";
import { fromWireDate } from "../protocol/dates";
import { Markdown } from "../render/markdown";
import { Graph, useLayout, useWalk } from "./Lineage";
import { go } from "../route";

/** How many pages of reports/nodes a list reads for its lineage: at most 500 nodes. */
const lineagePages = 5;

/** A machine's page of a forge list, and the cursor to its next. */
interface HostList { host: string; items: ForgeItem[]; cursor?: string | undefined; errors: ForgeListError[] }

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

const forgeState = (s: WorkState) => s === "open" ? "open" : s === "all" ? "all" : "closed";

export function WorkList({ store, kind }: { store: Store; kind: WorkKind }) {
  const filter = useSignal<WorkFilter>(anyFilter);
  const sort = useSignal<WorkSort>("updated");
  const lists = useSignal<HostList[] | null>(null);
  const lineage = useSignal<ReportNode[]>([]);
  const lineageCursor = useSignal<string | undefined>(undefined);
  const problem = useSignal<string | null>(null);
  const more = useSignal(false);
  const asked = useSignal(0);
  const hosts = store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.forge1));
  const hostKey = hosts.map((h) => h.id).join(",");
  const state = filter.value.state;
  // An issue's or a PR's lineage is joined by ref, in any order; a milestone's or a release's list is lineage's own.
  const nodesSort: ReportNodesSort = !fromForge(kind) && sort.value === "cost" ? "cost" : "newest";
  useEffect(() => {
    let current = true;
    lists.value = null;
    lineage.value = [];
    problem.value = null;
    void (async () => {
      // Lineage first, so the rows come with their figures; a control plane that does not list nodes gives none.
      const known = await readLineage(store, kind, nodesSort).catch((e: unknown) => {
        if (current && !(e instanceof CallFailed && e.code === -32601) && !fromForge(kind)) problem.value = describe(e);
        return { nodes: [] as ReportNode[], cursor: undefined };
      });
      if (!current) return;
      lineage.value = known.nodes;
      lineageCursor.value = known.cursor;
      if (!fromForge(kind)) { lists.value = []; return; }
      const method = kind === "issue" ? "forge/issues" : "forge/pulls";
      const read = await Promise.all(hosts.map(async (h): Promise<HostList> => {
        try {
          const got = await store.link.call(method, { state: forgeState(state), limit: 100 }, h.id);
          return { host: h.id, items: got.items, cursor: got.cursor, errors: got.errors ?? [] };
        } catch (e) {
          return { host: h.id, items: [], errors: [{ forge: "", message: describe(e) }] };
        }
      }));
      if (current) lists.value = read;
    })();
    return () => { current = false; };
  }, [kind, hostKey, forgeState(state), nodesSort, asked.value]);

  const loadMore = async () => {
    more.value = true;
    try {
      if (fromForge(kind)) {
        const method = kind === "issue" ? "forge/issues" : "forge/pulls";
        const read = await Promise.all((lists.value ?? []).map(async (l) => {
          if (!l.cursor) return l;
          const got = await store.link.call(method, { state: forgeState(state), limit: 100, cursor: l.cursor }, l.host);
          return { ...l, items: [...l.items, ...got.items], cursor: got.cursor, errors: got.errors ?? [] };
        }));
        lists.value = read;
      } else if (lineageCursor.value) {
        const next = await readLineage(store, kind, nodesSort, lineageCursor.value);
        lineage.value = [...lineage.value, ...next.nodes];
        lineageCursor.value = next.cursor;
      }
    } catch (e) {
      problem.value = describe(e);
    } finally {
      more.value = false;
    }
  };

  const all: WorkRow[] = fromForge(kind) ? mergeForge(lists.value ?? [], lineage.value) : lineage.value.map(lineageRow);
  const offered = choices(all);
  // Milestones and releases have no state in v1.
  const rows = sortRows(filterRows(all, fromForge(kind) ? filter.value : { ...filter.value, state: "all" }), sort.value);
  const errors = (lists.value ?? []).flatMap((l) => l.errors.map((e) => errorWords(e, hosts.length > 1 ? store.hosts.value.find((h) => h.id === l.host)?.name : undefined)));
  const hasMore = fromForge(kind) ? (lists.value ?? []).some((l) => l.cursor) : !!lineageCursor.value;
  const set = (patch: Partial<WorkFilter>) => { filter.value = { ...filter.value, ...patch }; };
  const states: WorkState[] = kind === "pr" ? ["open", "merged", "closed", "all"] : ["open", "closed", "all"];

  return (
    <div class="work-list">
      <div class="work-filters" role="group" aria-label="Filters">
        {fromForge(kind) && (
          <label>State <select value={state} onChange={(e) => set({ state: (e.target as HTMLSelectElement).value as WorkState })}>
            {states.map((s) => <option key={s} value={s}>{s === "all" ? "All" : s.charAt(0).toUpperCase() + s.slice(1)}</option>)}
          </select></label>
        )}
        <Choice label="Repo" value={filter.value.repo} options={offered.repos} words={repoName} onChange={(repo) => set({ repo })} />
        <Choice label="Label" value={filter.value.label} options={offered.labels} onChange={(label) => set({ label })} />
        {fromForge(kind) && <Choice label="Assignee" value={filter.value.assignee} options={offered.assignees} onChange={(assignee) => set({ assignee })} />}
        <label>Sort <select value={sort.value} onChange={(e) => { sort.value = (e.target as HTMLSelectElement).value as WorkSort; }}>
          {(Object.keys(workSortTitle) as WorkSort[]).filter((s) => fromForge(kind) || s !== "newest")
            .map((s) => <option key={s} value={s}>{workSortTitle[s]}</option>)}
        </select></label>
        <input type="search" placeholder="Filter" aria-label="Filter by words" value={filter.value.text}
          onInput={(e) => set({ text: (e.target as HTMLInputElement).value })} />
        <button type="button" class="link" onClick={() => { asked.value++; }}>Refresh</button>
      </div>
      {problem.value && <p class="hint">{problem.value}</p>}
      {errors.map((e) => <p key={e} class="hint">{e}</p>)}
      {fromForge(kind) && hosts.length === 0 ? <p class="hint">{noForgeHere}</p>
        : lists.value === null ? <p class="hint">Loading…</p>
        : rows.length === 0 ? <p class="hint">{noWork(kind)}</p>
        : (
          <ul class="work-rows">
            {rows.map((r) => <WorkRowView key={r.node.ref} row={r} several={offered.repos.length > 1}
              open={() => go({ nav: "work", section: kind, item: r.node.ref })} />)}
          </ul>
        )}
      {hasMore && <button type="button" class="link" disabled={more.value} onClick={() => void loadMore()}>{more.value ? "Loading…" : "More"}</button>}
      {!fromForge(kind) && <p class="quiet small">{lineageOnlyNote}</p>}
    </div>
  );
}

/** A filter's menu: Any, then the choices. */
function Choice({ label, value, options, words = (s) => s, onChange }: {
  label: string; value: string; options: string[]; words?: (s: string) => string; onChange: (v: string) => void;
}) {
  if (options.length === 0 && !value) return null;
  return (
    <label>{label} <select value={value} onChange={(e) => onChange((e.target as HTMLSelectElement).value)}>
      <option value="">{label === "Repo" ? "All" : "Any"}</option>
      {options.map((o) => <option key={o} value={o}>{words(o)}</option>)}
    </select></label>
  );
}

/** A label in its forge's colour (#2956). */
export function LabelChip({ label }: { label: ForgeLabel }) {
  const bg = labelColor(label.color);
  return <span class="work-label" style={bg ? { background: bg, color: labelInk(label.color), borderColor: bg } : undefined}>{label.name}</span>;
}

/** The state as a word in a pill: open, closed, merged, draft. */
export function StatePill({ state, draft }: { state: string; draft?: boolean | undefined }) {
  if (!state) return null;
  const word = draft && state === "open" ? "draft" : state;
  return <span class={`work-state ${word}`}>{word}</span>;
}

function WorkRowView({ row, several, open }: { row: WorkRow; several: boolean; open: () => void }) {
  const figures = lineageWords(row.lineage);
  return (
    <li>
      <button type="button" class="work-row" onClick={open}>
        <span class="work-row-head">
          {!titleSaysRef(row) && <span class="work-ref">{shortRef(row.node.ref)}</span>}
          <span class="work-title">{row.title}</span>
          <StatePill state={row.state} draft={row.draft} />
          {row.labels.map((l) => <LabelChip key={l.name} label={l} />)}
          {several && <span class="quiet small">{repoName(row.repo)}</span>}
        </span>
        <span class={`work-figures small${figures ? "" : " quiet"}`}>{figures ?? noAgentYet}</span>
      </button>
    </li>
  );
}

/** The page of one issue, PR, milestone or release (#3119): the item from its forge (forge/issue,
 * forge/pull) on the first machine that reads it, and what lineage knows about it on a machine that
 * keeps links: its cost, its links by relation, and the graph centred here. Read-only in this slice. */
export function WorkPage({ store, kind, ref }: { store: Store; kind: WorkKind; ref: string }) {
  const node = useMemo(() => ({ kind, ref }), [kind, ref]);
  const asked = useSignal(0);
  const detail = useSignal<{ host: string; got: ForgeItemDetail } | null>(null);
  const forgeProblem = useSignal<string | null>(null);
  const older = useSignal(false);
  const cost = useSignal<LineageCostRollup | null>(null);
  const forgeHosts = store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.forge1));
  const lineageHosts = store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.lineage1));
  // Lineage from the machine that read the forge, else this Mac, else the first that keeps links.
  const lineageHost = lineageHosts.find((h) => h.id === detail.value?.host)?.id
    ?? lineageHosts.find((h) => h.id === store.macHostID.value)?.id ?? lineageHosts[0]?.id;
  useEffect(() => {
    let current = true;
    detail.value = null;
    forgeProblem.value = null;
    if (!fromForge(kind)) return;
    void (async () => {
      let last: string | null = null;
      for (const h of forgeHosts) {
        try {
          const got = await store.link.call(kind === "pr" ? "forge/pull" : "forge/issue", { node }, h.id);
          if (current) detail.value = { host: h.id, got };
          return;
        } catch (e) {
          last = describe(e);
        }
      }
      if (current) forgeProblem.value = forgeHosts.length === 0 ? noForgeHere : last ?? notReadHere;
    })();
    return () => { current = false; };
  }, [kind, ref, forgeHosts.map((h) => h.id).join(","), asked.value]);
  useEffect(() => {
    let current = true;
    cost.value = null;
    if (!lineageHost) return;
    void store.link.call("lineage/cost", { node }, lineageHost).then((r) => { if (current) cost.value = r; }, () => {});
    return () => { current = false; };
  }, [kind, ref, lineageHost, asked.value]);
  // The walk holds the node's own links, and the titles of the nodes at their other ends.
  const { graph, costs, failed, reading } = useWalk(store, lineageHost, node, asked.value);
  const links: readonly LineageLink[] | null = failed.value ? [] : graph.value?.links ?? null;
  const layout = useLayout(store, lineageHost, node, graph.value, costs.value);

  const readOlder = async () => {
    const had = detail.value;
    if (!had?.got.cursor) return;
    older.value = true;
    try {
      const page = await store.link.call(kind === "pr" ? "forge/pull" : "forge/issue", { node, cursor: had.got.cursor }, had.host);
      const { cursor: _, ...rest } = had.got;
      const got: ForgeItemDetail = { ...rest, comments: [...page.comments, ...had.got.comments] };
      if (page.cursor) got.cursor = page.cursor;
      detail.value = { host: had.host, got };
    } catch (e) {
      forgeProblem.value = describe(e);
    } finally {
      older.value = false;
    }
  };

  const item = detail.value?.got.item;
  const resolved = graph.value?.resolved?.[ref];
  const title = item?.title ?? resolved?.title ?? nodeName(node);
  const state = item?.state ?? resolved?.state ?? "";
  const labels: ForgeLabel[] = item?.labels ?? (resolved?.labels ?? []).map((name) => ({ name }));
  const url = item?.url ?? lineageUrl(node);
  const groups = links ? linkGroups(node, links) : [];
  const costLine = cost.value ? pageCostWords(cost.value) : undefined;
  const none = links !== null && groups.length === 0;
  const name = (n: LineageNode) => n.kind === "session" ? sessionName(store, n) : graph.value?.resolved?.[n.ref]?.title ?? nodeName(n);
  const openNode = (n: LineageNode) => {
    if (n.kind === "session") {
      const id = n.ref.slice("session:".length);
      const host = sessionHost(store.agents.value, id);
      const chat = host ? store.agent(host, id) : undefined;
      return host && chat ? () => go({ host, folder: chat.worktree?.folder || chat.cwd, session: chat.id }) : undefined;
    }
    return hasPage(n) ? () => go({ nav: "work", section: n.kind, item: n.ref }) : undefined;
  };
  const checks = item?.node.kind === "pr" ? checksWords(detail.value?.got.checks, item.checks) : undefined;
  const review = item?.node.kind === "pr" ? reviewWords(item.review) : undefined;

  return (
    <article class="work-page">
      <div class="work-page-bar">
        <button type="button" title="Back" aria-label="Back" onClick={() => history.back()}>‹</button>
        <button type="button" title="Forward" aria-label="Forward" onClick={() => history.forward()}>›</button>
        <button type="button" class="link" onClick={() => go({ nav: "work", section: kind })}>All {workKindTitle[kind].toLowerCase()}</button>
        <button type="button" class="link" onClick={() => { asked.value++; }}>Refresh</button>
      </div>
      <header class="work-page-head">
        <h2><span class="work-title">{title}</span> {!titleSaysRef({ title, node }) && <span class="work-ref">{shortRef(ref)}</span>}</h2>
        <div class="work-row-head">
          <StatePill state={state} draft={item?.draft} />
          {labels.map((l) => <LabelChip key={l.name} label={l} />)}
        </div>
        <p class="quiet small">
          {[ref, ...item ? [peopleWords(item)] : []].filter(Boolean).join(" · ")}
          {url && <> · <a href={url} target="_blank" rel="noopener noreferrer">{openOnWords(ref)}</a></>}
        </p>
        {(checks || review) && <p class="small">{[checks, review].filter(Boolean).join(" · ")}</p>}
      </header>
      {forgeProblem.value && <p class="hint">{forgeProblem.value}</p>}
      {fromForge(kind) && !detail.value && !forgeProblem.value && <p class="hint">Loading…</p>}
      {detail.value && (
        <section class="work-body" aria-label="Description">
          {detail.value.got.body.trim() ? <Markdown text={detail.value.got.body} /> : <p class="quiet">No description.</p>}
        </section>
      )}
      {detail.value && (detail.value.got.comments.length > 0 || detail.value.got.cursor) && (
        <section class="work-comments" aria-label="Comments">
          <h3>Comments</h3>
          {detail.value.got.cursor && <button type="button" class="link" disabled={older.value} onClick={() => void readOlder()}>
            {older.value ? "Loading…" : "Older comments"}</button>}
          {detail.value.got.comments.map((c, i) => (
            <div key={`${c.at}-${i}`} class="work-comment">
              <p class="quiet small"><span class="strong">{c.author}</span>{c.bot ? " (bot)" : ""} · {ago(fromWireDate(c.at))}</p>
              <Markdown text={c.body} />
            </div>
          ))}
        </section>
      )}
      <section class="work-lineage" aria-label="Lineage">
        <h3>Lineage</h3>
        {!lineageHost ? <p class="hint">No machine keeps links yet. Update Agents on a machine to see them.</p>
          : links === null ? <p class="hint">Reading the links…</p>
          : none ? <p class="hint">{noAgentOnIt}</p>
          : (
            <>
              {costLine && <p><span class="quiet">Cost</span> {costLine}</p>}
              <dl class="work-links">
                {groups.map((g) => (
                  <div key={g.title}>
                    <dt>{g.title}</dt>
                    {g.rows.map((r) => {
                      const open = openNode(r.node);
                      const words = `${name(r.node)}${r.node.kind === "session" ? "" : ` (${kindWord(r.node.kind).toLowerCase()})`}${r.ended ? " · ended" : ""}`;
                      return <dd key={r.node.ref}>{open
                        ? <button type="button" class="link" onClick={open}>{words}{r.node.kind === "session" ? " ▸ chat" : " ▸"}</button>
                        : <span>{words}</span>}</dd>;
                    })}
                  </div>
                ))}
              </dl>
              {layout && layout.nodes.length > 0 && (
                <Graph layout={layout} verb={(row) => row.session ? "Show the chat" : "Open its page"}
                  show={(row) => row.node.kind === kind && row.node.ref === ref ? undefined : openNode(row.node)} />
              )}
              {reading.value && <p class="quiet small">{readingTitles}</p>}
            </>
          )}
      </section>
    </article>
  );
}

const sessionName = (store: Store, n: LineageNode) => {
  const id = n.ref.slice("session:".length);
  const host = sessionHost(store.agents.value, id);
  return (host ? store.agent(host, id)?.title : undefined) ?? "A session";
};
