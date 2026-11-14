// A release's page in the Work look (#4423, specs/4328-work-look/milestones.md notes 22 to 29 and 50), as the window's
// WorkReleasePage (#4421): the page's bar (Releases / v0.42.0, ↑ 2 of 28 ↓, Refresh), the header with its Latest chip
// and Open on GitHub, the state line with the range to the release before it, the notes, the pull requests in it, and
// the side panel (Tag, Compared with, Pipeline, Lineage): a column over 900 px, rows under the notes under it. Under
// 700 px the pull requests are a row, Pull requests · 23 ›, that opens their list (note 43). It draws what lineage
// knows (lineage/walk, lineage/cost, lineage/figures); the forge's releases (#4426) bring the name, the notes, the
// author, drafts and pre-releases.
import { useSignal } from "@preact/signals";
import { useEffect, useMemo } from "preact/hooks";
import type { LineageCostRollup, LineageFigures, LineageGraph } from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { describe } from "../model/errors";
import { hostAnswers } from "../model/capabilities";
import { anyFilter, choices, filterRows, lineageWords, openOnWords, shortRef, workKindTitle, type WorkFilter } from "../model/work";
import {
  compareUrl, figuresWords, latest, noPipeline, noPulls, notesElsewhere, pipeline, previous, pullRequests, pullsWords, rangeWords,
  runtimesWords, stateWords,
} from "../model/workRelease";
import { lineageUrl } from "../model/lineage";
import { planSessions } from "../model/epicPlan";
import { allRows, askKey, loadList, workList } from "../model/workLists";
import { go, routeHash } from "../route";
import { buildsRunLinkHelp, buildsRunLinkQuery } from "../model/builds";
import { ErrorStrip, PlaceholderRows, RefreshButton, StateIcon } from "./WorkParts";
import { Choice, OpenGlyph, ReleaseChip, ReleaseGlyph, SideSection, Stepper, WorkRowView, WorkSession, pictureReader } from "./Work";
import { Icon } from "./Icon";

const allPulls: WorkFilter = { ...anyFilter, state: "all" };

export function WorkReleasePage({ store, ref }: { store: Store; ref: string }) {
  const node = useMemo(() => ({ kind: "release", ref }), [ref]);
  const asked = useSignal(0);
  const graph = useSignal<LineageGraph | null>(null);
  const rollup = useSignal<LineageCostRollup | undefined>(undefined);
  const figures = useSignal<LineageFigures | undefined>(undefined);
  const problem = useSignal<string | null>(null);
  const reading = useSignal(false);
  // The pull requests' search and Label filter (note 25), and, under 700 px, their list opened (note 43).
  const filter = useSignal<WorkFilter>(allPulls);
  const pullsPage = useSignal(false);

  // The releases list, for the Latest chip, the release before this one and ↑ ↓: read when the page opens from an
  // address.
  const list = workList("release");
  const ask = askKey(store, list);
  useEffect(() => { void loadList(store, list); }, [ask]);
  const rows = allRows(list);
  const row = rows.find((r) => r.node.ref === ref);
  const before = previous(ref, rows);
  const isLatest = latest(rows).has(ref);
  const tag = shortRef(ref);

  // Lineage from this Mac, else the first machine that keeps links.
  const lineageHosts = store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.lineage1));
  const lineageHost = lineageHosts.find((h) => h.id === store.macHostID.value)?.id ?? lineageHosts[0]?.id;
  const figuresHere = lineageHost !== undefined && store.has(lineageHost, Capability.lineageFigures1);
  useEffect(() => { graph.value = null; rollup.value = undefined; figures.value = undefined; problem.value = null; pullsPage.value = false; filter.value = allPulls; }, [ref]);
  // The release's links (its pull requests, CI runs and deploys), its cost and its figures. A refresh keeps the page as
  // it is until the new read comes.
  useEffect(() => {
    let current = true;
    if (!lineageHost) {
      // A page opened from an address reads before the machines have said what they do: placeholders until one comes.
      const none = setTimeout(() => { if (current && !graph.peek()) graph.value = { nodes: [], links: [] }; }, 4000);
      return () => { current = false; clearTimeout(none); };
    }
    reading.value = true;
    void Promise.all([
      store.link.call("lineage/walk", { node, depth: 2 }, lineageHost),
      store.link.call("lineage/cost", { node }, lineageHost).catch(() => undefined),
      // A host before #4427 has no lineage/figures: the row's own figures stand in.
      figuresHere ? store.link.call("lineage/figures", { node }, lineageHost).catch(() => undefined) : Promise.resolve(undefined),
    ]).then(([walked, cost, got]) => {
      if (!current) return;
      graph.value = walked;
      rollup.value = cost;
      figures.value = got;
      problem.value = null;
    }, (e: unknown) => {
      if (!current) return;
      if (!graph.peek()) graph.value = { nodes: [], links: [] };
      problem.value = describe(e);
    }).finally(() => { if (current) reading.value = false; });
    return () => { current = false; };
  }, [ref, lineageHost, figuresHere, asked.value]);

  const g = graph.value;
  const pulls = g ? pullRequests(node, g) : undefined;
  const url = row?.url ?? lineageUrl(node);
  const openOn = openOnWords(ref);
  const released = row && row.updated > 0 ? new Date(row.updated * 1000) : undefined;
  const words = { wide: stateWords(released, pulls?.length, false), short: stateWords(released, pulls?.length, true) };
  const beforeTag = before ? shortRef(before.node.ref) : undefined;
  const compare = beforeTag ? compareUrl(ref, beforeTag) : undefined;
  const refresh = () => { asked.value++; list.asked.value++; };

  const runtimeName = (id: string) => store.hosts.value.map((h) => store.runtimes.value[h.id]?.find((s) => s.runtime.id === id)?.runtime.name)
    .find((name) => name) || id;
  const lineageLine = (figures.value && figuresWords(figures.value)) ?? lineageWords(row?.lineage);
  const runtimes = figures.value ? runtimesWords(figures.value, runtimeName) : undefined;
  const sessions = planSessions(node, g?.links ?? [], rollup.value);
  const stages = g ? pipeline(node, g) : [];
  // Build trends at the release's CI run, on Reports ▸ Planning ▸ Builds (#5180).
  const run = g?.links.find((l) => l.rel === "builds" && l.to.kind === node.kind && l.to.ref === node.ref && l.from.kind === "ci-run")?.from;
  const trends = stages.length > 0 && run ? buildsRunLinkQuery(run.ref) : undefined;

  const shown = pulls ? filterRows(pulls, filter.value) : [];
  const labels = pulls ? choices(pulls).labels : [];
  const set = (patch: Partial<WorkFilter>) => { filter.value = { ...filter.value, ...patch }; };
  const openPull = (prRef: string) => go({ nav: "work", section: "pr", item: prRef });
  const pullRows = pulls === undefined ? <PlaceholderRows />
    : pulls.length === 0 ? <p class="quiet small">{noPulls}</p>
    : shown.length === 0 ? (
      <p class="quiet small work-release-none">No pull requests match
        <button type="button" class="link" onClick={() => { filter.value = allPulls; }}>Clear filters</button></p>
    ) : (
      <ul class="work-rows work-item-rows work-release-pulls">
        {shown.map((r) => <WorkRowView key={r.node.ref} row={r} several={false} dim={false} pick={(label) => set({ label })} read={pictureReader(store, r.host)} open={() => openPull(r.node.ref)} />)}
      </ul>
    );
  const pullsFilters = pulls !== undefined && pulls.length > 0 && (
    <span class="work-release-filters">
      <input type="search" placeholder="Filter pull requests" aria-label="Filter pull requests by words" value={filter.value.text}
        onInput={(e) => set({ text: (e.target as HTMLInputElement).value })} />
      <Choice label="Label" value={filter.value.label} options={labels} onChange={(label) => set({ label })} />
    </span>
  );

  // The phone's list of the pull requests (note 43): ‹ v0.42.0, the search field and Label, then a row for each.
  if (pullsPage.value) {
    return (
      <article class="work-page work-item-page work-release-page">
        <div class="work-page-bar">
          <nav class="work-place" aria-label="Place">
            <button type="button" class="link work-release-back" onClick={() => { pullsPage.value = false; }}>
              <Icon name="chevron-left" />{tag}</button>
          </nav>
        </div>
        <h2 class="work-release-pulls-title">Pull requests</h2>
        <div class="work-release-pulls-bar">{pullsFilters}</div>
        {pullRows}
      </article>
    );
  }

  return (
    <article class={`work-page work-item-page work-release-page${g === null ? " loading" : ""}`} aria-busy={g === null}>
      <div class="work-release-grid">
        <div class="work-page-bar">
          {/* The place (note 22): Releases / v0.42.0, Releases a link to the list as it was. On a 390 px page: ‹ Releases. */}
          <nav class="work-place" aria-label="Place">
            <a href={routeHash({ nav: "work", section: "release" })} title="All releases"
              onClick={(e) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); go({ nav: "work", section: "release" }); }}>
              <Icon name="chevron-left" class="back" />{workKindTitle.release}</a>
            <span class="sep" aria-hidden="true">/</span>
            <span class="here">{tag}</span>
          </nav>
          <Stepper store={store} kind="release" at={ref} />
          {url && <a class="work-open-icon" href={url} target="_blank" rel="noopener noreferrer" title={openOn} aria-label={openOn}><OpenGlyph /></a>}
          <RefreshButton busy={reading.value || list.loading.value} onClick={refresh} />
        </div>
        <header class="work-page-head">
          <div class="work-title-line">
            <h2><span class="work-title">{row?.title ?? tag}</span>{isLatest && <> <ReleaseChip /></>}</h2>
          </div>
          {/* The state line (note 23): the box glyph, released 2 h ago · 23 pull requests · v0.41.0…v0.42.0, the range a
              link to the forge's compare page; then Open on GitHub. */}
          <p class="work-page-byline small">
            <ReleaseGlyph size={14} />
            <span class="quiet">
              {words.wide && <><span class="wide-line">{words.wide}</span><span class="short-line">{words.short}</span></>}
              {beforeTag && <>{words.wide && " · "}{compare
                ? <a class="work-release-range" href={compare} target="_blank" rel="noopener noreferrer" title="Compare on the forge">{rangeWords(beforeTag, tag)}</a>
                : <span class="work-release-range">{rangeWords(beforeTag, tag)}</span>}</>}
            </span>
            {url && <a class="work-open-on" href={url} target="_blank" rel="noopener noreferrer"><OpenGlyph />{openOn}</a>}
          </p>
        </header>
        {problem.value && <div class="work-problem"><ErrorStrip lines={[problem.value]} retry={() => { asked.value++; }} /></div>}
        {/* The notes' box (note 24). Agents reads no notes yet (#4426): the box says where they are. */}
        <section class="work-release-notes" aria-label="Release notes">
          <h3>Release notes</h3>
          <p class="quiet small">{notesElsewhere(ref)} {url && <a href={url} target="_blank" rel="noopener noreferrer">{openOn}</a>}</p>
        </section>
        {/* The side panel (notes 26, 28 and 29): a column over 900 px; rows under the notes under it. */}
        <aside class="work-side people" aria-label="Details">
          <SideSection title="Tag"><span class="work-release-tag"><TagGlyph />{tag}</span></SideSection>
          <SideSection title="Compared with">
            {before && beforeTag
              ? <a class="work-release-tag" href={routeHash({ nav: "work", section: "release", item: before.node.ref })} title="The release before this one"
                  onClick={(e) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); go({ nav: "work", section: "release", item: before.node.ref }); }}>
                  {beforeTag}</a>
              : <span class="quiet">None</span>}
          </SideSection>
          <SideSection title="Pipeline">
            {g === null ? <span class="bar" />
              : stages.length === 0 ? <span class="quiet">{noPipeline}</span>
              : stages.map((s, i) => (
                <span key={i} class="work-release-stage"><span class="tick" role="img" aria-label="Done"><Icon name="check" /></span>
                  {s.url ? <a href={s.url} target="_blank" rel="noopener noreferrer">{s.words}</a> : <span>{s.words}</span>}</span>
              ))}
            {trends && <a href={routeHash({ nav: "reports", section: "value", item: "builds", query: trends })}
              title={buildsRunLinkHelp("release")}>Build trends ›</a>}
          </SideSection>
          <SideSection title="Lineage">
            {lineageLine ? <span class="work-release-figures">{lineageLine}</span> : <span class="quiet">No agent worked on it yet</span>}
            {runtimes && <span class="quiet small work-release-figures">{runtimes}</span>}
            {sessions.map((id) => <WorkSession key={id} store={store} id={id} />)}
          </SideSection>
        </aside>
        <div class="work-main">
          {/* Pull requests in this release (note 25); under 700 px a row that opens their list (note 43). */}
          <section class="work-release-pulls-section work-wide-only" aria-label="Pull requests in this release">
            <div class="work-release-pulls-head">
              <h3>Pull requests in this release{pulls && <> · {pulls.length}</>}</h3>
              {pullsFilters}
            </div>
            {pullRows}
          </section>
          <div class="work-narrow-only"><div class="work-files-row">
            <button type="button" disabled={pulls === undefined} aria-label={pulls ? pullsWords(pulls.length) : "Pull requests"}
              onClick={() => { pullsPage.value = true; }}>
              <StateIcon kind="pr" state="merged" size={14} />
              <span class="words">{pulls ? `Pull requests · ${pulls.length}` : "Pull requests"}</span>
              <Icon name="chevron-right" />
            </button>
          </div></div>
        </div>
      </div>
    </article>
  );
}

/** Tag's glyph: a tag. */
function TagGlyph() {
  return <svg class="work-release-glyph" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
    <path d="M2.5 2.5h5l6 6-5 5-6-6z" /><circle cx="5.5" cy="5.5" r="1" /></svg>;
}
