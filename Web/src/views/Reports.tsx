// Cost ▸ Reports (#1811), as the window's and the Remote's ReportsPane: usage, cost and time by
// person, project, folder, machine and runtime, added up on the control plane from what each machine
// sends each hour. Cost ▸ Reports shows the caller's own machines (Me, #2071); Reports ▸ Spend
// has a scope, Me, a group or the organisation, and names it.
import { useEffect, useMemo, useRef } from "preact/hooks";
import { signal, useSignal } from "@preact/signals";
import { go } from "../route";
import type { Store } from "../model/store";
import type { FeatureUsage, ReportFormat, ReportPage, ReportRange, ReportRow, ReportScope, ReportScopeOption, ReportValue, ReportValueRow, ReportView,
  UsageReport } from "../protocol/generated";
import { CallFailed } from "../wire/link";
import { adoption, adoptionLine, barCaption, adoptionNote, budgetWords, dimensionTitle, empty, exportName, groupNote, hiddenNote, line, meNote,
  memberNote, noOutcomes, noWorkflows, outcomeLine, outcomeTotals, outcomesNote, rangeSpan, ranges, reportTotals, runtimeLine,
  runtimesNote, sameScope, spendBarCaption, scopeKey, scopeNote, scopedDimensions, share, timeLine, timeNote, utcNote, waitingShare, weekTitle, workflowLine,
  workflowRows, workflowsNote, deleteViewWords, digestText, noCopy, noViews, noViewsHere, viewBy, viewWords, viewsNote } from "../model/reports";
import type { OutcomeGroup, OutcomeOrder, ReportDimension, ReportGroup } from "../model/reports";
import { featureLine, featureUnused, featuresNote, mergeFeatures, noFeatures } from "../model/features";
import { hostAnswers } from "../model/capabilities";
import { leadLine, noValue, noValueHere, nodeName, nodeUrl, rowLine, unlinkedLine, valueHeadline, valueNote, wasteLine } from "../model/value";
import type { Section } from "../model/console";
import { Choice } from "./Choice";

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
    if (!window.confirm(deleteViewWords(v.name))) return;
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

/** Reports ▸ Value (#2351): what the work cost and delivered, from the machines' lineage nodes:
 * cost per merged pull request, waste and lead time, then each issue and milestone, the most costly first. */
function ValuePane({ store, scope, initial }: { store: Store; scope: ReportScope | undefined; initial?: Initial | undefined }) {
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
  // An issue or a milestone on GitHub opens there, as the window's Link does.
  const row = (r: ReportValueRow) => {
    const url = nodeUrl(r.node);
    return (
      <li key={r.node.ref}>
        {url ? <a href={url} target="_blank" rel="noopener noreferrer">{nodeName(r.node)}</a> : <span>{nodeName(r.node)}</span>}
        <span class="quiet small">{rowLine(r)}</span>
      </li>
    );
  };
  const lead = shown && leadLine(shown);
  const unlinked = shown && unlinkedLine(shown);
  return (
    <div class="reports-pane">
      <div class="reports-head">
        <RangePicker range={range} />
        {scope && <SaveView store={store} page="value" scope={scope} range={range.value} />}
      </div>
      <p class="quiet small">{rangeSpan[range.value]}</p>
      {problem.value && <p class="hint">{problem.value}</p>}
      {!shown && !problem.value && <p class="hint">Loading…</p>}
      {shown && (shown.issues.length === 0 && shown.prsMerged + shown.prsClosed === 0 ? <p class="hint">{noValue}</p> : (
        <>
          <ul class="report-list">
            <li class="report-total"><span class="strong">{valueHeadline(shown)}</span><span class="quiet small">{wasteLine(shown)}</span></li>
            {lead && <li><span>{lead}</span></li>}
            {unlinked && <li><span class="quiet">{unlinked}</span></li>}
          </ul>
          {shown.issues.length > 0 && <h3>Issues</h3>}
          {shown.issues.length > 0 && <ul class="report-list">{shown.issues.map(row)}</ul>}
          {shown.milestones.length > 0 && <h3>Milestones</h3>}
          {shown.milestones.length > 0 && <ul class="report-list">{shown.milestones.map(row)}</ul>}
          {shown.limited && <p class="quiet small">The 100 most costly of each.</p>}
        </>
      ))}
      <p class="quiet small">{valueNote}</p>
      {scope && <p class="quiet small">{scopeNote(scope, undefined)}</p>}
    </div>
  );
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
        : section.id === "value" ? <ValuePane key={view?.id ?? ""} store={store} scope={option?.scope} initial={initial} />
        : section.id === "adoption" ? <AdoptionPane key={view?.id ?? ""} store={store} scope={option?.scope} initial={initial} />
        : <ReportsPane key={view?.id ?? ""} store={store} runtimeName={runtimeNameIn(store)} scope={option?.scope} seesMore={list.length > 1} initial={initial} />)}
    </>
  );
}
