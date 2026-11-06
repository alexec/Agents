// Work ▸ Issues, Pull requests, Milestones and Releases (#3119, spec 3100), as the window's WorkView:
// every issue and pull request from forge/issues and forge/pulls on each machine, one row per ref, with
// what lineage knows (reports/nodes: sessions, cost, lead time) under its title; the milestones and
// releases lineage knows. A row opens its page.
import { effect, useSignal } from "@preact/signals";
import { Fragment } from "preact";
import { useEffect, useMemo } from "preact/hooks";
import type { ForgeItemDetail, ForgeLabel, LineageEstimate } from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { describe } from "../model/errors";
import { hostAnswers } from "../model/capabilities";
import {
  boardChoices, boardName, checksWords, choices, errorWords, fromForge, labelColor, labelInk, lineageOnlyNote,
  lineageWords, noAgentYet, noForgeHere, noWork, notReadHere, openOnWords, peopleWords, positionWords, repoName,
  reviewWords, shortRef, titleSaysRef, workKindTitle, workSortTitle, allProjects, projectOfFolder, projectWords, workFolderKey,
  type WorkFilter, type WorkKind, type WorkProject, type WorkRow, type WorkSort, type WorkState,
} from "../model/work";
import { newSessionProjects } from "../model/projects";
import { orderedFolders } from "./Sidebar";
import { lineageUrl } from "../model/lineage";
import { type PipelineStep, pipelineDepth, pipelineSteps } from "../model/pipeline";
import { nodeName } from "../model/value";
import { actualWords, estimateLine, estimateRangeWords, estimateSpentWords, showsEstimate } from "../model/estimate";
import { ago } from "../model/connectorSetup";
import { fromWireDate } from "../protocol/dates";
import { Markdown } from "../render/markdown";
import { forgeMarkdown } from "../model/forgeMarkdown";
import { ForgeTitle } from "../render/ForgeTitle";
import { WorkActions, WorkCommentBox } from "./WorkActions";
import { WorkPlan } from "./WorkPlan";
import { WorkDocs } from "./Docs";
import { hasPlan } from "../model/epicPlan";
import { go, replace, route } from "../route";
import {
  allRows, askKey, boardHosts, boards, forgeHosts, fromList, hasMore, listProjects, loadBoards, loadList, loadMore, nextAfter, pageNeighbours,
  placeKey, shownRows, workList,
} from "../model/workLists";

/** The person's projects (#3283), New Session's, for the Project filter and an item's page: each folder by the
 * machine Work's lists read it on. */
export function workProjects(store: Store): WorkProject[] {
  return newSessionProjects(orderedFolders(store.hosts.value, store.folders.value, store.macHostID.value)).map((p) => ({
    id: p.id, name: p.name, folders: new Set(p.folders.map((r) => workFolderKey(r.host.id, r.folder.folder.folder))),
  }));
}

/** What the projects are, as one string, so a list hears of a change and not of each render. */
const projectsKey = (projects: readonly WorkProject[]) => projects.map((p) => `${p.id} ${p.name} ${[...p.folders].join(",")}`).join(";");

// Back on a list, no page is opened from it yet: a pasted address of the last one opened has no Previous or Next.
effect(() => { if (route.value.nav === "work" && !route.value.item) fromList.value = undefined; });

export function WorkList({ store, kind }: { store: Store; kind: WorkKind }) {
  // The list's state lives for the tab (#3257), so an item's page can go through it and Back finds it as it was.
  const l = workList(kind);
  const { filter, sort, lists, problem, more } = l;
  const hosts = forgeHosts(store);
  const state = filter.value.state;
  const ask = askKey(store, l);
  useEffect(() => { void loadList(store, l); }, [kind, ask]);
  // The Board menu's choices (#3282), from the machines that know boards: Issues only.
  const boardKey = boardHosts(store).map((h) => h.id).join(",");
  useEffect(() => { if (kind === "issue") void loadBoards(store); }, [kind, boardKey]);
  const projects = workProjects(store);
  useEffect(() => { l.projects.value = projects; }, [projectsKey(projects)]);
  const offeredProjects = listProjects(l).map((p) => p.project);
  // Back from an item's page: the list at the row last opened.
  const shownOnce = lists.value !== null;
  useEffect(() => {
    const opened = l.opened.peek();
    if (shownOnce && opened) document.querySelector(`[data-ref="${CSS.escape(opened)}"]`)?.scrollIntoView({ block: "center" });
  }, [shownOnce]);

  const all = allRows(l);
  const offered = choices(all);
  const rows = shownRows(l);
  const errors = (lists.value ?? []).flatMap((h) => h.errors.map((e) => errorWords(e, hosts.length > 1 ? store.hosts.value.find((x) => x.id === h.host)?.name : undefined)));
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
        {(offeredProjects.length > 1 || filter.value.project) && (
          <Choice label="Project" any={allProjects} value={filter.value.project} options={offeredProjects.map((p) => p.id)}
            words={(id) => offeredProjects.find((p) => p.id === id)?.name ?? allProjects} onChange={(project) => set({ project })} />
        )}
        {kind === "issue" && (
          <Choice label="Board" any="All" value={filter.value.board} options={boardChoices(boards.value, filter.value.board)}
            words={(url) => boardName(boards.value, url)} onChange={(board) => set({ board })} />
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
        <button type="button" class="link" onClick={() => { l.asked.value++; if (kind === "issue") void loadBoards(store, true); }}>Refresh</button>
      </div>
      {problem.value && <p class="hint">{problem.value}</p>}
      {errors.map((e) => <p key={e} class="hint">{e}</p>)}
      {fromForge(kind) && hosts.length === 0 ? <p class="hint">{noForgeHere}</p>
        : lists.value === null ? <p class="hint">Loading…</p>
        : rows.length === 0 ? <p class="hint">{noWork(kind)}</p>
        : (
          <ul class="work-rows">
            {rows.map((r) => <WorkRowView key={r.node.ref} row={r} several={offered.repos.length > 1}
              open={() => { l.opened.value = r.node.ref; fromList.value = placeKey(kind, r.node.ref); go({ nav: "work", section: kind, item: r.node.ref }); }} />)}
          </ul>
        )}
      {hasMore(l) && <button type="button" class="link" disabled={more.value} onClick={() => void loadMore(store, l)}>{more.value ? "Loading…" : "More"}</button>}
      {!fromForge(kind) && <p class="quiet small">{lineageOnlyNote}</p>}
    </div>
  );
}

/** A filter's menu: Any (or `any`), then the choices. */
export function Choice({ label, value, options, words = (s) => s, any = label === "Repo" ? "All" : "Any", onChange }: {
  label: string; value: string; options: string[]; words?: (s: string) => string; any?: string; onChange: (v: string) => void;
}) {
  if (options.length === 0 && !value) return null;
  return (
    <label>{label} <select value={value} onChange={(e) => onChange((e.target as HTMLSelectElement).value)}>
      <option value="">{any}</option>
      {options.map((o) => <option key={o} value={o}>{words(o)}</option>)}
    </select></label>
  );
}

/** A label in its forge's colour (#2956). */
export function LabelChip({ label }: { label: ForgeLabel }) {
  const bg = labelColor(label.color);
  return <span class="work-label" style={bg ? { background: bg, color: labelInk(label.color), borderColor: bg } : undefined}>{label.name}</span>;
}

/** The state as a word in a pill: open, closed, merged, draft; or the tracker's own status (a Jira
 * status, #3260), in the colour of the state it is in. */
export function StatePill({ state, draft, status }: { state: string; draft?: boolean | undefined; status?: string | undefined }) {
  if (!state) return null;
  const word = draft && state === "open" ? "draft" : state;
  return <span class={`work-state ${word}`}>{status ?? word}</span>;
}

function WorkRowView({ row, several, open }: { row: WorkRow; several: boolean; open: () => void }) {
  const figures = lineageWords(row.lineage);
  return (
    <li data-ref={row.node.ref}>
      <button type="button" class="work-row" onClick={open}>
        <span class="work-row-head">
          {!titleSaysRef(row) && <span class="work-ref">{shortRef(row.node.ref)}</span>}
          <span class="work-title"><ForgeTitle text={row.title} /></span>
          <StatePill state={row.state} draft={row.draft} status={row.status} />
          {row.labels.map((l) => <LabelChip key={l.name} label={l} />)}
          {several && <span class="quiet small">{repoName(row.repo)}</span>}
        </span>
        <span class={`work-figures small${figures ? "" : " quiet"}`}>{figures ?? noAgentYet}</span>
      </button>
    </li>
  );
}

/** The page of one issue, PR, milestone or release (#3119): the item from its forge (forge/issue,
 * forge/pull) on the first machine that reads it. An issue's and a pull request's actions (#3130,
 * WorkActions) go to the machine that read it. */
export function WorkPage({ store, kind, ref }: { store: Store; kind: WorkKind; ref: string }) {
  const node = useMemo(() => ({ kind, ref }), [kind, ref]);
  const asked = useSignal(0);
  const detail = useSignal<{ host: string; got: ForgeItemDetail } | null>(null);
  const forgeProblem = useSignal<string | null>(null);
  const older = useSignal(false);
  const estimate = useSignal<LineageEstimate | null>(null);
  const pipeline = useSignal<PipelineStep[]>([]);
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
  // An issue's estimate (#3560), from the machine that keeps its links: an open one's, and a closed one's as it
  // was when its work started, against what it took (#3561).
  const isIssue = detail.value?.got.item.node.kind === "issue";
  const isOpen = detail.value?.got.item.state === "open";
  useEffect(() => {
    let current = true;
    estimate.value = null;
    if (!lineageHost || !isIssue) return;
    void store.link.call("lineage/estimate", { node }, lineageHost).then((r) => { if (current) estimate.value = r; }, () => {});
    return () => { current = false; };
  }, [kind, ref, lineageHost, isIssue, isOpen, asked.value]);
  const actual = estimate.value && !isOpen ? actualWords(estimate.value) : undefined;
  // The outer loop in reach (#3588): its releases, CI runs, deploys and health, and what it came from.
  useEffect(() => {
    let current = true;
    pipeline.value = [];
    if (!lineageHost || kind === "milestone") return;
    void store.link.call("lineage/walk", { node, depth: pipelineDepth }, lineageHost)
      .then((g) => { if (current) pipeline.value = pipelineSteps(node, g); }, () => {});
    return () => { current = false; };
  }, [kind, ref, lineageHost, asked.value]);

  // The item again after a write (#3130), from the machine that read it, keeping the page until it comes.
  const reread = async () => {
    const had = detail.value;
    if (!had) return;
    try {
      const got = await store.link.call(kind === "pr" ? "forge/pull" : "forge/issue", { node }, had.host);
      detail.value = { host: had.host, got };
    } catch (e) {
      forgeProblem.value = describe(e);
    }
  };
  const writes = detail.value !== null && store.has(detail.value.host, Capability.forgeWrite1);

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
  const title = item?.title ?? nodeName(node);
  const state = item?.state ?? "";
  const labels: ForgeLabel[] = item?.labels ?? [];
  const url = item?.url ?? lineageUrl(node);
  // The project the item was read for (#3283), when the person has more than one: with one, the page says nothing new.
  const projects = workProjects(store);
  const project = projects.length > 1 && detail.value ? projectOfFolder(item?.folder, detail.value.host, projects) : undefined;
  const checks = item?.node.kind === "pr" ? checksWords(detail.value?.got.checks, item.checks) : undefined;
  const review = item?.node.kind === "pr" ? reviewWords(item.review) : undefined;

  return (
    <article class="work-page">
      <div class="work-page-bar">
        <button type="button" title="Back" aria-label="Back" onClick={() => history.back()}>‹</button>
        <button type="button" title="Forward" aria-label="Forward" onClick={() => history.forward()}>›</button>
        <button type="button" class="link" onClick={() => go({ nav: "work", section: kind })}>All {workKindTitle[kind].toLowerCase()}</button>
        <button type="button" class="link" onClick={() => { asked.value++; }}>Refresh</button>
        <Stepper store={store} kind={kind} at={ref} />
      </div>
      <header class="work-page-head">
        <h2><span class="work-title"><ForgeTitle text={title} /></span> {!titleSaysRef({ title, node }) && <span class="work-ref">{shortRef(ref)}</span>}</h2>
        <div class="work-row-head">
          <StatePill state={state} draft={item?.draft} status={item?.status} />
          {labels.map((l) => <LabelChip key={l.name} label={l} />)}
        </div>
        <p class="quiet small">
          {[ref, ...item ? [peopleWords(item)] : [], ...project ? [projectWords(project.name)] : []].filter(Boolean).join(" · ")}
          {url && <> · <a href={url} target="_blank" rel="noopener noreferrer">{openOnWords(ref)}</a></>}
        </p>
        {estimate.value && isOpen && showsEstimate(estimate.value) && (
          <p class="quiet small work-estimate" title={estimateRangeWords(estimate.value)}>
            {[estimateLine(estimate.value), estimateSpentWords(estimate.value)].filter(Boolean).join(" · ")}</p>
        )}
        {actual && <p class="quiet small work-estimate">{actual}</p>}
        {pipeline.value.length > 0 && (
          <p class="small work-pipeline">{pipeline.value.map((s, i) => (
            <Fragment key={i}>{i > 0 && " · "}{s.url ? <a href={s.url} target="_blank" rel="noopener noreferrer">{s.words}</a> : <span class="quiet">{s.words}</span>}</Fragment>
          ))}</p>
        )}
        {(checks || review) && <p class="small">{[checks, review].filter(Boolean).join(" · ")}</p>}
        {writes && detail.value && <WorkActions store={store} host={detail.value.host} detail={detail.value.got} wrote={() => void reread()} />}
      </header>
      {forgeProblem.value && <p class="hint">{forgeProblem.value}</p>}
      {fromForge(kind) && !detail.value && !forgeProblem.value && <p class="hint">Loading…</p>}
      {detail.value && hasPlan(detail.value.got.item) && (
        <WorkPlan store={store} host={detail.value.host} lineageHost={lineageHost} detail={detail.value.got} asked={asked.value}
          estimates={estimate.value?.children ?? []}
          writes={writes} wrote={() => void reread()} />
      )}
      {detail.value && (
        <section class="work-body" aria-label="Description">
          {detail.value.got.body.trim() ? <Markdown text={forgeMarkdown(detail.value.got.body)} /> : <p class="quiet">No description.</p>}
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
              <Markdown text={forgeMarkdown(c.body)} />
            </div>
          ))}
        </section>
      )}
      {writes && detail.value && <WorkCommentBox store={store} host={detail.value.host} node={node} wrote={() => void reread()} />}
      {detail.value && (kind === "issue" || kind === "pr") && (
        <WorkDocs store={store} itemRef={ref} title={detail.value.got.item.title} body={detail.value.got.body} asked={asked.value} />
      )}
    </article>
  );
}

/** Previous and Next through the list the page was opened from (#3257), j and k, and where the page
 * stands in it. Each replaces the place, so Back goes to the list. None on a page opened from a link or an address. */
function Stepper({ store, kind, at }: { store: Store; kind: WorkKind; at: string }) {
  const n = pageNeighbours(kind, at);
  const l = workList(kind);
  const more = hasMore(l);
  const to = (ref: string | undefined) => {
    if (!ref) return;
    l.opened.value = ref;
    fromList.value = placeKey(kind, ref);
    replace({ nav: "work", section: kind, item: ref });
  };
  const next = async () => { to(await nextAfter(store, kind, at)); };
  useEffect(() => {
    if (!n) return;
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (e.metaKey || e.ctrlKey || e.altKey || target?.closest("input, textarea, select, [contenteditable=true]")) return;
      if (e.key === "j") { e.preventDefault(); void next(); }
      if (e.key === "k") { e.preventDefault(); to(n.previous); }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, [kind, at, n?.previous, n?.next]);
  if (!n) return null;
  return (
    <span class="work-stepper">
      <button type="button" title="Previous (k)" aria-label="Previous" disabled={!n.previous} onClick={() => to(n.previous)}>↑</button>
      <span class="quiet small">{positionWords(n, more)}</span>
      <button type="button" title="Next (j)" aria-label="Next" disabled={(!n.next && !more) || l.more.value} onClick={() => void next()}>
        {l.more.value ? "…" : "↓"}</button>
    </span>
  );
}
