// Cost ▸ Reports (#1811), as the window's and the Remote's ReportsPane: usage, cost and time by
// person, project, folder, machine and runtime, added up on the control plane from what each machine
// sends each hour. Cost ▸ Reports shows the caller's own machines (Me, #2071); Reports ▸ Spend
// has a scope, Me, a group or the organisation, and names it.
import { useEffect, useMemo, useRef } from "preact/hooks";
import { signal, useSignal } from "@preact/signals";
import { go, routeHash } from "../route";
import { hasPage } from "../model/work";
import type { Store } from "../model/store";
import type { FeatureUsage, LineageForecast, ReportDelivery, LineageForecastAssumes, LineageForecastWhatIfEffect, LineageNode, MachineRef, ReportFormat, ReportPage, ReportRange, ReportRow, ReportScope, ReportScopeOption, ReportValue, ReportValueRow, ReportView,
  UsageReport } from "../protocol/generated";
import { CallFailed } from "../wire/link";
import { adoption, adoptionLine, barCaption, adoptionNote, budgetWords, dimensionTitle, empty, exportName, groupNote, hiddenNote, line, meNote,
  memberNote, noOutcomes, noWorkflows, outcomeLine, outcomeTotals, outcomesNote, rangeSpan, ranges, reportTotals, runtimeLine,
  runtimesNote, sameScope, spendBarCaption, scopeKey, scopeNote, scopedDimensions, share, timeLine, timeNote, utcNote, waitingShare, weekTitle, workflowLine,
  workflowRows, workflowsNote, deleteViewWords, digestText, noCopy, noViews, noViewsHere, viewBy, viewWords, viewsNote } from "../model/reports";
import type { OutcomeGroup, OutcomeOrder, ReportDimension, ReportGroup } from "../model/reports";
import { featureLine, featureUnused, featuresNote, mergeFeatures, noFeatures } from "../model/features";
import { hostAnswers } from "../model/capabilities";
import {
  estimateCoverageLine, estimateErrorLine, estimateLandsAtLine, leadLine, noValue, noValueHere, nodeName, rowLine,
  unlinkedLine, valueHeadline, valueNote, wasteLine,
} from "../model/value";
import { assumesLine, burnLine, burnRuntime, forecastScoreLine, landsLine, laneOptions, loadedLine, mergeBurns, mixOptions, nextNote, noNext,
  noNextHere, noNextOffline, serviceLevelLine, spendLines, whatIfLines, whatIfNote, whatIfOf } from "../model/planning";
import { deliveryCards, deliveryNote, noDelivery, repoTitle, sparkPath } from "../model/delivery";
import { Capability } from "../protocol/capabilities.generated";
import type { Section } from "../model/console";
import { Choice } from "./Choice";
import { ask } from "./MessageKinds";

function sentence(error: unknown): string {
  if (error instanceof CallFailed) {
    // A control plane before #1811 keeps no reports.
    return error.code === -32601 ? "This control plane keeps no reports. Update it to see them." : error.message;
  }
  return "The control plane can’t be reached.";
}

/** The report of a range and scope, asked again when either changes, and the words of a call that failed.
 * A late answer to an earlier range or scope is dropped, and a report is shown only when it answers the
 * range and the scope on screen (#2201). */
function useReport(store: Store, range: ReportRange, scope: ReportScope | undefined) {
  const report = useSignal<UsageReport | null>(null);
  const problem = useSignal<string | null>(null);
  const asked = { range, scope: scope ?? { kind: "me" as const } };
  // The range and scope on screen now, for an answer that comes after they changed.
  const current = useRef(asked);
  current.current = asked;
  const load = async () => {
    const ask = asked;
    try {
      const got = await store.link.call("reports/usage", ask);
      if (ask.range !== current.current.range || !sameScope(ask.scope, current.current.scope)) return;
      report.value = got;
      problem.value = null;
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  useEffect(() => { report.value = null; void load(); }, [range, scope && scopeKey(scope)]);
  const shown = report.value?.range === range && sameScope(report.value.scope, asked.scope) ? report.value : null;
  return { report, problem, shown };
}

/** With no `scope`, the Cost page's pane: the caller's own machines, an admin's too (#2071).
 * `seesMore` says whether reports/scopes offers the caller more than Me; the Cost page's pane asks
 * it itself (#2200). */
export function ReportsPane({ store, runtimeName, scope, seesMore, initial }: { store: Store; runtimeName: (id: string) => string;
  scope?: ReportScope | undefined; seesMore?: boolean; initial?: Initial | undefined }) {
  const range = useSignal<ReportRange>(initial?.range ?? "week");
  const by = useSignal<ReportDimension>(initial?.by ?? "person");
  const { problem, shown } = useReport(store, range.value, scope);
  const offered = useSignal<boolean>(false);
  const asked = { scope: scope ?? { kind: "me" as const } };
  useEffect(() => {
    if (seesMore !== undefined) return;
    // A control plane before scopes offers Me only.
    void store.link.call("reports/scopes", {}).then((r) => { offered.value = r.scopes.length > 1; }, () => { offered.value = false; });
  }, [seesMore]);
  const more = seesMore ?? offered.value;
  const exportRows = async (format: ReportFormat) => {
    try {
      const got = await store.link.call("reports/export", { range: range.value, format, ...asked });
      const url = URL.createObjectURL(new Blob([got.text], { type: format === "csv" ? "text/csv" : "application/jsonl" }));
      const a = document.createElement("a");
      a.href = url;
      a.download = exportName(range.value, format);
      a.click();
      URL.revokeObjectURL(url);
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  const ways = scopedDimensions(shown);
  // A way the scope does not offer (a person, with nobody named) falls back to the first.
  const way = ways.includes(by.value) ? by.value : ways[0]!;
  // Added up once per report and way, not at each draw (#2057).
  const names = store.runtimes.value;
  const totals = useMemo(() => shown ? reportTotals(shown.rows, way, runtimeName, shown.groupNames ?? {}) : null, [shown, way, names]);
  const row = (g: ReportGroup, bar: number | null) => (
    <li key={g.id} class={bar === null ? "report-total" : ""}>
      <span class={bar === null ? "strong" : ""}>{g.name}</span>
      <span class="quiet small">{line(g)}</span>
      {bar !== null && <span class="report-bar" aria-hidden="true"><span style={{ width: `${Math.max(1, bar * 100)}%` }} /></span>}
    </li>
  );
  return (
    <div class="reports-pane">
      <div class="reports-head">
        <Choice label="Range" value={range.value} options={ranges.map((r) => [r, rangeSpan[r]] as const)} onPick={(r) => { range.value = r; }} />
        <span class="reports-export">
          <button title="Save the rows of this range as CSV" onClick={() => void exportRows("csv")}>Export CSV</button>
          <button title="Save the rows of this range as JSON lines" onClick={() => void exportRows("jsonl")}>Export JSON lines</button>
          {scope && <SaveView store={store} page="spend" scope={scope} range={range.value} by={way} />}
        </span>
      </div>
      <Choice label="By" value={way} options={ways.map((d) => [d, dimensionTitle[d]] as const)} onPick={(d) => { by.value = d; }} />
      <p class="quiet small">{rangeSpan[range.value]}</p>
      {scope && shown?.budgetUSD !== undefined && shown.monthSpentUSD !== undefined && <Budget spent={shown.monthSpentUSD} budget={shown.budgetUSD} />}
      {problem.value && <p class="hint">{problem.value}</p>}
      {!totals && !problem.value && <p class="hint">Loading…</p>}
      {totals && shown && (
        <>
          {totals.groups.length === 0 ? <p class="hint">{empty}</p> : (
            <ul class="report-list">
              {row(totals.total, null)}
              {totals.groups.map((g) => row(g, share(totals, g)))}
            </ul>
          )}
          {totals.groups.length > 0 && <p class="quiet small">{spendBarCaption}</p>}
          {shown.personsHidden && <p class="quiet small">{hiddenNote}</p>}
          {way === "group" && <p class="quiet small">{groupNote}</p>}
          <p class="quiet small">{`${note(shown, scope, more)} ${utcNote}`}</p>
        </>
      )}
    </div>
  );
}

/** Whose machines the report is of, named from the answer's scope (#2201); Reports ▸ Spend is
 * named only to someone it offers more than Me (#2200). */
function note(shown: UsageReport, scope: ReportScope | undefined, more: boolean): string {
  if (!scope) return meNote(more);
  const of = shown.scope ?? scope;
  if (of.kind === "me" && !more) return memberNote;
  return scopeNote(of, of.group ? shown.groupNames?.[of.group] : undefined);
}

type CountsKind = "outcomes" | "time" | "runtimes" | "workflows";

/** How each page of counts adds up, sorts, says and draws its groups. */
const countsPages: Record<CountsKind, { order: OutcomeOrder; by: ReportDimension; words: (g: OutcomeGroup) => string; note: string; caption: string;
  none: string; rows: (rows: readonly ReportRow[]) => readonly ReportRow[]; nothing: (t: OutcomeGroup) => boolean;
  bar: (g: OutcomeGroup, most: OutcomeGroup[]) => number }> = {
  outcomes: { order: "merged", by: "person", words: outcomeLine, note: outcomesNote, caption: barCaption.outcomes, none: noOutcomes, rows: (r) => r,
    nothing: (t) => t.sessions + t.opened === 0, bar: (g, all) => fraction(g.merged, Math.max(0, ...all.map((x) => x.merged))) },
  time: { order: "waiting", by: "person", words: timeLine, note: timeNote, caption: barCaption.time, none: empty, rows: (r) => r,
    nothing: (t) => t.workingSeconds + t.waitingSeconds === 0, bar: (g) => waitingShare(g) },
  runtimes: { order: "cost", by: "runtime", words: runtimeLine, note: runtimesNote, caption: barCaption.runtimes, none: empty, rows: (r) => r,
    nothing: (t) => t.turns + t.sessions === 0, bar: (g, all) => fraction(costOf(g), Math.max(0, ...all.map(costOf))) },
  workflows: { order: "failing", by: "workflow", words: workflowLine, note: workflowsNote, caption: barCaption.workflows, none: noWorkflows, rows: workflowRows,
    nothing: (t) => t.runs + t.turns === 0, bar: (g) => fraction(g.runFailures, g.runs) },
};

const fraction = (part: number, all: number) => all > 0 ? part / all : 0;
const costOf = (g: OutcomeGroup) => Object.values(g.cost)[0] ?? 0;

/** What a saved view opens a page with. */
interface Initial { range: ReportRange; by?: ReportDimension | undefined }

/** The saved view to open, set by Reports ▸ Saved Views and read by the page it names (#2019). */
const opened = signal<ReportView | null>(null);

/** Save View…: keeps the page's scope, range and way to add up under a name, for the caller (#2019). */
function SaveView({ store, page, scope, range, by }: { store: Store; page: ReportPage; scope: ReportScope; range: ReportRange;
  by?: ReportDimension }) {
  const naming = useSignal(false);
  const name = useSignal("");
  const said = useSignal<string | null>(null);
  const save = async () => {
    try {
      await store.link.call("reports/saveView", { id: "", name: name.value, page, scope, range, ...(by ? { by } : {}) });
      said.value = "Saved. It is in Reports ▸ Saved Views.";
      naming.value = false;
      name.value = "";
    } catch (error) {
      said.value = error instanceof CallFailed && error.code === -32601 ? noViewsHere : sentence(error);
    }
  };
  if (!naming.value) {
    return (
      <span class="reports-export">
        <button title="Keep this page’s scope, range and way to add up under a name" onClick={() => { naming.value = true; said.value = null; }}>Save View…</button>
        {said.value && <span class="quiet small">{said.value}</span>}
      </span>
    );
  }
  return (
    <form class="reports-export" onSubmit={(e) => { e.preventDefault(); void save(); }}>
      <input aria-label="View name" placeholder="Monday digest" maxLength={80} value={name.value} autoFocus
        onInput={(e) => { name.value = (e.target as HTMLInputElement).value; }} />
      <button type="submit" disabled={name.value.trim() === ""}>Save</button>
      <button type="button" onClick={() => { naming.value = false; }}>Cancel</button>
      {said.value && <span class="hint">{said.value}</span>}
    </form>
  );
}

/** Reports ▸ Saved Views (R8), #2019: the caller's saved views, each to open, copy as a digest or delete. */
function SavedPage({ store, scopes }: { store: Store; scopes: readonly ReportScopeOption[] }) {
  const views = useSignal<ReportView[] | null>(null);
  const problem = useSignal<string | null>(null);
  const copied = useSignal<string | null>(null);
  const failed = (error: unknown) => {
    problem.value = error instanceof CallFailed && error.code === -32601 ? noViewsHere : sentence(error);
  };
  useEffect(() => {
    store.link.call("reports/views", {}).then((r) => { views.value = r.views; }, (e: unknown) => { views.value = []; failed(e); });
  }, []);
  const scopeName = (v: ReportView) => scopes.find((o) => scopeKey(o.scope) === scopeKey(v.scope))?.name ?? "A scope you no longer see";
  const open = (v: ReportView) => {
    opened.value = v;
    go({ nav: "reports", section: v.page });
  };
  const digest = async (v: ReportView) => {
    const text = store.link.call("reports/usage", { range: v.range, scope: v.scope }).then((r) => digestText(v, scopeName(v), r));
    try {
      // Safari refuses a write that comes after an await (#2263): give the clipboard the promise of the text at once.
      if (typeof ClipboardItem !== "undefined" && navigator.clipboard.write) {
        await navigator.clipboard.write([new ClipboardItem({ "text/plain": text.then((t) => new Blob([t], { type: "text/plain" })) })]);
      } else {
        await navigator.clipboard.writeText(await text);
      }
      copied.value = v.id;
    } catch {
      // A failed call says why; a refused write is not the control plane's fault.
      const asked = await text.then(() => null, (e: unknown) => e ?? new Error());
      if (asked) failed(asked);
      else problem.value = noCopy;
    }
  };
  const remove = async (v: ReportView) => {
    if (!await ask(deleteViewWords(v.name))) return;
    try {
      views.value = (await store.link.call("reports/deleteView", { id: v.id })).views;
    } catch (error) {
      failed(error);
    }
  };
  return (
    <div class="reports-pane">
      {problem.value && <p class="hint">{problem.value}</p>}
      {views.value === null && !problem.value && <p class="hint">Loading…</p>}
      {views.value?.length === 0 && !problem.value && <p class="hint">{noViews}</p>}
      {views.value && views.value.length > 0 && (
        <ul class="report-list">
          {views.value.map((v) => (
            <li key={v.id}>
              <span class="strong">{v.name}</span>
              <span class="quiet small">{viewWords(v, scopeName(v))}</span>
              <span class="reports-export">
                <button onClick={() => open(v)}>Open</button>
                <button title="Copy this view’s numbers as text" onClick={() => void digest(v)}>{copied.value === v.id ? "Copied" : "Copy Digest"}</button>
                <button class="destructive" onClick={() => void remove(v)}>Delete…</button>
              </span>
            </li>
          ))}
        </ul>
      )}
      <p class="quiet small">{viewsNote}</p>
    </div>
  );
}

function RangePicker({ range, from = 0 }: { range: { value: ReportRange }; from?: number }) {
  return (
    <Choice label="Range" value={range.value} options={ranges.slice(from).map((r) => [r, rangeSpan[r]] as const)} onPick={(r) => { range.value = r; }} />
  );
}

/** Reports ▸ Outcomes (R2), Time (R3), Runtimes (R4) and Workflows (R6), #2019: what the agents did,
 * from the counts each machine adds to its rows. */
function CountsPane({ store, runtimeName, scope, kind, initial }: { store: Store; runtimeName: (id: string) => string; scope: ReportScope | undefined;
  kind: CountsKind; initial?: Initial | undefined }) {
  const page = countsPages[kind];
  const range = useSignal<ReportRange>(initial?.range ?? "week");
  const by = useSignal<ReportDimension>(initial?.by ?? page.by);
  const { problem, shown } = useReport(store, range.value, scope);
  const scoped = scopedDimensions(shown);
  const ways = kind === "workflows" ? ["workflow" as const, ...scoped] : scoped;
  const way = ways.includes(by.value) ? by.value : ways[0]!;
  const names = store.runtimes.value;
  const totals = useMemo(() => shown ? outcomeTotals(page.rows(shown.rows), way, page.order, runtimeName, shown.groupNames ?? {}) : null,
    [shown, way, names, kind]);
  const row = (g: OutcomeGroup, total: boolean) => (
    <li key={g.id} class={total ? "report-total" : ""}>
      <span class={total ? "strong" : ""}>{g.name}</span>
      <span class="quiet small">{page.words(g)}</span>
      {!total && totals && <span class="report-bar" aria-hidden="true"><span style={{ width: `${Math.max(1, page.bar(g, totals.groups) * 100)}%` }} /></span>}
    </li>
  );
  return (
    <div class="reports-pane">
      <div class="reports-head">
        <RangePicker range={range} />
        {scope && <SaveView store={store} page={kind} scope={scope} range={range.value} by={way} />}
      </div>
      <Choice label="By" value={way} options={ways.map((d) => [d, dimensionTitle[d]] as const)} onPick={(d) => { by.value = d; }} />
      <p class="quiet small">{rangeSpan[range.value]}</p>
      {problem.value && <p class="hint">{problem.value}</p>}
      {!totals && !problem.value && <p class="hint">Loading…</p>}
      {totals && shown && (
        <>
          {page.nothing(totals.total) ? <p class="hint">{page.none}</p> : (
            <ul class="report-list">
              {row(totals.total, true)}
              {totals.groups.map((g) => row(g, false))}
            </ul>
          )}
          {!page.nothing(totals.total) && <p class="quiet small">{page.caption}</p>}
          <p class="quiet small">{page.note}</p>
          {shown.personsHidden && <p class="quiet small">{hiddenNote}</p>}
          {way === "group" && <p class="quiet small">{groupNote}</p>}
          {scope && <p class="quiet small">{`${scopeNote(scope, scope.group ? shown.groupNames?.[scope.group] : undefined)} ${utcNote}`}</p>}
        </>
      )}
    </div>
  );
}

/** Reports ▸ Adoption (R5), #2019: each week's active people, sessions, runtimes and workflows in use. */
function AdoptionPane({ store, scope, initial }: { store: Store; scope: ReportScope | undefined; initial?: Initial | undefined }) {
  const range = useSignal<ReportRange>(initial?.range ?? "month");
  const { problem, shown } = useReport(store, range.value, scope);
  const weeks = useMemo(() => shown ? adoption(shown.rows, shown.personsHidden === true) : null, [shown]);
  return (
    <div class="reports-pane">
      <div class="reports-head">
        <RangePicker range={range} from={1} />
        {scope && <SaveView store={store} page="adoption" scope={scope} range={range.value} />}
      </div>
      <p class="quiet small">{rangeSpan[range.value]}</p>
      {problem.value && <p class="hint">{problem.value}</p>}
      {!weeks && !problem.value && <p class="hint">Loading…</p>}
      {weeks && shown && (
        <>
          {weeks.length === 0 ? <p class="hint">{empty}</p> : (
            <ul class="report-list">
              {weeks.map((w) => (
                <li key={w.week}>
                  <span>{weekTitle(w.week)}</span>
                  <span class="quiet small">{adoptionLine(w)}</span>
                </li>
              ))}
            </ul>
          )}
          <p class="quiet small">{adoptionNote}</p>
          {shown.personsHidden && <p class="quiet small">{hiddenNote}</p>}
          {scope && <p class="quiet small">{scopeNote(scope, scope.group ? shown.groupNames?.[scope.group] : undefined)}</p>}
        </>
      )}
    </div>
  );
}

/** Reports ▸ Planning (#4528; Value before, #2351): what the work cost and delivered, from the machines' lineage
 * nodes: cost per merged pull request, all in beside it, waste and lead time; then what comes next, from
 * lineage/forecast (#4526): the burn against each allowance, the spend at this pace, the service levels and when each
 * open epic lands; then how the estimates and the forecasts scored; then each issue and release (#3023), the most
 * costly first. */
function PlanningPane({ store, scope, initial }: { store: Store; scope: ReportScope | undefined; initial?: Initial | undefined }) {
  const range = useSignal<ReportRange>(initial?.range ?? "month");
  const value = useSignal<ReportValue | null>(null);
  const problem = useSignal<string | null>(null);
  const asked = { range: range.value, scope: scope ?? { kind: "me" as const } };
  const current = useRef(asked);
  current.current = asked;
  useEffect(() => {
    value.value = null;
    const ask = asked;
    store.link.call("reports/value", ask).then((got) => {
      if (ask.range !== current.current.range || !sameScope(ask.scope, current.current.scope)) return;
      value.value = got;
      problem.value = null;
    }, (error: unknown) => {
      problem.value = error instanceof CallFailed && error.code === -32601 ? noValueHere : sentence(error);
    });
  }, [range.value, scope && scopeKey(scope)]);
  const shown = value.value?.range === range.value && sameScope(value.value.scope, asked.scope) ? value.value : null;
  // An issue or a release opens its Work page (#3088), its lineage and its forge's link there.
  const row = (r: ReportValueRow) => {
    const n = r.node;
    return (
      <li key={n.ref}>
        {hasPage(n) ? <a href={routeHash({ nav: "work", section: n.kind, item: n.ref })}>{nodeName(n)}</a> : <span>{nodeName(n)}</span>}
        <span class="quiet small">{rowLine(r)}</span>
      </li>
    );
  };
  const lead = shown && leadLine(shown);
  const loaded = shown && loadedLine(shown);
  const unlinked = shown && unlinkedLine(shown);
  const estimates = shown && estimateErrorLine(shown);
  const coverage = shown && estimateCoverageLine(shown);
  const landsAt = shown && estimateLandsAtLine(shown);
  const forecasts = shown && forecastScoreLine(shown.forecastScore);
  const empty = shown && shown.issues.length === 0 && shown.prsMerged + shown.prsClosed === 0;
  return (
    <div class="reports-pane">
      <div class="reports-head">
        <RangePicker range={range} />
        {scope && <SaveView store={store} page="value" scope={scope} range={range.value} />}
      </div>
      <p class="quiet small">{rangeSpan[range.value]}</p>
      {problem.value && <p class="hint">{problem.value}</p>}
      {!shown && !problem.value && <p class="hint">Loading…</p>}
      {empty && <p class="hint">{noValue}</p>}
      {shown && !empty && (
        <ul class="report-list">
          <li class="report-total"><span class="strong">{valueHeadline(shown)}</span><span class="quiet small">{wasteLine(shown)}</span></li>
          {loaded && <li><span>{loaded}</span></li>}
          {lead && <li><span>{lead}</span></li>}
          {unlinked && <li><span class="quiet">{unlinked}</span></li>}
        </ul>
      )}
      {shown?.delivery && <DeliveryPart delivery={shown.delivery} />}
      <NextPart store={store} epics={shown?.openEpics ?? []} />
      {(estimates || forecasts) && <h3>How the estimates and forecasts scored</h3>}
      {(estimates || forecasts) && (
        <ul class="report-list">
          {forecasts && <li><span>{forecasts}</span></li>}
          {estimates && <li><span>{estimates}</span></li>}
          {coverage && <li><span class="quiet small">{coverage}</span></li>}
          {landsAt && <li><span class="quiet small">{landsAt}</span></li>}
        </ul>
      )}
      {shown && !empty && shown.issues.length > 0 && <h3>Issues</h3>}
      {shown && !empty && shown.issues.length > 0 && <ul class="report-list">{shown.issues.map(row)}</ul>}
      {shown && !empty && shown.releases.length > 0 && <h3>Releases</h3>}
      {shown && !empty && shown.releases.length > 0 && <ul class="report-list">{shown.releases.map(row)}</ul>}
      {shown?.limited && <p class="quiet small">The 100 most costly of each.</p>}
      <p class="quiet small">{valueNote}</p>
      {scope && <p class="quiet small">{scopeNote(scope, undefined)}</p>}
    </div>
  );
}

/** Reports ▸ Planning's Delivery row (#4555): a card a figure for each repo the scope merged most in, with its
 * 4-week figure, a line of its weeks and DORA 2024's band where one exists. A repo's name heads its row only when
 * there are more than one. */
function DeliveryPart({ delivery }: { delivery: readonly ReportDelivery[] }) {
  return (
    <>
      <h3>Delivery</h3>
      {delivery.length === 0 && <p class="hint">{noDelivery}</p>}
      {delivery.map((d) => (
        <section key={d.repo} class="delivery-repo">
          {delivery.length > 1 && <h4>{repoTitle(d.repo)}</h4>}
          <ul class="delivery-cards">
            {deliveryCards(d.figures).map((c) => {
              const path = sparkPath(c.weeks, 96, 20);
              return (
                <li key={c.key} class="delivery-card">
                  <span class="quiet small">{c.title}</span>
                  <span class="delivery-value strong">{c.value}</span>
                  {path ? (
                    <svg class="delivery-spark" viewBox="-1 -1 98 22" width="98" height="22" role="img" aria-label={`${c.title}, the last 4 weeks`}>
                      <path d={path} />
                    </svg>
                  ) : <span class="delivery-spark" aria-hidden="true" />}
                  <span class="quiet small">{c.detail}</span>
                  {c.band && <span class="delivery-band">{`DORA: ${c.band}`}</span>}
                </li>
              );
            })}
          </ul>
        </section>
      ))}
      {delivery.length > 0 && <p class="quiet small">{deliveryNote}</p>}
    </>
  );
}

/** What comes next on Reports ▸ Planning (#4528), from lineage/forecast on the person's own machines: each
 * allowance's burn, the newest reading of it from any machine; the spend and the service levels of the machine with
 * the most landings (this Mac first); and when each open epic lands, from that machine. What if (#4531): a lane limit
 * and a runtime mix, asked of every machine, move the figures; the mix to pick from is the main machine's. */
function NextPart({ store, epics }: { store: Store; epics: readonly LineageNode[] }) {
  const answering = store.hosts.value.filter((h) => hostAnswers(h.state));
  const hosts = answering.filter((h) => store.has(h.id, Capability.lineageForecast1)).map((h) => h.id);
  const all = useSignal<{ host: MachineRef; forecast: LineageForecast }[] | null>(null);
  // Each open epic's forecast, or why it could not be made.
  const lands = useSignal<Record<string, LineageForecast | string>>({});
  const names = runtimeNameIn(store);
  const epicKey = epics.map((e) => e.ref).join(" ");
  // The what-if's picks: "" is as the window ran. assumes is what the window ran with, from the first answer.
  const lanes = useSignal("");
  const mix = useSignal<Record<string, string>>({});
  const assumes = useSignal<LineageForecastAssumes | undefined>(undefined);
  const whatIf = whatIfOf(lanes.value, mix.value, assumes.value);
  const whatIfKey = JSON.stringify(whatIf ?? null);
  useEffect(() => {
    let live = true;
    // A new what-if keeps the figures on screen until its answer comes; the epics say they are forecasting.
    lands.value = {};
    const ask = whatIf ? { whatIf } : {};
    void Promise.all(hosts.map((host) => store.link.call("lineage/forecast", ask, host).then((forecast) => ({ host, forecast }), () => null)))
      .then((got) => {
        if (!live) return;
        const answers = got.filter((g): g is { host: MachineRef; forecast: LineageForecast } => g !== null);
        all.value = answers;
        const main = mainForecast(answers, store.macHostID.value);
        if (!main) return;
        if (!assumes.value) assumes.value = main.forecast.assumes;
        for (const node of epics) {
          void store.link.call("lineage/forecast", { node, ...ask }, main.host).then((f) => {
            if (live) lands.value = { ...lands.value, [node.ref]: f };
          }, (error: unknown) => {
            if (live) lands.value = { ...lands.value, [node.ref]: sentence(error) };
          });
        }
      });
    return () => { live = false; };
  }, [hosts.join(" "), epicKey, whatIfKey]);
  if (hosts.length === 0) return <><h3>What comes next</h3><p class="hint">{answering.length === 0 ? noNextOffline : noNextHere}</p></>;
  if (all.value === null) return <><h3>What comes next</h3><p class="hint">Loading…</p></>;
  const main = mainForecast(all.value, store.macHostID.value);
  const burns = mergeBurns(all.value.map((a) => a.forecast));
  const spend = main ? spendLines(main.forecast) : [];
  const levels = main?.forecast.serviceLevels ?? [];
  return (
    <>
      <h3>What comes next</h3>
      {burns.length === 0 && spend.length === 0 && levels.length === 0 && <p class="hint">{noNext}</p>}
      {(burns.length > 0 || spend.length > 0) && (
        <ul class="report-list">
          {burns.map((b) => <li key={b.credentialKey}><span>{burnLine(b, names(burnRuntime(b)))}</span></li>)}
          {spend.map((line) => <li key={line}><span class="quiet">{line}</span></li>)}
        </ul>
      )}
      {levels.length > 0 && <h4>Service levels</h4>}
      {levels.length > 0 && <ul class="report-list">{levels.map((l) => <li key={l.level}><span>{serviceLevelLine(l)}</span></li>)}</ul>}
      {epics.length > 0 && <h4>Open epics</h4>}
      {epics.length > 0 && (
        <ul class="report-list">
          {epics.map((n) => (
            <li key={n.ref}>
              <a href={routeHash({ nav: "work", section: n.kind, item: n.ref })}>{nodeName(n)}</a>
              <span class="quiet small">{landsWords(lands.value[n.ref])}</span>
            </li>
          ))}
        </ul>
      )}
      {assumes.value && main && (
        <WhatIfPart assumes={assumes.value} windowDays={main.forecast.windowDays} effect={main.forecast.whatIf} names={names}
          lanes={lanes.value} mix={mix.value} onLanes={(v) => { lanes.value = v; }} onMix={(runtime, v) => { mix.value = { ...mix.value, [runtime]: v }; }} />
      )}
      <p class="quiet small">{nextNote}</p>
    </>
  );
}

/** What if (#4531): the lane limit and each runtime's share, what the window ran with, and what the picks moved. */
function WhatIfPart({ assumes, windowDays, effect, names, lanes, mix, onLanes, onMix }: {
  assumes: LineageForecastAssumes; windowDays: number; effect: LineageForecastWhatIfEffect | undefined; names: (runtime: string) => string;
  lanes: string; mix: Record<string, string>; onLanes: (v: string) => void; onMix: (runtime: string, v: string) => void;
}) {
  return (
    <>
      <h4>What if</h4>
      <div class="report-whatif">
        <Choice label="Lanes" value={lanes} options={laneOptions(assumes)} onPick={onLanes} />
        {assumes.runtimes.length > 1 && assumes.runtimes.map((r) => (
          <Choice key={r.runtime} label={names(r.runtime)} value={mix[r.runtime] ?? ""} onPick={(v) => onMix(r.runtime, v)}
            options={mixOptions(r.share, effect?.mix && !mix[r.runtime] ? effect.mix[r.runtime] ?? 0 : undefined)} />
        ))}
      </div>
      <ul class="report-list">
        <li><span class="quiet small">{assumesLine(assumes, windowDays, names)}</span></li>
        {effect && whatIfLines(effect, assumes).map((line) => <li key={line}><span>{line}</span></li>)}
      </ul>
      {effect && <p class="quiet small">{whatIfNote}</p>}
    </>
  );
}

const landsWords = (f: LineageForecast | string | undefined) => f === undefined ? "Forecasting…" : typeof f === "string" ? f : landsLine(f);

/** The machine whose forecast the page shows: this Mac when it has landings, else the one with the most. */
function mainForecast<T extends { host: MachineRef; forecast: LineageForecast }>(answers: readonly T[], mac: string | null | undefined): T | undefined {
  const here = answers.find((a) => a.host === mac && a.forecast.landings > 0);
  return here ?? [...answers].sort((a, b) => b.forecast.landings - a.forecast.landings)[0];
}

/** Reports ▸ Features (#2165), as the window's: which methods the clients and agents called on the
 * person's own machines, from each machine's counts added up, the least used first. The counts stay
 * on the machines, so it has no scope. */
function FeaturesPane({ store }: { store: Store }) {
  const usage = useSignal<FeatureUsage | null>(null);
  const hosts = store.hosts.value.filter((h) => hostAnswers(h.state)).map((h) => h.id);
  useEffect(() => {
    usage.value = null;
    void Promise.all(hosts.map((host) => store.link.call("reports/features", {}, host).catch(() => null))).then((all) => {
      usage.value = mergeFeatures(all.filter((u): u is FeatureUsage => u !== null));
    });
  }, [hosts.join(" ")]);
  const shown = usage.value;
  return (
    <div class="reports-pane">
      {shown && <p class="quiet small">{featuresNote(shown)}</p>}
      {!shown && <p class="hint">Loading…</p>}
      {shown && (shown.features.length === 0 ? <p class="hint">{noFeatures}</p> : (
        <ul class="report-list">
          {shown.features.map((f) => (
            <li key={f.method}>
              <span><code>{f.method}</code>{f.quarter === 0 && <span class="report-unused small"> {featureUnused}</span>}</span>
              <span class="quiet small">{featureLine(f, shown.days)}</span>
            </li>
          ))}
        </ul>
      ))}
    </div>
  );
}

/** A runtime's name, from the first host that knows it. */
export function runtimeNameIn(store: Store) {
  return (id: string) => Object.values(store.runtimes.value).map((list) => list.find((s) => s.runtime.id === id)?.runtime.name)
    .find((name) => name) || id;
}

/** This month's spend against the scope's budget, with a forecast to the month's end (#1804). The
 * control plane adds the month up (#2057). */
function Budget({ spent, budget }: { spent: number; budget: number }) {
  const used = Math.min(1, budget > 0 ? spent / budget : 0);
  return (
    <div class="report-budget">
      <span class="strong">{budgetWords(spent, budget)}</span>
      <span class={`report-bar${used >= 1 ? " over" : ""}`} aria-hidden="true"><span style={{ width: `${Math.max(1, used * 100)}%` }} /></span>
    </div>
  );
}

/** A page of Reports (#1804), the control plane's app beside the Workspace and the Console: Me, a
 * group the person leads (every group for an admin) or the organisation, as reports/scopes offers them. */
export function ReportsPage({ store, section, down }: { store: Store; section: Section; down: boolean }) {
  const scopes = useSignal<ReportScopeOption[] | null>(null);
  const picked = useSignal<string>("me");
  // The runtimes' names, from each machine that answers.
  useEffect(() => { if (!down) for (const host of store.hosts.value) void store.loadRuntimes(host.id); }, [down]);
  const changes = store.peopleChanges.value;
  useEffect(() => {
    if (down) return;
    // A control plane before scopes: Me, as Cost ▸ Reports has it.
    void store.link.call("reports/scopes", {}).then((r) => { scopes.value = r.scopes; }, () => { scopes.value = []; });
  }, [down, changes]);
  // A saved view opens its page on its scope, range and way (#2019); the next page opens as before.
  const view = opened.value && opened.value.page === section.id ? opened.value : null;
  useEffect(() => {
    if (view) picked.value = scopeKey(view.scope);
    else if (opened.value && opened.value.page !== section.id) opened.value = null;
  }, [view?.id, section.id]);
  const initial = view ? { range: view.range, by: viewBy(view) } : undefined;
  const list = scopes.value ?? [];
  const option = list.find((o) => scopeKey(o.scope) === picked.value) ?? list[0];
  return (
    <>
      {list.length > 1 && section.id !== "saved" && section.id !== "features" && (
        <Choice label="Scope" class="report-scopes" value={option ? scopeKey(option.scope) : picked.value}
          options={list.map((o) => [scopeKey(o.scope), o.name] as const)} onPick={(k) => { picked.value = k; }} />
      )}
      {section.id === "features" ? <FeaturesPane store={store} />
        : scopes.value !== null && (section.id === "saved" ? <SavedPage store={store} scopes={list} />
        : section.id in countsPages
        ? <CountsPane key={`${section.id}:${view?.id ?? ""}`} store={store} runtimeName={runtimeNameIn(store)} scope={option?.scope}
          kind={section.id as CountsKind} initial={initial} />
        : section.id === "value" ? <PlanningPane key={view?.id ?? ""} store={store} scope={option?.scope} initial={initial} />
        : section.id === "adoption" ? <AdoptionPane key={view?.id ?? ""} store={store} scope={option?.scope} initial={initial} />
        : <ReportsPane key={view?.id ?? ""} store={store} runtimeName={runtimeNameIn(store)} scope={option?.scope} seesMore={list.length > 1} initial={initial} />)}
    </>
  );
}
