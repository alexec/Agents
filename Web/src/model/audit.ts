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
