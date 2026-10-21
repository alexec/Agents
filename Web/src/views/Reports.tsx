// Cost ▸ Reports (#1811), as the window's and the Remote's ReportsPane: usage, cost and time by
// person, project, machine and runtime, added up on the control plane from what each machine
// sends each hour. An admin sees every person's machines; a member their own.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { ReportFormat, ReportRange, UsageReport } from "../protocol/generated";
import { CallFailed } from "../wire/link";
import { dimensionTitle, dimensions, empty, exportName, line, memberNote, rangeShort, rangeSpan, ranges, reportTotals, share, utcNote } from "../model/reports";
import type { ReportDimension, ReportGroup } from "../model/reports";
import type { Section } from "../model/console";

function sentence(error: unknown): string {
  if (error instanceof CallFailed) {
    // A control plane before #1811 keeps no reports.
    return error.code === -32601 ? "This control plane keeps no reports. Update it to see them." : error.message;
  }
  return "The control plane can’t be reached.";
}

export function ReportsPane({ store, runtimeName }: { store: Store; runtimeName: (id: string) => string }) {
  const range = useSignal<ReportRange>("week");
  const by = useSignal<ReportDimension>("person");
  const report = useSignal<UsageReport | null>(null);
  const problem = useSignal<string | null>(null);
  const load = async () => {
    try {
      report.value = await store.link.call("reports/usage", { range: range.value });
      problem.value = null;
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  useEffect(() => { void load(); }, [range.value]);
  const exportRows = async (format: ReportFormat) => {
    try {
      const got = await store.link.call("reports/export", { range: range.value, format });
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
  const totals = shown ? reportTotals(shown.rows, by.value, runtimeName) : null;
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
        {dimensions.map((d) => (
          <button key={d} role="radio" aria-checked={by.value === d} class={by.value === d ? "on" : ""}
            onClick={() => { by.value = d; }}>{dimensionTitle[d]}</button>
        ))}
      </div>
      <p class="quiet small">{rangeSpan[range.value]}</p>
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
          <p class="quiet small">{shown.admin ? utcNote : `${memberNote} ${utcNote}`}</p>
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

/** A page of Reports (#1804), the control plane's app beside the Workspace and the Console. */
export function ReportsPage({ store, down }: { store: Store; section: Section; down: boolean }) {
  // The runtimes' names, from each machine that answers.
  useEffect(() => { if (!down) for (const host of store.hosts.value) void store.loadRuntimes(host.id); }, [down]);
  return <ReportsPane store={store} runtimeName={runtimeNameIn(store)} />;
}
