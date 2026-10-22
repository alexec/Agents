// Events ▸ Audit's words (#996, spec 736 US8), as AuditWords has them on the window and the
// Remote: who did what through the control plane, on which machine, and when.
import type { AuditActor, AuditEntry } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

/** AuditWords.dayChoices: how long entries may be kept. */
export const dayChoices = [30, 90, 180, 365];

/** AuditWords.who: "Local owner · MacBook Pro"; a bot's names the event that started it. */
export function who(actor: AuditActor): string {
  const parts = [actor.userName ?? "Someone"];
  if (actor.clientName) parts.push(actor.clientName);
  if (actor.event) parts.push(`for ${actor.event.kind}`);
  return parts.join(" · ");
}

/** AuditWords.place: "on box-1", or "on the control plane" for its own methods. */
export function place(entry: AuditEntry, hostName: (host: string) => string): string {
  return entry.host ? `on ${hostName(entry.host)}` : "on the control plane";
}

/** AuditWords.call: `agents/stop · A1`. */
export function call(entry: AuditEntry): string {
  return entry.target ? `${entry.method} · ${entry.target}` : entry.method;
}

/** AuditWords.kept: "Kept for 90 days". */
export function kept(days: number): string {
  return days === 1 ? "Kept for 1 day" : `Kept for ${days} days`;
}

/** AuditWords.choices: the choices, with the days set now when they are not one of them. */
export function choices(days: number): number[] {
  return [...new Set([...dayChoices, days])].sort((a, b) => a - b);
}

/** AuditWords.older: how many entries are older than `days`; null when the list leaves older ones out (#2067). */
export function older(list: { entries: AuditEntry[]; more: boolean }, days: number, now: Date = new Date()): number | null {
  if (list.more) return null;
  const cut = now.getTime() - days * 86_400_000;
  return list.entries.filter((e) => fromWireDate(e.at).getTime() < cut).length;
}

const daysWord = (n: number) => n === 1 ? "1 day" : `${n} days`;

/** AuditWords.shorterTitle: the question before a shorter time is saved (#2067). */
export function shorterTitle(days: number): string {
  return `Keep the audit for ${daysWord(days)}?`;
}

/**
 * AuditWords.shorterMessage: what a shorter time deletes, and how to keep it: the sweep waits a day.
 * Everyone's entries: while Whose names a person, the caller passes no count (#2192).
 */
export function shorterMessage(from: number, to: number, count: number | null): string {
  const n = count === null ? "" : count === 1 ? ", 1 entry now" : `, ${count} entries now`;
  return `Everyone's entries older than ${daysWord(to)} are deleted in a day (up to ${daysWord(from - to)} of them${n}). To keep them, choose ${from} days again before then.`;
}

/** AuditWords.empty. */
export const empty = "Nothing has been done through the control plane yet. Starting, stopping or deleting an agent, answering a card, changing a setting and approving something appear here, with who did it.";

/** AuditWords.days: entries cut into local days, newest first. */
export function days(entries: AuditEntry[]): { day: Date; entries: AuditEntry[] }[] {
  const out: { day: Date; entries: AuditEntry[] }[] = [];
  for (const entry of [...entries].sort((a, b) => b.at - a.at)) {
    const at = fromWireDate(entry.at);
    const day = new Date(at.getFullYear(), at.getMonth(), at.getDate());
    const last = out[out.length - 1];
    if (last && last.day.getTime() === day.getTime()) last.entries.push(entry);
    else out.push({ day, entries: [entry] });
  }
  return out;
}

/** AuditWords.exportName: `audit-2026-10-20.jsonl`. */
export function exportName(now: Date = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `audit-${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}.jsonl`;
}

// Console ▸ Audit (#1804, M8): the same entries, for one person or everyone, and as CSV for a
// spreadsheet (decision 4), made here from audit/export's JSON lines.

const csvField = (text: string) => /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;

/** audit/export's JSON lines as CSV, a row per entry, oldest first; a line that is not an entry is left out. */
export function auditCSV(lines: string, hostName: (host: string) => string): string {
  const header = ["at", "action", "method", "host", "hostName", "target", "user", "userName", "client", "clientName", "event"];
  const rows = [header.join(",")];
  for (const line of lines.split("\n")) {
    if (!line.trim()) continue;
    let entry: AuditEntry;
    try {
      entry = JSON.parse(line) as AuditEntry;
    } catch {
      continue;
    }
    if (typeof entry.at !== "number" || !entry.actor) continue;
    const a = entry.actor;
    rows.push([fromWireDate(entry.at).toISOString(), entry.action, entry.method, entry.host ?? "", entry.host ? hostName(entry.host) : "",
      entry.target ?? "", a.user, a.userName ?? "", a.client ?? "", a.clientName ?? "", a.event ? `${a.event.kind} ${a.event.id}` : ""]
      .map((f) => csvField(String(f))).join(","));
  }
  return rows.join("\n") + "\n";
}

/** `audit-2026-10-20.csv`. */
export function csvExportName(now: Date = new Date()): string {
  return exportName(now).replace(/\.jsonl$/, ".csv");
}
