// What a secret's row tells you (#4159, specs/secret-info/wireframe.md sections 1, 2 and 4): its last 4, when it
// was added, when it was last used, and that it is not backed up. The words are SecretInfoWords' in
// Packages/AgentsKit/Sources/AgentsKitCore/Model/SecretInfoWords.swift.
import type { ControlMachine, SecretLastOp, SessionSecret, UserSecretRow } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { months, parts as dateParts } from "./activity";
import { machines } from "./userScope";

/** `••••ab12` at the end of the name line; `••••` when the row has no hint. */
export function hint(value: string | undefined): string {
  return "••••" + (value ?? "");
}

/** "just now", "5 min ago", "2 h ago", "27 d ago". */
export function age(date: Date, now: Date = new Date()): string {
  const seconds = Math.max(0, (now.getTime() - date.getTime()) / 1000);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} h ago`;
  return `${Math.floor(seconds / 86_400)} d ago`;
}

/** The date and time a hover gives: "12 Oct 2026, 09:14", where the reader is. */
export function stamp(date: Date, timeZone?: string): string {
  const p = dateParts(date, timeZone);
  const two = (n: number) => String(n).padStart(2, "0");
  return `${p.day} ${months[p.month - 1]} ${p.year}, ${two(p.hour)}:${two(p.minute)}`;
}

/** A part of the line, with what its hover (`title`) gives. */
export interface Part {
  text: string;
  help?: string;
}

/** "Added 27 d ago", or "Replaced 2 d ago" after a Replace…, which keeps `created`. A row set before `created` was
 * kept says "Set 3 d ago". */
export function setPart(created: Date | null, updated: Date | null, now = new Date(), timeZone?: string): Part | null {
  const last = updated ?? created;
  if (!last) return null;
  if (!created) return { text: `Set ${age(last, now)}`, help: `Set ${stamp(last, timeZone)}` };
  if (last.getTime() - created.getTime() >= 1000) {
    return { text: `Replaced ${age(last, now)}`, help: `Added ${stamp(created, timeZone)}\nReplaced ${stamp(last, timeZone)}` };
  }
  return { text: `Added ${age(created, now)}`, help: `Added ${stamp(created, timeZone)}` };
}

/** "Used 2 h ago" after a read, "Never used" when none since it was added. The machines keep only the last operation
 * (#4158), so a Replace… since the last read reads "Not used since it was replaced". */
export function usedPart(last: SecretLastOp | undefined, now = new Date(), timeZone?: string): Part {
  if (!last) return { text: "Never used" };
  const at = fromWireDate(last.at);
  const when = stamp(at, timeZone);
  switch (last.what) {
    case "read": return { text: `Used ${age(at, now)}`, help: `Read ${when}` };
    case "denied": return { text: `Use denied ${age(at, now)}`, help: `A use was denied ${when}` };
    case "replaced": return { text: "Not used since it was replaced", help: `Replaced ${when}` };
    default: return { text: "Never used" };
  }
}

function date(text: string | undefined): Date | null {
  if (!text) return null;
  const at = new Date(text);
  return Number.isNaN(at.getTime()) ? null : at;
}

/** The line under a person's secret: "On 3 machines · Added 27 d ago · Used 2 h ago". */
export function rowLine(row: Pick<UserSecretRow, "machines" | "created" | "updated" | "lastOp">, now = new Date(),
  timeZone?: string): Part[] {
  const set = setPart(date(row.created), date(row.updated), now, timeZone);
  return [{ text: machines(row) }, ...(set ? [set] : []), usedPart(row.lastOp, now, timeZone)];
}

/** The line under a secret for one session: "Fix the shop sign-in · Added 1 h ago · Used 20 min ago". */
export function sessionLine(secret: Pick<SessionSecret, "title" | "created" | "setAt" | "lastOp">, now = new Date(),
  timeZone?: string): Part[] {
  const set = setPart(secret.created !== undefined ? fromWireDate(secret.created) : null, fromWireDate(secret.setAt), now, timeZone);
  return [{ text: secret.title }, ...(set ? [set] : []), usedPart(secret.lastOp, now, timeZone)];
}

export function joined(parts: readonly Part[]): string {
  return parts.map((p) => p.text).join(" · ");
}

/** The control plane's machines' names, by id, for the warnings. */
export function machineNames(hosts: readonly Pick<ControlMachine, "id" | "name">[]): Record<string, string> {
  const names: Record<string, string> = {};
  for (const h of hosts) names[h.id] ??= h.name;
  return names;
}

/** Under a person's secret that one copy only opens. Null while a machine waits for a copy (that line shows). */
export function notBackedUp(row: Pick<UserSecretRow, "backedUp" | "waiting" | "machines">,
  names: Record<string, string> = {}): string | null {
  const id = row.machines[0];
  if (row.backedUp !== false || (row.waiting?.length ?? 0) > 0 || id === undefined) return null;
  const name = names[id];
  return name ? `Only on ${name}. Not backed up: if ${name} is lost, this secret is lost.`
    : "Only on one machine. Not backed up: if it is lost, this secret is lost.";
}

/** The one machine the person has, when every secret is on it and on no other: then the page says it once, at the
 * top, and the rows have no warning. */
export function onlyMachine(rows: readonly Pick<UserSecretRow, "backedUp" | "waiting" | "machines">[]): string | null {
  if (!rows.some((r) => r.backedUp === false)) return null;
  const all = new Set<string>(rows.flatMap((r) => [...r.machines, ...(r.waiting ?? [])]));
  return all.size === 1 ? ([...all][0] ?? null) : null;
}

/** At the top of the page, for a person with one machine only. */
export function onlyMachineLine(id: string, names: Record<string, string> = {}): string {
  return `Your secrets are only on ${names[id] ?? "one machine"}. Add a second machine to keep a copy.`;
}

/** Under each secret for one session: it is on this Mac only. */
export const sessionNotBackedUp = "Only on this Mac. Not backed up. It is deleted when the session is archived.";
