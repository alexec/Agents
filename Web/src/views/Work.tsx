// Work ▸ Issues, Pull requests and Releases (#3119, spec 3100), as the window's WorkView: every issue
// and pull request from forge/issues and forge/pulls on each machine, one row per ref, with what
// lineage knows (reports/nodes: sessions, cost, lead time) under its title; the releases lineage
// knows. A row opens its page.
import { effect, useSignal } from "@preact/signals";
import { Fragment, type ComponentChildren } from "preact";
import { useEffect, useMemo, useRef } from "preact/hooks";
import type { ForgeComment, ForgeItemDetail, ForgeLabel, LineageEstimate } from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { describe } from "../model/errors";
import { hostAnswers } from "../model/capabilities";
import {
  boardChoices, boardName, checksGlyph, checksWords, choices, clearedFilter, connectForge, couldNotLoadMore, couldNotRead, countWords,
  credentialProblem, emptyWords, errorWords, filtered, fromForge, loadingMore, parseWorkQuery, setFilters, workQuery,
  lineageOnlyNote, noForgeHere, notReadHere, openOnWords, positionWords, repoName, repoOf, rowLine, rowReviewWords,
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
import { type ForgeImages, Markdown } from "../render/markdown";
import { bytesOf } from "../model/pageImage";
import { forgeMarkdown } from "../model/forgeMarkdown";
import { ForgeTitle } from "../render/ForgeTitle";
import { Avatar, Avatars, EmptyState, ErrorStrip, FilterMenu, LabelChip, PlaceholderRows, RefreshButton, StateIcon, type MenuChoice } from "./WorkParts";
import { WorkActions, WorkCommentBox } from "./WorkActions";
import { WorkPlan } from "./WorkPlan";
import { WorkDocs } from "./Docs";
import { hasPlan } from "../model/epicPlan";
import { go, replace, route, routeHash } from "../route";
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
  // The filters and the sort are in the address too (lists.md section 4), so a link or a reload keeps them. An address
  // that says none (the section's link, All issues) keeps the tab's, and the address then says them.
  const query = route.value.query;
  useEffect(() => {
    if (query === undefined) return;
    const said = parseWorkQuery(query, kind);
    if (workQuery(said.filter, said.sort) !== workQuery(filter.peek(), sort.peek())) { filter.value = said.filter; sort.value = said.sort; }
  }, [kind, query]);
  const asked = workQuery(filter.value, sort.value);
  useEffect(() => {
    const now = workQuery(filter.peek(), sort.peek());
    if ((route.peek().query ?? "") !== now) replace({ nav: "work", section: kind, ...now ? { query: now } : {} });
  }, [asked]);
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
  const rowsAt = useRef<HTMLUListElement>(null);
  const end = useRef<HTMLDivElement>(null);
  // Back from an item's page: the list at the row last opened, selected.
  const shownOnce = lists.value !== null;
  useEffect(() => {
    const opened = l.opened.peek();
    const row = shownOnce && opened ? document.querySelector<HTMLElement>(`[data-ref="${CSS.escape(opened)}"] a`) : null;
    row?.scrollIntoView({ block: "center" });
    row?.focus({ preventScroll: true });
  }, [shownOnce]);
  // ↑ and ↓ move the selection, which is the focus (lists.md section 4); Enter opens the row, as a link does. From the
  // search field, ↓ goes to the first row.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey || (e.key !== "ArrowDown" && e.key !== "ArrowUp")) return;
      const target = e.target as HTMLElement | null;
      const links = [...rowsAt.current?.querySelectorAll<HTMLAnchorElement>("a.work-row") ?? []];
      if (links.length === 0) return;
      const at = links.indexOf(target?.closest<HTMLAnchorElement>("a.work-row") as HTMLAnchorElement);
      const fromSearch = target?.matches(".work-filters input[type=search]") && e.key === "ArrowDown";
      if (at < 0 && !fromSearch && target !== document.body) return;
      e.preventDefault();
      const next = links[at < 0 ? 0 : Math.max(0, Math.min(links.length - 1, at + (e.key === "ArrowDown" ? 1 : -1)))];
      next?.focus({ preventScroll: true });
      next?.scrollIntoView({ block: "nearest" });
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);

  const all = allRows(l);
  const offered = choices(all);
  const rows = shownRows(l);
  const errors = (lists.value ?? []).flatMap((h) => h.errors.map((e) => errorWords(e, hosts.length > 1 ? store.hosts.value.find((x) => x.id === h.host)?.name : undefined)));
  const set = (patch: Partial<WorkFilter>) => { filter.value = { ...filter.value, ...patch }; };
  const states: WorkState[] = kind === "pr" ? ["open", "merged", "closed", "all"] : ["open", "closed", "all"];

  const filter_ = filter.value;
  const pick = (label: string) => set({ label });
  const stateChoices: MenuChoice[] = states.map((s) => ({ value: s, words: s === "all" ? "All" : s.charAt(0).toUpperCase() + s.slice(1) }));
  const sortChoices: MenuChoice[] = (Object.keys(workSortTitle) as WorkSort[]).filter((s) => fromForge(kind) || s !== "newest")
    .map((s) => ({ value: s, words: workSortTitle[s] }));
  const refresh = () => { l.asked.value++; if (kind === "issue") void loadBoards(store, true); };
  const firstRead = lists.value === null || (l.loading.value && rows.length === 0);
  const problems = [...problem.value ? [problem.value] : [], ...errors];
  const stale = new Set((lists.value ?? []).flatMap((h) => h.stale ?? []));
  const narrowed = filtered(filter_);
  const empty = emptyWords(kind, state, narrowed, offered.repos);
  const things = kind === "pr" ? "pull requests" : workKindTitle[kind].toLowerCase();
  const clear = () => { filter.value = clearedFilter(filter_); };
  const connectors = () => go({ nav: "settings", section: "mcp" });

  // The next page loads when the end of the list shows (lists.md section 4), and again while it still shows; a page that
  // failed waits for Try again.
  const further = hasMore(l);
  const failed = l.moreFailed.value;
  const shown = !(fromForge(kind) && hosts.length === 0) && !firstRead && (rows.length > 0 || further);
  useEffect(() => {
    const at = end.current;
    if (!at || !shown || !further || failed || more.value || typeof IntersectionObserver === "undefined") return;
    const seen = new IntersectionObserver((e) => { if (e.some((x) => x.isIntersecting)) void loadMore(store, l); });
    seen.observe(at);
    return () => seen.disconnect();
  }, [shown, further, failed, more.value, rows.length]);

  return (
    <div class="work-list">
      <div class="work-filters" role="group" aria-label="Filters">
        <input type="search" placeholder={`Filter ${things}`} aria-label="Filter by words" value={filter_.text}
          onInput={(e) => set({ text: (e.target as HTMLInputElement).value })} />
        {/* The order of lists.md section 1: Project, State, Repo, Label, Assignee, Board, Clear, then Sort at the end. */}
        <div class="work-menus">
          {(offeredProjects.length > 1 || filter_.project) && (
            <Choice label="Project" any={allProjects} value={filter_.project} options={offeredProjects.map((p) => p.id)}
              words={(id) => offeredProjects.find((p) => p.id === id)?.name ?? allProjects} onChange={(project) => set({ project })} />
          )}
          {fromForge(kind) && <FilterMenu label="State" always value={state} choices={stateChoices} onPick={(v) => set({ state: v as WorkState })} />}
          {(offered.repos.length > 1 || filter_.repo) && (
            <Choice label="Repo" value={filter_.repo} options={offered.repos} words={repoName} onChange={(repo) => set({ repo })} />
          )}
          <Choice label="Label" value={filter_.label} options={offered.labels} onChange={(label) => set({ label })} />
          {fromForge(kind) && <Choice label="Assignee" value={filter_.assignee} options={offered.assignees} onChange={(assignee) => set({ assignee })} />}
          {kind === "issue" && (
            <Choice label="Board" any="All boards" value={filter_.board} options={boardChoices(boards.value, filter_.board)}
              words={(url) => boardName(boards.value, url)} onChange={(board) => set({ board })} />
          )}
          {narrowed && (
            <button type="button" class="work-menu-button work-clear" title="Clear the filters but State" onClick={clear}>
              <span aria-hidden="true">✕</span>Clear</button>
          )}
          <span class="work-sort">
            <FilterMenu label="Sort" standard="updated" value={sort.value} choices={sortChoices} onPick={(v) => { sort.value = v as WorkSort; }} />
          </span>
        </div>
        <RefreshButton busy={l.loading.value} onClick={refresh} />
      </div>
      {fromForge(kind) && hosts.length === 0
        ? <EmptyState kind={kind} title={connectForge(kind)} line={noForgeHere} action={{ words: "Settings ▸ Connectors", run: connectors }} />
        : firstRead ? <PlaceholderRows />
        : rows.length === 0 && !further && problems.length > 0
          ? <ErrorStrip lines={problems} retry={refresh} middle title={couldNotRead(kind)}
              also={problems.some(credentialProblem) ? { words: "Settings ▸ Connectors", run: connectors } : undefined} />
        : (
          <>
            <ErrorStrip lines={problems} retry={refresh} />
            {rows.length === 0
              ? <EmptyState kind={kind} title={empty.title}
                  line={narrowed ? setFilters(filter_, offeredProjects.find((p) => p.id === filter_.project)?.name, filter_.board ? boardName(boards.value, filter_.board) : undefined) : empty.line}
                  action={narrowed ? { words: "Clear filters", run: clear } : undefined} />
              : (
                <ul class="work-rows work-item-rows" ref={rowsAt}>
                  {rows.map((r) => <WorkRowView key={r.node.ref} row={r} several={offered.repos.length > 1} dim={stale.has(r.node.ref)} pick={pick}
                    open={() => { l.opened.value = r.node.ref; fromList.value = placeKey(kind, r.node.ref); go({ nav: "work", section: kind, item: r.node.ref }); }} />)}
                </ul>
              )}
          </>
        )}
      {shown && (
        <div class="work-list-end quiet small" ref={end} aria-live="polite">
          {more.value ? <><span class="work-spinner" aria-hidden="true" />{loadingMore(rows.length)}</>
            : failed ? <><span title={failed}>{couldNotLoadMore}</span><button type="button" onClick={() => void loadMore(store, l)}>Try again</button></>
            : further ? <><button type="button" onClick={() => void loadMore(store, l)}>Load more</button><span>{countWords(kind, rows.length, true)}</span></>
            : <span>{countWords(kind, rows.length)}</span>}
        </div>
      )}
      {!fromForge(kind) && <p class="quiet small">{lineageOnlyNote}</p>}
    </div>
  );
}

/** A filter's menu (#4392): Any (or `any`), then the choices, as a button that opens a list. */
export function Choice({ label, value, options, words = (s) => s, any = label === "Repo" ? "All" : "Any", onChange }: {
  label: string; value: string; options: string[]; words?: (s: string) => string; any?: string; onChange: (v: string) => void;
}) {
  if (options.length === 0 && !value) return null;
  return <FilterMenu label={label} value={value} any={any} choices={options.map((o) => ({ value: o, words: words(o) }))} onPick={onChange} />;
}

/** The state as a word in a pill on an item's page: open, closed, merged, draft; or the tracker's own status (a Jira
 * status, #3260), in the colour of the state it is in. A row has the state icon instead (#4392). */
export function StatePill({ state, draft, status }: { state: string; draft?: boolean | undefined; status?: string | undefined }) {
  if (!state) return null;
  const word = draft && state === "open" ? "draft" : state;
  return <span class={`work-state ${word}`}>{status ?? word}</span>;
}

/** A row (#4392, parts.md section 2), a link to its page (#4395): the state icon, the title and at most three chips, the comment count and the
 * assignees; under it the number, the age, the author and what lineage knows. On a phone the CSS folds it: the
 * title on two lines, every chip under it, the short line and no avatars. */
function WorkRowView({ row, several, dim, pick, open }: { row: WorkRow; several: boolean; dim: boolean; pick: (label: string) => void; open: () => void }) {
  const line = rowLine(row, Date.now());
  const checks = row.node.kind === "pr" ? checksGlyph(row.checks) : undefined;
  const review = row.node.kind === "pr" ? rowReviewWords(row.review) : undefined;
  const comments = row.comments ?? 0;
  return (
    <li data-ref={row.node.ref} class={dim ? "stale" : undefined}>
      {/* A link (lists.md section 4): a click opens the page here, a middle-click or ⌘-click in a new tab. */}
      <a class="work-row work-item-row" href={routeHash({ nav: "work", section: row.node.kind, item: row.node.ref })}
        onClick={(e) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); open(); }}>
        <span class="work-row-icon"><StateIcon kind={row.node.kind} state={row.state} draft={row.draft} /></span>
        <span class="work-row-main">
          <span class="work-row-head">
            <span class="work-title"><ForgeTitle text={row.title} /></span>
            {row.labels.length > 0 && (
              <span class="work-chips">
                {row.labels.map((l) => <LabelChip key={l.name} label={l} pick={pick} />)}
                {row.labels.length > 3 && <span class="work-chips-more quiet small">+{row.labels.length - 3}</span>}
              </span>
            )}
          </span>
          <span class="work-row-line quiet small">
            <span class="wide-line">{line.wide}</span><span class="short-line">{line.short}</span>
            {several && <span class="work-row-repo">{repoName(row.repo)}</span>}
          </span>
        </span>
        <span class="work-row-end small">
          {checks && <span class={`work-checks ${checks.tone}`} title={checks.words} aria-label={checks.words}>{checks.mark}</span>}
          {review && <span class={`work-review${row.review === "changes_requested" ? " bad" : ""}`}>{review}</span>}
          {comments > 0 && <span class="work-count" aria-label={`${comments} comment${comments === 1 ? "" : "s"}`}>
            <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z" /></svg>{comments}</span>}
          <Avatars logins={row.assignees} />
        </span>
      </a>
    </li>
  );
}

/** The page of one issue, PR or release (#3119): the item from its forge (forge/issue,
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
  // The page's images, read by the machine that read the page (#4011); without forge/image there, their words.
  const imageHost = detail.value && store.has(detail.value.host, Capability.forgeImage1) ? detail.value.host : null;
  const forgeImages = useMemo<ForgeImages | undefined>(() => imageHost === null ? undefined
    : (url) => store.link.call("forge/image", { url }, imageHost).then((got) => ({ bytes: bytesOf(got.data), type: got.mimeType })),
  [imageHost]);
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
    if (!lineageHost) return;
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

  const spentWords = estimate.value ? estimateSpentWords(estimate.value) : undefined;
  const lineage = [...spentWords ? [spentWords] : [], ...actual ? [actual] : []];
  const commentCount = item?.comments ?? detail.value?.got.comments.length ?? 0;
  const byline = item ? [
    ...item.author ? [item.author] : [],
    `updated ${ago(fromWireDate(item.updatedAt))}`,
    ...commentCount > 0 ? [`${commentCount} comment${commentCount === 1 ? "" : "s"}`] : [],
  ].join(" · ") : "";

  return (
    <article class="work-page work-item-page">
      <div class="work-item-grid">
      <div class="work-page-bar">
        <button type="button" title="Back" aria-label="Back" onClick={() => history.back()}>‹</button>
        <button type="button" title="Forward" aria-label="Forward" onClick={() => history.forward()}>›</button>
        <button type="button" class="link" onClick={() => go({ nav: "work", section: kind })}>All {workKindTitle[kind].toLowerCase()}</button>
        <Stepper store={store} kind={kind} at={ref} />
        <RefreshButton busy={fromForge(kind) && !detail.value && !forgeProblem.value} onClick={() => { asked.value++; }} />
      </div>
      <header class="work-page-head">
        <h2><span class="work-title"><ForgeTitle text={title} /></span> {!titleSaysRef({ title, node }) && <span class="work-ref">{shortRef(ref)}</span>}</h2>
        <p class="work-page-byline small">
          <StatePill state={state} draft={item?.draft} status={item?.status} />
          {byline && <span class="quiet">{byline}</span>}
          {url && <a href={url} target="_blank" rel="noopener noreferrer">{openOnWords(ref)}</a>}
        </p>
      </header>
      {/* The side panel (#4392, parts.md section 5): a column on a wide page; under the header on a narrow one, with
          Linked and Lineage at the end. */}
      {item && (
        <aside class="work-side people" aria-label="Details">
          <SideSection title="Assignees">
            {item.assignees.length === 0 ? <span class="quiet">No one</span>
              : item.assignees.map((a) => <span key={a} class="work-person"><Avatar login={a} />{a}</span>)}
          </SideSection>
          <SideSection title="Labels">
            {labels.length === 0 ? <span class="quiet">None</span> : <span class="work-chips">{labels.map((l) => <LabelChip key={l.name} label={l} />)}</span>}
          </SideSection>
          <SideSection title="Repo">
            <span>{repoName(repoOf(ref))}</span>
            {project && <span class="quiet">{projectWords(project.name)}</span>}
          </SideSection>
        </aside>
      )}
      <div class="work-main">
        {estimate.value && isOpen && showsEstimate(estimate.value) && (
          <p class="quiet small work-estimate" title={estimateRangeWords(estimate.value)}>{estimateLine(estimate.value)}</p>
        )}
        {pipeline.value.length > 0 && (
          <p class="small work-pipeline">{pipeline.value.map((s, i) => (
            <Fragment key={i}>{i > 0 && " · "}{s.url ? <a href={s.url} target="_blank" rel="noopener noreferrer">{s.words}</a> : <span class="quiet">{s.words}</span>}</Fragment>
          ))}</p>
        )}
        {(checks || review) && <p class="small">{[checks, review].filter(Boolean).join(" · ")}</p>}
        {writes && detail.value && <WorkActions store={store} host={detail.value.host} detail={detail.value.got} wrote={() => void reread()} />}
        {forgeProblem.value && <ErrorStrip lines={[forgeProblem.value]} retry={() => { asked.value++; }} />}
        {fromForge(kind) && !detail.value && !forgeProblem.value && <PlaceholderRows />}
        {detail.value && hasPlan(detail.value.got.item) && (
          <WorkPlan store={store} host={detail.value.host} lineageHost={lineageHost} detail={detail.value.got} asked={asked.value}
            estimates={estimate.value?.children ?? []}
            writes={writes} wrote={() => void reread()} />
        )}
        {detail.value && (
          <section class="work-body" aria-label="Description">
            {detail.value.got.body.trim() ? <Markdown text={forgeMarkdown(detail.value.got.body)} forgeImages={forgeImages} /> : <p class="quiet">No description.</p>}
          </section>
        )}
        {detail.value && (detail.value.got.comments.length > 0 || detail.value.got.cursor) && (
          <section class="work-comments" aria-label="Comments">
            {detail.value.got.cursor && <button type="button" class="link" disabled={older.value} onClick={() => void readOlder()}>
              {older.value ? "Loading…" : "Older comments"}</button>}
            {detail.value.got.comments.map((c, i) => <Comment key={`${c.at}-${i}`} comment={c} forgeImages={forgeImages} />)}
          </section>
        )}
        {writes && detail.value && <WorkCommentBox store={store} host={detail.value.host} node={node} wrote={() => void reread()} />}
        {detail.value && (kind === "issue" || kind === "pr") && (
          <WorkDocs store={store} itemRef={ref} title={detail.value.got.item.title} body={detail.value.got.body} asked={asked.value} />
        )}
      </div>
      {item && (
        <aside class="work-side links" aria-label="Linked and lineage">
          <SideSection title="Linked">
            {item.parent ? (
              <button type="button" class="work-mini-row" onClick={() => go({ nav: "work", section: "issue", item: item.parent!.ref })}>
                <StateIcon kind="issue" state="open" size={14} /><span>{shortRef(item.parent.ref)}</span><span class="quiet">parent</span>
              </button>
            ) : <span class="quiet">None</span>}
          </SideSection>
          <SideSection title="Lineage">
            {lineage.length === 0 ? <span class="quiet">None</span> : lineage.map((w) => <span key={w}>{w}</span>)}
          </SideSection>
        </aside>
      )}
      </div>
    </article>
  );
}

/** One section of the side panel: a small grey heading, then its value. */
function SideSection({ title, children }: { title: string; children: ComponentChildren }) {
  return (
    <section class="work-side-section">
      <h3>{title}</h3>
      <div class="value">{children}</div>
    </section>
  );
}

/** A comment on the timeline (#4392, parts.md section 6): its avatar on the line, the author, when, and the body in a
 * box; a bot's with a small "bot" capsule. */
function Comment({ comment: c, forgeImages }: { comment: ForgeComment; forgeImages: ForgeImages | undefined }) {
  const at = fromWireDate(c.at);
  return (
    <div class="work-comment">
      <Avatar login={c.author} size={28} />
      <div class="work-comment-main">
        <p class="small">
          <span class="strong">{c.author}</span>
          {c.bot && <span class="work-bot">bot</span>}
          <span class="quiet" title={at.toLocaleString()}> commented {ago(at)}</span>
        </p>
        <div class="work-comment-body"><Markdown text={forgeMarkdown(c.body)} forgeImages={forgeImages} /></div>
      </div>
    </div>
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
