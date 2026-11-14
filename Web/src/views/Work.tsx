// Work ▸ Issues, Pull requests and Releases (#3119, spec 3100), as the window's WorkView: every issue
// and pull request from forge/issues and forge/pulls on each machine, one row per ref, with what
// lineage knows (reports/nodes: sessions, cost, lead time) under its title; the releases lineage
// knows. A row opens its page.
import { effect, useSignal } from "@preact/signals";
import { Fragment, type ComponentChildren } from "preact";
import { useEffect, useMemo, useRef } from "preact/hooks";
import type {
  ForgeCloseRequest, ForgeComment, ForgeDone, ForgeEvent, ForgeLinked, ForgeItemDetail, ForgeLabel, ForgeLabelRequest, LineageCostRollup, LineageEstimate, LineageForecast,
} from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { describe } from "../model/errors";
import { hostAnswers } from "../model/capabilities";
import {
  boardChoices, boardName, checksGlyph, choices, clearedFilter, connectForge, couldNotLoadMore, couldNotRead,
  credentialProblem, emptyWords, endWords, errorWords, eventsSayClose, filtered, fromForge, listTotal, loadingMore, timelineEntries, parseWorkQuery, setFilters, workQuery,
  lineageOnlyNote, noForgeHere, notReadHere, openOnWords, positionWords, repoName, repoOf, rowLine, rowReviewWords,
  shortRef, titleSaysRef, workKindTitle, workSortTitle, allProjects, projectOfFolder, workFolderKey,
  defaultSort, doneWords, forgeName, lineageCountWords, pageStateWords, shortPositionWords, stateGlyph, takesLabels,
  workSorts, type WorkFilter, type WorkKind, type WorkProject, type WorkRow, type WorkSort, type WorkState,
} from "../model/work";
import { latest, latestWords } from "../model/workRelease";
import { newSessionProjects } from "../model/projects";
import { orderedFolders } from "./Sidebar";
import { lineageUrl, sessionHost } from "../model/lineage";
import { type PipelineStep, pipelineDepth, pipelineSteps } from "../model/pipeline";
import { buildsRunLinkHelp, buildsRunLinkQuery } from "../model/builds";
import { costWords, nodeName, spent } from "../model/value";
import { actualWords, estimateLine, estimateRangeWords, estimateSpentWords, showsEstimate } from "../model/estimate";
import { forecastHelp, keptHelp, keptLine, landsLine, toCompleteLine } from "../model/forecast";
import { offerStart } from "./NewAgent";
import { ago } from "../model/connectorSetup";
import { fromWireDate } from "../protocol/dates";
import { type ForgeImages, Markdown } from "../render/markdown";
import { bytesOf } from "../model/pageImage";
import { keepWork, keptPicture, keptWorkRead } from "../model/localCopy";
import { forgeMarkdown } from "../model/forgeMarkdown";
import { ForgeTitle } from "../render/ForgeTitle";
import {
  Avatar, Avatars, EmptyState, ErrorStrip, FilterMenu, FromDeviceStrip, LabelChip, PlaceholderRows, RefreshButton, StateIcon, picture, type MenuChoice, type ReadPicture,
} from "./WorkParts";
import { WorkChecksPage, WorkCommentBox, WorkFilesChanged, WorkLabelsPicker, WorkMergeBox, WorkStatusMenu } from "./WorkActions";
import { branchWords, mergeBox, mergedStrip, offers, pullStateWords, reviewersWords } from "../model/workPull";
import { WorkPlan } from "./WorkPlan";
import { WorkDocs } from "./Docs";
import { hasPlan, leadStart, leadWords, planSessions } from "../model/epicPlan";
import { epicLead } from "../model/workFeatures";
import { go, replace, route, routeHash } from "../route";
import {
  allRows, askKey, boardHosts, boards, forgeHosts, fromList, hasMore, listProjects, loadBoards, loadList, loadMore, nextAfter, pageNeighbours,
  placeKey, shownRows, workList,
} from "../model/workLists";
import { Glyph, Icon } from "./Icon";

/** The person's projects (#3283), New Session's, for the Project filter and an item's page: each folder by the
 * machine Work's lists read it on. */
export function workProjects(store: Store): WorkProject[] {
  return newSessionProjects(orderedFolders(store.hosts.value, store.folders.value, store.macHostID.value)).map((p) => ({
    id: p.id, name: p.name, folders: new Set(p.folders.map((r) => workFolderKey(r.host.id, r.folder.folder.folder))),
  }));
}

/** What the projects are, as one string, so a list hears of a change and not of each render. */
const projectsKey = (projects: readonly WorkProject[]) => projects.map((p) => `${p.id} ${p.name} ${[...p.folders].join(",")}`).join(";");

/** Each machine's reader of the forge's pictures (forge/image, #4363), kept so an avatar asks once; none on a machine
 * without forge/image, whose avatars are initials. */
const readers = new Map<string, ReadPicture>();
export function pictureReader(store: Store, host: string | undefined): ReadPicture | undefined {
  if (!host || !store.has(host, Capability.forgeImage1)) return undefined;
  let r = readers.get(host);
  if (!r) {
    // From this device's copy when it holds it (#4930): a picture does not change at its URL.
    r = (url) => picture(url, (u) => keptPicture(u, (v) => store.link.call("forge/image", { url: v }, host))
      .then((got) => ({ bytes: bytesOf(got.data), type: got.mimeType })));
    readers.set(host, r);
  }
  return r;
}

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
    if (workQuery(said.filter, said.sort, kind) !== workQuery(filter.peek(), sort.peek(), kind)) { filter.value = said.filter; sort.value = said.sort; }
  }, [kind, query]);
  const asked = workQuery(filter.value, sort.value, kind);
  useEffect(() => {
    const now = workQuery(filter.peek(), sort.peek(), kind);
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
  // The latest release of each repo has a green Latest chip (milestones.md note 19).
  const newest = kind === "release" ? latest(all) : undefined;
  const errors = (lists.value ?? []).flatMap((h) => h.errors.map((e) => errorWords(e, hosts.length > 1 ? store.hosts.value.find((x) => x.id === h.host)?.name : undefined)));
  const set = (patch: Partial<WorkFilter>) => { filter.value = { ...filter.value, ...patch }; };
  const states: WorkState[] = kind === "pr" ? ["open", "merged", "closed", "all"] : ["open", "closed", "all"];

  const filter_ = filter.value;
  const pick = (label: string) => set({ label });
  const stateChoices: MenuChoice[] = states.map((s) => ({ value: s, words: s === "all" ? "All" : s.charAt(0).toUpperCase() + s.slice(1) }));
  const sortChoices: MenuChoice[] = workSorts(kind).map((s) => ({ value: s, words: workSortTitle[s] }));
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
  // The forge's count of the list (#4396), where it gives one and the list shows all it counts.
  const total = listTotal((lists.value ?? []).map((h) => h.total), filter.value);
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
              <Icon name="x" />Clear</button>
          )}
          <span class="work-sort">
            <FilterMenu label="Sort" standard={defaultSort(kind)} value={sort.value} choices={sortChoices} onPick={(v) => { sort.value = v as WorkSort; }} />
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
            <FromDeviceStrip at={l.fromDevice.value ? l.readAt.value : undefined} />
            <ErrorStrip lines={problems} retry={refresh} at={stale.size > 0 ? l.readAt.value : undefined} />
            {rows.length === 0
              ? <EmptyState kind={kind} title={empty.title}
                  line={narrowed ? setFilters(filter_, offeredProjects.find((p) => p.id === filter_.project)?.name, filter_.board ? boardName(boards.value, filter_.board) : undefined) : empty.line}
                  action={narrowed ? { words: "Clear filters", run: clear } : undefined} />
              : (
                <ul class="work-rows work-item-rows" ref={rowsAt}>
                  {rows.map((r) => <WorkRowView key={r.node.ref} row={r} several={offered.repos.length > 1} dim={stale.has(r.node.ref)} pick={pick}
                    latest={newest?.has(r.node.ref) === true} read={pictureReader(store, r.host)}
                    open={() => { l.opened.value = r.node.ref; fromList.value = placeKey(kind, r.node.ref); go({ nav: "work", section: kind, item: r.node.ref }); }} />)}
                </ul>
              )}
          </>
        )}
      {shown && (
        <div class="work-list-end quiet small" ref={end} aria-live="polite">
          {more.value ? <><span class="work-spinner" aria-hidden="true" />{loadingMore(rows.length, total)}</>
            : failed ? <><span title={failed}>{couldNotLoadMore}</span><button type="button" onClick={() => void loadMore(store, l)}>Try again</button></>
            : further ? <><button type="button" onClick={() => void loadMore(store, l)}>Load more</button><span>{endWords(kind, rows.length, true, total)}</span></>
            : <span>{endWords(kind, rows.length, false, total)}</span>}
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
export function WorkRowView({ row, several, dim, pick, read, open, latest: isLatest = false }: {
  row: WorkRow; several: boolean; dim: boolean; pick: (label: string) => void; read: ReadPicture | undefined; open: () => void; latest?: boolean;
}) {
  const line = rowLine(row, Date.now());
  const checks = row.node.kind === "pr" ? checksGlyph(row.checks) : undefined;
  const review = row.node.kind === "pr" ? rowReviewWords(row.review) : undefined;
  const comments = row.comments ?? 0;
  return (
    <li data-ref={row.node.ref} class={dim ? "stale" : undefined}>
      {/* A link (lists.md section 4): a click opens the page here, a middle-click or ⌘-click in a new tab. */}
      <a class="work-row work-item-row" href={routeHash({ nav: "work", section: row.node.kind, item: row.node.ref })}
        onClick={(e) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); open(); }}>
        <span class="work-row-icon">{row.node.kind === "release" ? <ReleaseGlyph /> : <StateIcon kind={row.node.kind} state={row.state} draft={row.draft} stateReason={row.stateReason} />}</span>
        <span class="work-row-main">
          <span class="work-row-head">
            <span class="work-title"><ForgeTitle text={row.title} /></span>
            {isLatest && <ReleaseChip />}
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
          {checks && <span class={`work-checks ${checks.tone}`} title={checks.words} aria-label={checks.words}><Glyph of={checks.mark} /></span>}
          {review && <span class={`work-review${row.review === "changes_requested" ? " bad" : ""}`}>{review}</span>}
          {comments > 0 && <span class="work-count" aria-label={`${comments} comment${comments === 1 ? "" : "s"}`}>
            <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z" /></svg>{comments}</span>}
          {/* The forge gives the author's picture (#4363): an assignee who wrote it has it. */}
          <Avatars logins={row.assignees} avatars={row.author && row.avatar ? { [row.author]: row.avatar } : {}} read={read} />
        </span>
      </a>
    </li>
  );
}

/** The page of one issue, PR or release (#3119): the item from its forge (forge/issue,
 * forge/pull) on the first machine that reads it. An issue's page is in the Work look (#4402,
 * specs/4328-work-look/issue.md), as the window's WorkItemPage (#4400): the page's bar (the place, ↑ 3 of 42 ↓,
 * Refresh), the header with Start Agent, one timeline (the body, then the comments), the comment box with Close or
 * Reopen, and the side panel (Assignees, Labels with its gear, Repo, Linked, Lineage, Docs). A pull request's page (#4408,
 * specs/4328-work-look/pull-request.md), as the window's (#4406): Files changed at the title's end, the merge box at the
 * end of the timeline (at the top under 700 px, its checks row opening the Checks page), Close or Reopen pull request in
 * the comment box, and Reviewers and Branch on the panel. Its writes (#3130) go to the machine that read it. */
export function WorkPage({ store, kind, ref }: { store: Store; kind: WorkKind; ref: string }) {
  const node = useMemo(() => ({ kind, ref }), [kind, ref]);
  const asked = useSignal(0);
  const detail = useSignal<{ host: string; got: ForgeItemDetail } | null>(null);
  const forgeProblem = useSignal<string | null>(null);
  const reading = useSignal(false);
  /** The item on screen came from this device's copy (#4930): no writes until its machine answers. */
  const fromDevice = useSignal(false);
  /** When the item on screen was read (#5142): this device's copy's time, or the last read that worked. */
  const detailAt = useSignal<number | undefined>(undefined);
  /** When the plan drawn from this device's copy was read, until its machine answers (#5142). */
  const planCopyAt = useSignal<number | undefined>(undefined);
  const older = useSignal(false);
  const estimate = useSignal<LineageEstimate | null>(null);
  const forecast = useSignal<LineageForecast | null>(null);
  const pipeline = useSignal<PipelineStep[]>([]);
  const lineageGot = useSignal<{ cost?: LineageCostRollup | undefined; sessions: string[] } | null>(null);
  const said = useSignal<{ words: string; failed: boolean } | null>(null);
  const writing = useSignal(false);
  const pickingLabels = useSignal(false);
  const checksPage = useSignal(false);
  const forgeHosts = store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.forge1));
  const lineageHosts = store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.lineage1));
  // The page's images, read by the machine that read the page (#4011); without forge/image there, their words.
  const imageHost = detail.value && store.has(detail.value.host, Capability.forgeImage1) ? detail.value.host : null;
  const forgeImages = useMemo<ForgeImages | undefined>(() => imageHost === null ? undefined
    : (url) => keptPicture(url, (u) => store.link.call("forge/image", { url: u }, imageHost))
      .then((got) => ({ bytes: bytesOf(got.data), type: got.mimeType })),
  [imageHost]);
  // Lineage from the machine that read the forge, else this Mac, else the first that keeps links.
  const lineageHost = lineageHosts.find((h) => h.id === detail.value?.host)?.id
    ?? lineageHosts.find((h) => h.id === store.macHostID.value)?.id ?? lineageHosts[0]?.id;
  // A new item starts empty; a refresh keeps the page, and Refresh spins, until the new read comes.
  useEffect(() => { detail.value = null; fromDevice.value = false; forgeProblem.value = null; said.value = null; pickingLabels.value = false; checksPage.value = false; }, [kind, ref]);
  useEffect(() => {
    let current = true;
    if (!fromForge(kind)) return;
    reading.value = true;
    // A page opened from an address reads before the machines have said what they do: placeholders until one that
    // reads the forge comes, and "no machine" only once none came.
    if (forgeHosts.length === 0) {
      const none = setTimeout(() => { if (current) { forgeProblem.value = noForgeHere; reading.value = false; } }, 4000);
      return () => { current = false; clearTimeout(none); };
    }
    void (async () => {
      // Seen before: this device's copy at once, until a machine answers (#4930).
      if (!detail.peek()) {
        const kept = await keptWorkRead<{ host: string; got: ForgeItemDetail }>("item", ref);
        if (current && kept && !detail.peek()) { detail.value = kept.value; detailAt.value = kept.at; fromDevice.value = true; }
      }
      let last: string | null = null;
      for (const h of forgeHosts) {
        try {
          const got = await store.link.call(kind === "pr" ? "forge/pull" : "forge/issue", { node }, h.id);
          if (current) {
            detail.value = { host: h.id, got }; detailAt.value = Date.now(); fromDevice.value = false; forgeProblem.value = null;
            keepWork("item", ref, { host: h.id, got });
          }
          return;
        } catch (e) {
          last = describe(e);
        }
      }
      if (current) forgeProblem.value = last ?? notReadHere;
    })().finally(() => { if (current) reading.value = false; });
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
  // An epic's forecast (#4527): when an open one lands and what it costs to complete, and a closed one's first
  // forecast against when it landed. A standing epic never lands (#3662).
  const forecasts = isIssue && !!detail.value && hasPlan(detail.value.got.item) && detail.value.got.item.standing !== true;
  useEffect(() => {
    let current = true;
    forecast.value = null;
    if (!lineageHost || !forecasts) return;
    void store.link.call("lineage/forecast", { node }, lineageHost).then((r) => { if (current) forecast.value = r; }, () => {});
    return () => { current = false; };
  }, [kind, ref, lineageHost, forecasts, isOpen, asked.value]);
  const f = forecasts ? forecast.value : null;
  const forecastLines = !f ? [] : isOpen ? [landsLine(f), toCompleteLine(f)].filter((l) => l !== undefined)
    : [keptLine(f, detail.value?.got.item.closedAt)].filter((l) => l !== undefined);
  const forecastTitle = f ? isOpen ? forecastHelp(f) : keptHelp(f) : undefined;
  // The outer loop in reach (#3588): its releases, CI runs, deploys and health, and what it came from.
  useEffect(() => {
    let current = true;
    pipeline.value = [];
    if (!lineageHost) return;
    void store.link.call("lineage/walk", { node, depth: pipelineDepth }, lineageHost)
      .then((g) => { if (current) pipeline.value = pipelineSteps(node, g); }, () => {});
    return () => { current = false; };
  }, [kind, ref, lineageHost, asked.value]);
  // The cost and the sessions of an issue or a pull request (#4402 note 14), from the machine that keeps its links.
  const hasDetail = detail.value !== null;
  useEffect(() => {
    let current = true;
    lineageGot.value = null;
    if (!lineageHost || !hasDetail || !fromForge(kind)) return;
    void Promise.all([
      store.link.call("lineage/cost", { node }, lineageHost).catch(() => undefined),
      store.link.call("lineage/walk", { node }, lineageHost).catch(() => undefined),
    ]).then(([cost, walk]) => { if (current) lineageGot.value = { cost, sessions: planSessions(node, walk?.links ?? [], cost) }; });
    return () => { current = false; };
  }, [kind, ref, lineageHost, hasDetail, asked.value]);

  // The item again after a write (#3130), from the machine that read it, keeping the page until it comes.
  const reread = async () => {
    const had = detail.value;
    if (!had) return;
    try {
      const got = await store.link.call(kind === "pr" ? "forge/pull" : "forge/issue", { node }, had.host);
      detail.value = { host: had.host, got };
      detailAt.value = Date.now();
      fromDevice.value = false;
      keepWork("item", ref, { host: had.host, got });
    } catch (e) {
      forgeProblem.value = describe(e);
    }
  };
  // None while the page is this device's copy (#4930): a write acts on the machine's own answer.
  const writes = detail.value !== null && !fromDevice.value && store.has(detail.value.host, Capability.forgeWrite1);
  // The page's one "From this device" strip (#5142): the oldest of the item's and the plan's copies on screen.
  const copyReads = [fromDevice.value ? detailAt.value : undefined, planCopyAt.value].filter((at): at is number => at !== undefined);
  const copyAt = forgeProblem.value || copyReads.length === 0 ? undefined : Math.min(...copyReads);
  // A write from the header or the side panel (the status menu, a label); what it did is the line under the comment box.
  const act = async (method: "forge/close" | "forge/label", params: ForgeCloseRequest | ForgeLabelRequest) => {
    const host = detail.value?.host;
    if (!host || writing.value) return;
    writing.value = true;
    try {
      const done = await store.link.call(method, params as never, host) as ForgeDone;
      const close = method === "forge/close" ? params as ForgeCloseRequest : undefined;
      said.value = { words: doneWords(method, done, close?.reopen === true, close?.transition !== undefined), failed: false };
      await reread();
    } catch (e) {
      said.value = { words: describe(e), failed: true };
    } finally {
      writing.value = false;
    }
  };

  const readOlder = async () => {
    const had = detail.value;
    if (!had?.got.cursor || fromDevice.peek()) return;
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

  const got = detail.value?.got;
  const item = got?.item;
  // The row the page was opened from, while the read runs: its title, number and state show at once.
  const row = !item && fromForge(kind) ? allRows(workList(kind)).find((r) => r.node.ref === ref) : undefined;
  const title = item?.title ?? row?.title ?? (fromForge(kind) ? undefined : nodeName(node));
  const state = item?.state ?? row?.state ?? "";
  const draft = item?.draft ?? row?.draft;
  const status = item?.status ?? row?.status;
  const labels: ForgeLabel[] = item?.labels ?? row?.labels ?? [];
  const assignees = item?.assignees ?? row?.assignees ?? [];
  const url = item?.url ?? row?.url ?? lineageUrl(node);
  const openOn = openOnWords(ref);
  // The project the item was read for (#3283), when the person has more than one: with one, the page says nothing new.
  const projects = workProjects(store);
  const project = projects.length > 1 && detail.value ? projectOfFolder(item?.folder, detail.value.host, projects) : undefined;
  const updated = item ? fromWireDate(item.updatedAt) : row && row.updated > 0 ? new Date(row.updated * 1000) : undefined;
  const wireDate = (at: number | undefined, unix: number | undefined) =>
    at !== undefined ? fromWireDate(at as never) : unix !== undefined ? new Date(unix * 1000) : undefined;
  const byline = {
    author: item?.author ?? row?.author, updated, comments: item?.comments ?? row?.comments ?? got?.comments.length ?? 0, state,
    created: wireDate(item?.createdAt, item ? undefined : row?.created), closed: wireDate(item?.closedAt, item ? undefined : row?.closed),
  };
  const words = kind === "pr" ? pullStateWords(byline) : pageStateWords(byline);
  const stateReason = item?.stateReason ?? row?.stateReason;
  const read = pictureReader(store, detail.value?.host);
  const authorAvatar = item?.authorAvatar ?? row?.avatar;
  // A pull request's merge box (note 10): an open one's; Files changed, the diff, in the header.
  const box = got ? mergeBox(got) : undefined;
  const isPull = kind === "pr" && got !== undefined;
  const writeBox = (top: boolean) => box && detail.value && (
    <WorkMergeBox store={store} host={detail.value.host} detail={detail.value.got} box={box} writes={writes} waiting={fromDevice.value} top={top}
      checksPage={top ? () => { checksPage.value = true; } : undefined} wrote={() => void reread()} />
  );
  // The comment box's Close or Reopen: an issue with no tracker's status; a pull request's as its forge offers them.
  // A standing epic never closes (epic.md note 16).
  const closes = !got || got.transitions || got.item.standing ? undefined : kind === "issue" ? got.item.state
    : kind === "pr" && got.item.state === "open" && offers(got, "close") ? "open"
    : kind === "pr" && got.item.state === "closed" && offers(got, "reopen") ? "closed" : undefined;
  // Start Agent: on an open issue whose read gives a start (one in a folder), when a machine of the person's writes. An
  // epic has Start lead or Open lead in its place (#4418, epic.md note 1).
  const isEpic = item !== undefined && hasPlan(item);
  const start = kind === "issue" && writes && item?.state === "open" && !isEpic ? got?.start : undefined;
  const lead = isEpic ? epicLead(node, Object.values(store.agents.value).flat()) : undefined;
  const leadAt = lead ? sessionHost(store.agents.value, lead.id) : undefined;
  const startsLead = isEpic && !lead && writes && item?.state === "open" ? got?.start : undefined;
  const startLead = () => {
    if (!detail.value || !startsLead) return;
    if (!item?.folder) { said.value = { words: "No folder on this machine is on this issue's repo.", failed: true }; return; }
    const why = offerStart(store, detail.value.host, item.folder, leadStart(startsLead, item.url));
    if (why) said.value = { words: why, failed: true };
  };
  const startAgent = () => {
    if (!detail.value || !start) return;
    if (!item?.folder) { said.value = { words: "No folder on this machine is on this issue's repo.", failed: true }; return; }
    const why = offerStart(store, detail.value.host, item.folder, { prompt: start.prompt, labels: start.labels, worktree: start.worktree });
    if (why) said.value = { words: why, failed: true };
  };
  const labelsEdit = (kind === "issue" || kind === "pr") && writes && item && takesLabels(item.node);
  const pickLabel = (name: string) => { workList(kind).filter.value = { ...workList(kind).filter.value, label: name }; go({ nav: "work", section: kind }); };

  // Lineage (#4402 note 14): the cost and the sessions, then the estimate of an open issue, or what a closed one spent;
  // then the pipeline line.
  const cost = lineageGot.value?.cost && spent(lineageGot.value.cost.total) ? costWords(lineageGot.value.cost.total) : undefined;
  const sessions = lineageGot.value?.sessions ?? [];
  const counts = lineageCountWords(cost, sessions.length);
  const showsEst = estimate.value && isOpen && showsEstimate(estimate.value);
  const spentWords = estimate.value ? estimateSpentWords(estimate.value) : undefined;
  const hasLineage = counts !== "" || showsEst || actual !== undefined || forecastLines.length > 0 || pipeline.value.length > 0;
  const session = (id: string) => <WorkSession key={id} store={store} id={id} />;

  const nothingRead = !detail.value && forgeProblem.value !== null;
  const loading = fromForge(kind) && !detail.value && !forgeProblem.value;
  const narrowStart = start ? (
    <button type="button" class="prominent work-start" disabled={writing.value} onClick={startAgent}
      title="The new-agent form in this issue's folder, filled in for it"><Icon name="sparkles" />Start Agent</button>
  ) : lead ? (
    // Open lead (bordered), with a dot for the lead's state: green while it works, the attention colour when it needs you.
    <button type="button" class="work-start work-open-lead" title="The lead's chat" aria-label={`Open lead, ${leadWords(lead.state)}`}
      onClick={() => { if (leadAt) go({ host: leadAt, folder: lead.worktree?.folder || lead.cwd, session: lead.id }); }}>
      <PersonGlyph />Open lead<span class={`dot ${lead.state === "waitingOnUser" ? "attention" : ["starting", "running"].includes(lead.state) ? "working" : "quiet"}`} aria-hidden="true" />
    </button>
  ) : startsLead && (
    <button type="button" class="prominent work-start" onClick={startLead}
      title="The new-session form in this epic's folder, filled in for a lead with the lead skill"><Icon name="sparkles" />Start lead</button>
  );

  // The Checks page (note 17), pushed from the checks row of a page under 700 px.
  if (checksPage.value && detail.value && kind === "pr") {
    return (
      <article class="work-page work-item-page">
        <WorkChecksPage store={store} host={detail.value.host} detail={detail.value.got} writes={writes}
          back={() => { checksPage.value = false; }} wrote={() => void reread()} />
      </article>
    );
  }

  return (
    <article class={`work-page work-item-page${loading ? " loading" : ""}`} aria-busy={loading}>
      <div class="work-item-grid">
      <div class="work-page-bar">
        {/* The place (note 1): Issues / #4331, Issues a link to the list as it was; the browser's Back and Forward are
            the page's. On a 390 px page: ‹ Issues. */}
        <nav class="work-place" aria-label="Place">
          <a href={routeHash({ nav: "work", section: kind })} title={`All ${workKindTitle[kind].toLowerCase()}`}
            onClick={(e) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); go({ nav: "work", section: kind }); }}>
            <Icon name="chevron-left" class="back" />{workKindTitle[kind]}</a>
          <span class="sep" aria-hidden="true">/</span>
          <span class="here">{shortRef(ref)}</span>
        </nav>
        <Stepper store={store} kind={kind} at={ref} />
        {url && <a class="work-open-icon" href={url} target="_blank" rel="noopener noreferrer" title={openOn} aria-label={openOn}><OpenGlyph /></a>}
        <RefreshButton busy={reading.value} onClick={() => { asked.value++; }} />
      </div>
      {nothingRead ? (
        <div class="work-could-not" role="alert">
          <span class="mark" aria-hidden="true"><Icon name="triangle-alert" /></span>
          <p class="strong">Could not read {shortRef(ref)}</p>
          <p class="quiet">{forgeProblem.value}</p>
          <p class="buttons">
            <button type="button" onClick={() => { asked.value++; }}>Try again</button>
            {url && <a href={url} target="_blank" rel="noopener noreferrer">{openOn}</a>}
          </p>
        </div>
      ) : (
      <>
      <header class={`work-page-head${title === undefined ? " placeholder" : ""}`}>
        <div class="work-title-line">
          <h2>
            {title === undefined ? <span class="bar" aria-label="Loading" />
              : <><span class="work-title"><ForgeTitle text={title} /></span> {!titleSaysRef({ title, node }) && <span class="work-ref">{shortRef(ref)}</span>}</>}
          </h2>
          {narrowStart && <span class="wide-only">{narrowStart}</span>}
          {isPull && detail.value && <span class="work-wide-only"><WorkFilesChanged store={store} host={detail.value.host} detail={detail.value.got} /></span>}
        </div>
        <p class="work-page-byline small">
          {got?.transitions && writes && item
            ? <WorkStatusMenu state={item.state} status={item.status} transitions={got.transitions} busy={writing.value}
                move={(id) => void act("forge/close", { node: item.node, transition: id })} />
            : <PagePill kind={kind} state={state} draft={draft} status={status} stateReason={stateReason} />}
          {item?.standing && <span class="work-standing">Standing</span>}
          {words.wide && <span class="quiet"><span class="wide-line">{words.wide}</span><span class="short-line">{words.short}</span></span>}
          {url && <a class="work-open-on" href={url} target="_blank" rel="noopener noreferrer"><OpenGlyph />{openOn}</a>}
        </p>
        {narrowStart && <div class="narrow-only">{narrowStart}</div>}
      </header>
      {detail.value && forgeProblem.value && (
        <div class="work-problem"><ErrorStrip lines={[forgeProblem.value]} retry={() => { asked.value++; }} at={detailAt.value} /></div>
      )}
      {copyAt !== undefined && <div class="work-problem"><FromDeviceStrip at={copyAt} /></div>}
      {/* A pull request under 700 px (pull-request.md, Narrow): the merge box at the top, then Files changed as a row. */}
      {isPull && detail.value && (
        <div class="work-pull-top work-narrow-only">
          {writeBox(true)}
          <WorkFilesChanged store={store} host={detail.value.host} detail={detail.value.got} row />
        </div>
      )}
      {/* The side panel (parts.md section 5): a column on a page over 900 px; rows under the header on a narrower one,
          with Linked, Lineage and Docs at the end. */}
      {(item || loading) && (
        <aside class="work-side people" aria-label="Details">
          <SideSection title="Assignees">
            {loading && !row ? <span class="bar" /> : assignees.length === 0 ? <span class="quiet">No one</span>
              : assignees.map((a) => <span key={a} class="work-person">
                <Avatar login={a} url={a === byline.author ? authorAvatar : undefined} read={read} />{a}</span>)}
          </SideSection>
          {kind === "pr" && (
            // Each reviewer and their state come with the forge's reviewers (#4406, missing fields).
            <SideSection title="Reviewers">
              {loading && !row ? <span class="bar" /> : <span class={(item?.review ?? row?.review) ? undefined : "quiet"}>{reviewersWords(item?.review ?? row?.review)}</span>}
            </SideSection>
          )}
          <SideSection title="Labels" edit={labelsEdit ? () => { pickingLabels.value = !pickingLabels.value; } : undefined}
            editing={pickingLabels.value}>
            {loading && !row ? <span class="bar" /> : labels.length === 0 ? <span class="quiet">None</span>
              : <span class="work-chips">{labels.map((l) => <LabelChip key={l.name} label={l} pick={pickLabel} />)}</span>}
            {pickingLabels.value && detail.value && item && (
              <WorkLabelsPicker store={store} host={detail.value.host} node={item.node} has={item.labels} close={() => { pickingLabels.value = false; }}
                pick={(name, add) => void act("forge/label", { node: item.node, ...add ? { add: [name] } : { remove: [name] } })} />
            )}
          </SideSection>
          {kind === "pr" && branchWords(got?.filesChanged) && (
            // The head and base branches and the size come with the forge's fields (#4406).
            <SideSection title="Branch"><span class="work-branch"><BranchGlyph />{branchWords(got?.filesChanged)}</span></SideSection>
          )}
          <SideSection title="Repo"><span>{repoName(repoOf(ref))}</span></SideSection>
          {project && <SideSection title="Project"><span>{project.name}</span></SideSection>}
        </aside>
      )}
      <div class="work-main">
        {detail.value && hasPlan(detail.value.got.item) && (
          <WorkPlan store={store} host={detail.value.host} lineageHost={lineageHost} detail={detail.value.got} asked={asked.value}
            estimates={estimate.value?.children ?? []}
            writes={writes} waiting={fromDevice.value} wrote={() => void reread()} fromCopy={(at) => { planCopyAt.value = at; }} />
        )}
        {loading && (
          <div class="work-timeline" aria-hidden="true">
            <div class="work-comment placeholder"><span class="work-avatar" /><div class="work-comment-main">
              <p class="small"><span class="bar short" /></p><div class="work-comment-body"><span class="bar" /><span class="bar" /><span class="bar short" /></div>
            </div></div>
          </div>
        )}
        {got && (
          // One timeline (notes 8 to 10): the body is its first box, Older comments under it, then the comments and the
          // forge's events in time order (#4373); a closed issue's close, from its state where the forge gives no events.
          <section class="work-timeline" aria-label="Timeline">
            <Comment comment={{ author: got.item.author ?? forgeName(ref), body: got.body, at: got.item.createdAt ?? got.item.updatedAt, ...got.item.authorAvatar ? { avatar: got.item.authorAvatar } : {} }}
              words="opened this" forgeImages={forgeImages} read={read} empty="No description." />
            {got.cursor && (
              <div class="work-event">
                <span class="mark" aria-hidden="true">…</span>
                <button type="button" class="link" disabled={older.value} onClick={() => void readOlder()}>{older.value ? "Loading…" : "Older comments"}</button>
              </div>
            )}
            {timelineEntries(got.comments, got.events, got.cursor !== undefined).map((e, i) => "comment" in e
              ? <Comment key={`c${e.at}-${i}`} comment={e.comment} forgeImages={forgeImages} read={read} />
              : <TimelineEvent key={`e${e.at}-${i}`} event={e.event} words={e.words} stateReason={got.item.stateReason} />)}
            {kind === "issue" && got.item.state === "closed" && !got.transitions && !eventsSayClose(got.events) && (
              got.item.stateReason === "not_planned"
                ? <div class="work-event"><span class="mark not-planned" aria-hidden="true"><StateIcon kind="issue" state="closed" stateReason="not_planned" size={12} /></span>
                  <span class="quiet small">Closed as not planned{atWords(got.item.closedAt)}</span></div>
                : <div class="work-event"><span class="mark closed" aria-hidden="true"><Icon name="check" /></span><span class="quiet small">Closed{atWords(got.item.closedAt)}</span></div>
            )}
            {kind === "pr" && got.item.state === "merged" && (
              <>
                <div class="work-event"><span class="mark merged" aria-hidden="true"><StateIcon kind="pr" state="merged" size={12} /></span>
                  <span class="quiet small">Merged{atWords(got.item.closedAt)}</span></div>
                <div class="work-merged-strip">
                  <span class="strong small">{mergedStrip}</span>
                  {pipeline.value.length > 0 && <PipelineLine steps={pipeline.value} kind={node.kind} />}
                </div>
              </>
            )}
            {kind === "pr" && got.item.state === "closed" && (
              <div class="work-event"><span class="mark pr-closed" aria-hidden="true"><Icon name="x" /></span><span class="quiet small">Closed with unmerged commits{atWords(got.item.closedAt)}</span></div>
            )}
            {box && <div class="work-wide-only work-merge-end">{writeBox(false)}</div>}
          </section>
        )}
        {got && detail.value && (writes
          ? <WorkCommentBox store={store} host={detail.value.host} node={node} noun={kind === "pr" ? "pull request" : "issue"}
              closes={closes} said={said.value}
              wrote={(w, failed) => { said.value = { words: w, failed }; if (!failed) void reread(); }} />
          : !box && !fromDevice.value && <p class="quiet small work-no-writes">No machine of yours can write to {forgeName(ref)}.</p>)}
      </div>
      {item && (
        <aside class="work-side links" aria-label="Linked, lineage and docs">
          {(item.parent || item.progress || (got?.children ?? []).length > 0 || (got?.linkedPulls ?? []).length > 0) && (
            <SideSection title="Linked">
              {item.parent && (
                <button type="button" class="work-mini-row" onClick={() => go({ nav: "work", section: "issue", item: item.parent!.ref })}>
                  <StateIcon kind="issue" state="open" size={14} /><span>{shortRef(item.parent.ref)}</span><span class="quiet">parent</span>
                </button>
              )}
              {item.progress && (
                <span class="work-progress">
                  <progress max={Math.max(item.progress.total, 1)} value={item.progress.done} />
                  <span class="quiet small">{item.progress.done} of {item.progress.total} closed</span>
                </span>
              )}
              {/* Its children and the pull requests that close it, where the forge gives them (#4373); each opens its page. */}
              {[...got?.children ?? [], ...got?.linkedPulls ?? []].map((linked) => <LinkedRow key={linked.node.ref} linked={linked} />)}
            </SideSection>
          )}
          {hasLineage && (
            <SideSection title="Lineage">
              {counts && <span>{counts}</span>}
              {sessions.map(session)}
              {showsEst && estimate.value && (
                <span class="quiet small work-estimate" title={estimateRangeWords(estimate.value)}>
                  {[estimateLine(estimate.value), ...spentWords ? [spentWords] : []].join(" · ")}</span>
              )}
              {!isOpen && actual && <span class="quiet small">{actual}</span>}
              {forecastLines.map((line) => <span key={line} class="quiet small work-forecast" title={forecastTitle}>{line}</span>)}
              {pipeline.value.length > 0 && <PipelineLine steps={pipeline.value} kind={node.kind} />}
            </SideSection>
          )}
          {(kind === "issue" || kind === "pr") && (
            <WorkDocs store={store} itemRef={ref} title={item.title} body={got?.body ?? ""} asked={asked.value} />
          )}
        </aside>
      )}
      </>
      )}
      </div>
    </article>
  );
}

/** A session on the Lineage section: its title, a green dot while it runs; a click opens its chat. */
export function WorkSession({ store, id }: { store: Store; id: string }) {
  const h = sessionHost(store.agents.value, id);
  const chat = h ? store.agent(h, id) : undefined;
  const runs = chat ? ["starting", "running", "waitingOnUser"].includes(chat.state) : false;
  return (
    <button type="button" class="work-session" disabled={!chat} aria-label={[chat?.title ?? "A session on another machine", ...runs ? ["running"] : []].join(", ")}
      onClick={() => { if (h && chat) go({ host: h, folder: chat.worktree?.folder || chat.cwd, session: chat.id }); }}>
      <span class={`dot${runs ? " runs" : ""}`} aria-hidden="true" /><span class="name">{chat?.title || "A session on another machine"}</span>
    </button>
  );
}

/** A release's chip after its name (milestones.md note 19): Latest in green; Pre-release and Draft come with the forge's
 * releases (#4426). */
export function ReleaseChip() {
  return <span class="work-release-chip latest">{latestWords}</span>;
}

/** A release's glyph (note 19): a box. */
export function ReleaseGlyph({ size = 16 }: { size?: number }) {
  return <svg class="work-release-glyph" width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
    <path d="M2.5 5 8 2.5 13.5 5v6L8 13.5 2.5 11z" /><path d="M2.5 5 8 7.5 13.5 5M8 7.5v6" /></svg>;
}

/** The page header's state pill (note 6, parts.md section 1): the state's glyph and word, Open, Closed, Merged, Draft,
 * on the state's colour. A tracker's status (a Jira status, #3260) with no write is its word in the pill. */
function PagePill({ kind, state, draft, status, stateReason }: {
  kind: string; state: string; draft?: boolean | undefined; status?: string | undefined; stateReason?: string | undefined;
}) {
  if (!state) return <span class="work-state placeholder" aria-hidden="true">Open</span>;
  if (status || !stateGlyph(kind, state, draft)) return <StatePill state={state} draft={draft} status={status} />;
  const word = draft && state === "open" ? "Draft" : state.charAt(0).toUpperCase() + state.slice(1);
  // The forge's not_planned (#4365): the grey pill with a slash.
  const dropped = kind === "issue" && state === "closed" && stateReason === "not_planned";
  return <span class={`work-state with-glyph ${draft && state === "open" ? "draft" : state}${kind === "pr" && state === "closed" ? " pr-closed" : ""}${dropped ? " not-planned" : ""}`}>
    <StateIcon kind={kind} state={state} draft={draft} stateReason={stateReason} size={14} />{word}</span>;
}

/** " · 3 days ago", after a timeline line's words, where the forge says when. */
function atWords(at: number | undefined) {
  if (at === undefined) return null;
  const d = fromWireDate(at as never);
  return <span title={d.toLocaleString()}> · {ago(d)}</span>;
}

/** One of the forge's events on an issue's timeline (#4373): its mark, then one grey line and when. */
function TimelineEvent({ event: e, words, stateReason }: { event: ForgeEvent; words: string; stateReason: string | undefined }) {
  const dropped = e.kind === "closed" && stateReason === "not_planned";
  const mark = e.kind === "closed" ? <span class={`mark ${dropped ? "not-planned" : "closed"}`} aria-hidden="true">
      {dropped ? <StateIcon kind="issue" state="closed" stateReason="not_planned" size={12} /> : <Icon name="check" />}</span>
    : e.kind === "reopened" ? <span class="mark" aria-hidden="true"><StateIcon kind="issue" state="open" size={12} /></span>
    : e.kind === "assigned" || e.kind === "unassigned" ? <span class="mark" aria-hidden="true"><PersonGlyph /></span>
    : e.kind === "labeled" || e.kind === "unlabeled" ? <span class="mark" aria-hidden="true"><TagGlyph /></span>
    : <span class="mark" aria-hidden="true">↳</span>;
  return <div class="work-event">{mark}<span class="quiet small">{words}{atWords(e.at)}</span></div>;
}

/** A child or a pull request that closes the issue, in Linked: its state, number and title; it opens its page. */
function LinkedRow({ linked }: { linked: ForgeLinked }) {
  const kind = linked.node.kind === "pr" ? "pr" : "issue";
  return (
    <button type="button" class="work-mini-row" title={linked.title} onClick={() => go({ nav: "work", section: kind, item: linked.node.ref })}>
      <StateIcon kind={kind} state={linked.state} size={14} /><span>{shortRef(linked.node.ref)}</span><span class="work-mini-title">{linked.title}</span>
    </button>
  );
}

/** A label's glyph: a tag. */
function TagGlyph() {
  return <svg class="work-open-glyph" width="12" height="12" viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 2.5h5.25l6 6-5.25 5.25-6-6z" /><circle cx="5.5" cy="5.5" r="1" /></svg>;
}

/** The pipeline line (#3588): its releases, CI runs, deploys and health, each a link where it has one. */
export function PipelineLine({ steps, kind }: { steps: readonly PipelineStep[]; kind: string }) {
  // Build trends at the line's newest CI run, on Reports ▸ Planning ▸ Builds (#5180).
  const run = steps.find((s) => s.node?.kind === "ci-run")?.node;
  const trends = run && buildsRunLinkQuery(run.ref);
  return (
    <span class="small work-pipeline">{steps.map((s, i) => (
      <Fragment key={i}>{i > 0 && " · "}{s.url ? <a href={s.url} target="_blank" rel="noopener noreferrer">{s.words}</a> : <span class="quiet">{s.words}</span>}</Fragment>
    ))}{trends && <> · <a href={routeHash({ nav: "reports", section: "value", item: "builds", query: trends })} title={buildsRunLinkHelp(kind)}>Build trends ›</a></>}</span>
  );
}

/** Open lead's glyph: a person. */
function PersonGlyph() {
  return <svg class="work-open-glyph" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="5.5" r="2.75" /><path d="M2.75 14a5.25 5.25 0 0 1 10.5 0" /></svg>;
}

/** Branch's glyph: a branch off a line. */
function BranchGlyph() {
  return <svg class="work-branch-glyph" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><circle cx="4.5" cy="3.5" r="1.5" /><circle cx="4.5" cy="12.5" r="1.5" />
    <circle cx="11.5" cy="5" r="1.5" /><path d="M4.5 5v6M11.5 6.5c0 3-7 2-7 4.5" /></svg>;
}

/** Open on GitHub's glyph: a square with an arrow out of it. */
export function OpenGlyph() {
  return <svg class="work-open-glyph" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M9.5 2.5h4v4M13.5 2.5 7.5 8.5M12 9.5v3.25a.75.75 0 0 1-.75.75h-8a.75.75 0 0 1-.75-.75v-8A.75.75 0 0 1 3.25 4H6.5" /></svg>;
}

/** One section of the side panel: a small grey heading, then its value. `edit`, where the person can change it, is the
 * gear on the heading (note 12); it is faint until the pointer is on the section, as on the Mac. */
export function SideSection({ title, edit, editing, children }: { title: string; edit?: (() => void) | undefined; editing?: boolean; children: ComponentChildren }) {
  return (
    <section class="work-side-section">
      <h3>{title}{edit && (
        <button type="button" class="work-gear" aria-label={`Edit ${title.toLowerCase()}`} title={`Edit ${title.toLowerCase()}`} aria-expanded={editing === true}
          onClick={edit}>
          {/* A cog: its teeth are a dashed ring round a ring. */}
          <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.7" stroke-width="2.4" stroke-dasharray="2.24 2.24" />
            <circle cx="8" cy="8" r="4.3" stroke-width="1.6" /><circle cx="8" cy="8" r="1.4" stroke-width="1.3" /></svg>
        </button>
      )}</h3>
      <div class="value">{children}</div>
    </section>
  );
}

/** A box on the timeline (parts.md section 6): its avatar on the line, the author, when, and the body in a box; a bot's
 * with a small "bot" capsule. `words` says what in place of "commented 20 min ago" (the body's "opened this"); `empty`
 * what an empty body says. On a page under 700 px the CSS puts the avatar in the box's header, 20 px. */
function Comment({ comment: c, words, empty, forgeImages, read }: {
  comment: ForgeComment; words?: string; empty?: string; forgeImages: ForgeImages | undefined; read: ReadPicture | undefined;
}) {
  const at = fromWireDate(c.at);
  return (
    <div class="work-comment">
      <Avatar login={c.author} size={28} url={c.avatar} read={read} />
      <div class="work-comment-main">
        <p class="small">
          <span class="work-comment-small-avatar"><Avatar login={c.author} size={20} url={c.avatar} read={read} /></span>
          <span class="strong">{c.author}</span>
          {c.bot && <span class="work-bot">bot</span>}
          <span class="quiet" title={words ? undefined : at.toLocaleString()}> {words ?? `commented ${ago(at)}`}</span>
        </p>
        <div class="work-comment-body">
          {c.body.trim() || !empty ? <Markdown text={forgeMarkdown(c.body)} forgeImages={forgeImages} /> : <p class="quiet">{empty}</p>}
        </div>
      </div>
    </div>
  );
}

/** Previous and Next through the list the page was opened from (#3257), j and k, and where the page
 * stands in it: ↑ 3 of 42 ↓, and 3/42 on a 390 px page. Each replaces the place, so Back goes to the list. None on a
 * page opened from a link or an address. */
export function Stepper({ store, kind, at }: { store: Store; kind: WorkKind; at: string }) {
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
      <span class="quiet small"><span class="wide-line">{positionWords(n, more)}</span><span class="short-line">{shortPositionWords(n, more)}</span></span>
      <button type="button" title="Next (j)" aria-label="Next" disabled={(!n.next && !more) || l.more.value} onClick={() => void next()}>
        {l.more.value ? "…" : "↓"}</button>
    </span>
  );
}
