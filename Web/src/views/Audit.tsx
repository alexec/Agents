// Events ▸ Audit (#996, spec 736 US8), as the window's and the Remote's AuditPane: who did what
// through the control plane, newest first in days. Read only. An admin also sets how long entries
// are kept and exports them as JSON lines; a member sees only their own.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { AuditList, PersonRow } from "../protocol/generated";
import { fromWireDate, toWireDate } from "../protocol/dates";
import { CallFailed } from "../wire/link";
import { clock } from "../model/rowLines";
import { auditCSV, call, csvExportName, dayChoices, days, empty, exportName, kept, place, who } from "../model/audit";

const page = 200;

function sentence(error: unknown): string {
  if (error instanceof CallFailed) {
    // A control plane before #996 does not know the audit.
    return error.code === -32601 ? "This control plane keeps no audit. Update it to see who did what." : error.message;
  }
  return "The control plane can’t be reached.";
}

function dayTitle(day: Date): string {
  const today = new Date();
  const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
  const same = (a: Date, b: Date) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  return same(day, today) ? "Today" : same(day, yesterday) ? "Yesterday" : day.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
}

/** Saves text as a file in the browser's downloads. */
function save(text: string, type: string, name: string) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
}

/** Events ▸ Audit, and Console ▸ Audit (#1804) with `people`: one person's entries or everyone's, and CSV. */
export function AuditPane({ store, hostName, people }: { store: Store; hostName: (host: string) => string; people?: readonly PersonRow[] }) {
  const list = useSignal<AuditList | null>(null);
  const problem = useSignal<string | null>(null);
  const user = useSignal("");
  const only = user.value ? { user: user.value } : {};
  const load = async () => {
    try {
      list.value = await store.link.call("audit/list", { limit: page, ...only });
      problem.value = null;
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  useEffect(() => { void load(); }, [user.value]);
  const older = async () => {
    const current = list.value;
    const last = current?.entries[current.entries.length - 1];
    if (!current || !last) return;
    try {
      const until = toWireDate(new Date(fromWireDate(last.at).getTime() - 1));
      const got = await store.link.call("audit/list", { until, limit: page, ...only });
      const seen = new Set(current.entries.map((e) => e.id));
      list.value = { ...current, entries: [...current.entries, ...got.entries.filter((e) => !seen.has(e.id))], more: got.more };
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  const setDays = async (n: number) => {
    try {
      await store.link.call("control/setAuditDays", { days: n });
      await load();
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  const exportAll = async (csv = false) => {
    try {
      const got = await store.link.call("audit/export", only);
      if (csv) save(auditCSV(got.lines, hostName), "text/csv", csvExportName());
      else save(got.lines, "application/jsonl", exportName());
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  const shown = list.value;
  return (
    <div class="audit-pane">
      {problem.value && <p class="hint">{problem.value}</p>}
      {!shown && !problem.value && <p class="hint">Loading…</p>}
      {shown && (
        <>
          <div class="event-head audit-head">
            {shown.admin ? (
              <>
                <select aria-label="How long the audit is kept" title="How long the control plane keeps who did what"
                  value={String(shown.days)} onChange={(e) => void setDays(Number((e.currentTarget as HTMLSelectElement).value))}>
                  {[...new Set([...dayChoices, shown.days])].sort((a, b) => a - b).map((n) => <option key={n} value={String(n)}>{kept(n)}</option>)}
                </select>
                {people && (
                  <select aria-label="Whose" value={user.value} onChange={(e) => { user.value = (e.currentTarget as HTMLSelectElement).value; }}>
                    <option value="">Everyone</option>
                    {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                  </select>
                )}
                {people && <button title="Save these entries as CSV" onClick={() => void exportAll(true)}>Export CSV</button>}
                <button title="Save every entry kept as JSON lines" onClick={() => void exportAll()}>{people ? "Export JSON lines" : "Export…"}</button>
              </>
            ) : <p class="quiet small">{kept(shown.days)}. You see what you did.</p>}
          </div>
          {shown.entries.length === 0 && <p class="hint">{empty}</p>}
          {days(shown.entries).map((day) => (
            <section key={day.day.getTime()}>
              <h3 class="event-day">{dayTitle(day.day)}</h3>
              <ul class="event-list audit-list">{day.entries.map((entry) => {
                const at = fromWireDate(entry.at);
                return <li key={entry.id}>
                  <time class="when" dateTime={at.toISOString()} title={at.toLocaleString()}>{clock(at)}</time>
                  <span class="body">
                    <span>{entry.action}</span>
                    <span class="quiet small">{who(entry.actor)} {place(entry, hostName)}</span>
                    <span class="quiet small event-name">{call(entry)}</span>
                  </span>
                </li>;
              })}</ul>
            </section>
          ))}
          {shown.more && <button class="link event-older" onClick={() => void older()}>Show older</button>}
        </>
      )}
    </div>
  );
}
