// Cost ▸ Reports (#1811), as the window's and the Remote's ReportsPane: usage, cost and time by
// person, project, machine and runtime, added up on the control plane from what each machine
// sends each hour. Cost ▸ Reports shows the caller's own machines (Me, #2071); Reports ▸ Spend
// has a scope, Me, a group or the organisation, and names it.
import { useEffect, useMemo } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { ReportFormat, ReportRange, ReportScope, ReportScopeOption, UsageReport } from "../protocol/generated";
import { CallFailed } from "../wire/link";
import { budgetWords, dimensionTitle, empty, exportName, groupNote, hiddenNote, line, meNote, rangeShort, rangeSpan, ranges,
  reportTotals, scopeKey, scopeNote, scopedDimensions, share, utcNote } from "../model/reports";
import type { ReportDimension, ReportGroup } from "../model/reports";
import type { Section } from "../model/console";

function sentence(error: unknown): string {
  if (error instanceof CallFailed) {
    // A control plane before #1811 keeps no reports.
    return error.code === -32601 ? "This control plane keeps no reports. Update it to see them." : error.message;
  }
  return "The control plane can’t be reached.";
}

/** With no `scope`, the Cost page's pane: the caller's own machines, an admin's too (#2071). */
export function ReportsPane({ store, runtimeName, scope }: { store: Store; runtimeName: (id: string) => string; scope?: ReportScope | undefined }) {
  const range = useSignal<ReportRange>("week");
  const by = useSignal<ReportDimension>("person");
  const report = useSignal<UsageReport | null>(null);
  const problem = useSignal<string | null>(null);
  const asked = { scope: scope ?? { kind: "me" as const } };
  const load = async () => {
    try {
      report.value = await store.link.call("reports/usage", { range: range.value, ...asked });
      problem.value = null;
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  useEffect(() => { report.value = null; void load(); }, [range.value, scope && scopeKey(scope)]);
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
  const shown = report.value?.range === range.value ? report.value : null;
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
        <div class="segmented" role="radiogroup" aria-label="Range" title={rangeSpan[range.value]}>
          {ranges.map((r) => (
            <button key={r} role="radio" aria-checked={range.value === r} class={range.value === r ? "on" : ""}
              onClick={() => { range.value = r; }}>{rangeShort[r]}</button>
          ))}
        </div>
        <span class="reports-export">
          <button title="Save the rows of this range as CSV" onClick={() => void exportRows("csv")}>Export CSV</button>
          <button title="Save the rows of this range as JSON lines" onClick={() => void exportRows("jsonl")}>Export JSON lines</button>
        </span>
      </div>
      <div class="segmented" role="radiogroup" aria-label="By">
        {ways.map((d) => (
          <button key={d} role="radio" aria-checked={way === d} class={way === d ? "on" : ""}
            onClick={() => { by.value = d; }}>{dimensionTitle[d]}</button>
        ))}
      </div>
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
          {shown.personsHidden && <p class="quiet small">{hiddenNote}</p>}
          {way === "group" && <p class="quiet small">{groupNote}</p>}
          <p class="quiet small">{scope ? `${scopeNote(scope, scope.group ? shown.groupNames?.[scope.group] : undefined)} ${utcNote}` : `${meNote} ${utcNote}`}</p>
        </>
      )}
    </div>
  );
}

/** A runtime's name, from the first host that knows it. */
function runtimeNameIn(store: Store) {
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
export function ReportsPage({ store, down }: { store: Store; section: Section; down: boolean }) {
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
  const list = scopes.value ?? [];
  const option = list.find((o) => scopeKey(o.scope) === picked.value) ?? list[0];
  return (
    <>
      {list.length > 1 && (
        <div class="segmented report-scopes" role="radiogroup" aria-label="Scope">
          {list.map((o) => {
            const k = scopeKey(o.scope);
            return (
              <button key={k} role="radio" aria-checked={option === o} class={option === o ? "on" : ""}
                onClick={() => { picked.value = k; }}>{o.name}</button>
            );
          })}
        </div>
      )}
      {scopes.value !== null && <ReportsPane store={store} runtimeName={runtimeNameIn(store)} scope={option?.scope} />}
    </>
  );
}
