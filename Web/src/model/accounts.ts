// Settings ▸ You ▸ Accounts (#3967): the words and sums, as the window's AccountsWords.
import type { AccountLastOp, OutsideAccount, UserSecretRow } from "../protocol/generated";
import { Capability } from "../protocol/capabilities.generated";
import { fromWireDate } from "../protocol/dates";
import { planeNeedsUpdate } from "./capabilities";
import { age, hint, type Part, stamp } from "./secretInfo";

export const accountsTitle = "Accounts";
export const noSecrets = "No secret goes here: give a card or a token by its name in Secrets.";

/**
 * What the page says in place of Accounts (#4100): the control plane takes the accounts part of
 * `user/setSettings` only from `user/3`, so an older one, which refuses it, is sent nothing.
 * Null when it has it, and while its list (`control/status`) has not come yet.
 */
export function accountsRefusal(plane: { capabilities?: string[] | undefined } | null): string | null {
  if (!plane) return null;
  return plane.capabilities?.includes(Capability.user3) ? null : planeNeedsUpdate;
}

/** The accounts a project uses: those that name it and those that name none. */
export function accountsOf(all: OutsideAccount[], project: string): OutsideAccount[] {
  if (!project) return all;
  const p = project.toLowerCase();
  return all.filter((a) => !a.projects?.length || a.projects.some((n) => n.toLowerCase() === p));
}

/** Every project an account names, once, in order. */
export function accountProjects(all: OutsideAccount[]): string[] {
  const seen = new Map<string, string>();
  for (const n of all.flatMap((a) => a.projects ?? [])) if (!seen.has(n.toLowerCase())) seen.set(n.toLowerCase(), n);
  return [...seen.values()].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));
}

export function money(usd: number): string {
  return Number.isInteger(usd) ? `$${usd}` : `$${usd.toFixed(2)}`;
}

export function accountCost(a: OutsideAccount): string {
  return a.monthlyCostUsd === undefined ? "" : `${money(a.monthlyCostUsd)}/month`;
}

export const noDescription = "No description";

/** Ask before use (#4163): absent is on, as agentsd reads it. */
export function accountAsks(a: OutsideAccount): boolean {
  return a.askBeforeUse !== false;
}

/** Under the sheet's Ask before use toggle, as the window's AccountsWords.askHint. */
export function accountAskHint(on: boolean): string {
  return on ? "An agent's read of it waits for your approval: Approve, Approve for This Session, Always Approve or Deny."
    : "Every agent can read it with no approval.";
}

/** The sheet's field for Ask before use: "off" when it is off, else none. */
export const askField = "askBeforeUse";

/** The description (#4164), under the address; an account made before it has none. */
export function accountAbout(a: OutsideAccount): string {
  return a.description?.trim() || noDescription;
}

export function accountDetail(a: OutsideAccount): string {
  return [a.address, a.plan].filter((v) => v).join(" · ");
}

export function accountsFoot(shown: OutsideAccount[]): string {
  const total = shown.reduce((sum, a) => sum + (a.monthlyCostUsd ?? 0), 0);
  return `${shown.length} ${shown.length === 1 ? "account" : "accounts"}, ${money(total)} a month.`;
}

/** A line when the token expires in 30 days or less, or has expired. */
export function expiresSoon(a: OutsideAccount, now: number): string | null {
  const day = a.tokenExpires;
  const at = day && /^\d{4}-\d{2}-\d{2}$/.test(day) ? Date.parse(`${day}T00:00:00Z`) : NaN;
  if (Number.isNaN(at)) return null;
  const days = Math.ceil((at - now) / 86_400_000);
  if (days < 0) return `Its token expired on ${day}.`;
  return days <= 30 ? `Its token expires on ${day}.` : null;
}

/** The secret an account names (#4160): its token, else its card. */
export function accountSecretName(a: OutsideAccount): string | null {
  return [a.secret, a.card].map((n) => n?.trim()).find((n) => !!n) ?? null;
}

type Row = Pick<UserSecretRow, "name" | "hint" | "backedUp" | "waiting" | "machines">;

/** At the end of the first line (#4160): the last 4 of the secret it names, as its row in Secrets has them; "no
 * secret" when it names none; "not in Secrets" when Secrets has no such name (a secret kept somewhere else). */
export function accountHint(a: OutsideAccount, rows: readonly Row[]): string {
  const name = accountSecretName(a);
  if (!name) return "no secret";
  const row = rows.find((r) => r.name === name);
  return row ? hint(row.hint) : "not in Secrets";
}

/** "Used 2 h ago": an agent's manage_accounts call that names it, or a read of its secret or card, whichever is
 * newer; "Never used" for none. */
export function accountUsed(last: AccountLastOp | undefined, now = new Date(), timeZone?: string): Part {
  if (!last) return { text: "Never used" };
  const at = fromWireDate(last.at);
  const when = stamp(at, timeZone);
  const help = last.what === "added" ? `Added by an agent ${when}` : last.what === "edited" ? `Changed by an agent ${when}` : `Read ${when}`;
  return { text: `Used ${age(at, now)}`, help };
}

function dayOf(day: string | undefined): number {
  return day && /^\d{4}-\d{2}-\d{2}$/.test(day) ? Date.parse(`${day}T00:00:00Z`) : NaN;
}

/** The line under an account (#4160): "Made 9 d ago · Edited 1 d ago · Used 2 h ago", and "Token expires in 45 d"
 * while that is more than 30 days away (nearer, its own line says it). */
export function accountLine(a: OutsideAccount, now = new Date(), timeZone?: string): Part[] {
  const parts: Part[] = [];
  const made = dayOf(a.made);
  if (!Number.isNaN(made)) {
    const days = Math.floor((now.getTime() - made) / 86_400_000);
    parts.push({ text: days < 1 ? "Made today" : `Made ${days} d ago`, help: `Made ${a.made}` });
  }
  if (a.edited !== undefined) {
    const at = fromWireDate(a.edited);
    parts.push({ text: `Edited ${age(at, now)}`, help: `Edited ${stamp(at, timeZone)}` });
  }
  parts.push(accountUsed(a.lastOp, now, timeZone));
  const expires = dayOf(a.tokenExpires);
  const days = Math.ceil((expires - now.getTime()) / 86_400_000);
  if (!Number.isNaN(expires) && days > 30) parts.push({ text: `Token expires in ${days} d`, help: `Its token expires on ${a.tokenExpires}` });
  return parts;
}

/** Under an account whose key or card one copy only opens (#4160): "Its key, AWS_SECRET_KEY, is only on devbox. Not
 * backed up." Null while a machine waits for a copy. */
export function accountNotBackedUp(a: OutsideAccount, rows: readonly Row[], names: Record<string, string> = {}): string | null {
  for (const [kind, raw] of [["key", a.secret], ["card", a.card]] as const) {
    const name = raw?.trim();
    const row = name ? rows.find((r) => r.name === name) : undefined;
    const id = row?.machines[0];
    if (!row || row.backedUp !== false || (row.waiting?.length ?? 0) > 0 || id === undefined) continue;
    return `Its ${kind}, ${name}, is only on ${names[id] ?? "one machine"}. Not backed up.`;
  }
  return null;
}

export function sameAccount(a: OutsideAccount, b: OutsideAccount): boolean {
  return a.service.toLowerCase() === b.service.toLowerCase() && (a.address ?? "").toLowerCase() === (b.address ?? "").toLowerCase();
}

export type AccountFields = Record<string, string>;

export function accountFields(a: OutsideAccount): AccountFields {
  return {
    service: a.service, description: a.description ?? "", address: a.address ?? "", plan: a.plan ?? "", cost: a.monthlyCostUsd === undefined ? "" : String(a.monthlyCostUsd),
    card: a.card ?? "", secret: a.secret ?? "", twoFactor: a.twoFactor ?? "", issue: a.issue ?? "", made: a.made ?? "",
    tokenExpires: a.tokenExpires ?? "", notes: a.notes ?? "", projects: (a.projects ?? []).join(", "),
    ...(accountAsks(a) ? {} : { [askField]: "off" }),
  };
}

/** The account the sheet's fields say; an empty field is no value. */
export function accountOf(f: AccountFields): OutsideAccount {
  const v = (key: string) => (f[key] ?? "").trim() || undefined;
  const a: OutsideAccount = { service: v("service") ?? "" };
  for (const key of ["description", "address", "plan", "card", "secret", "twoFactor", "issue", "made", "tokenExpires", "notes"] as const) {
    const value = v(key);
    if (value) a[key] = value;
  }
  const cost = Number((v("cost") ?? "").replace("$", ""));
  if (v("cost") && !Number.isNaN(cost)) a.monthlyCostUsd = cost;
  const projects = (v("projects") ?? "").split(",").map((p) => p.trim()).filter((p) => p);
  if (projects.length) a.projects = projects;
  if (f[askField] === "off") a.askBeforeUse = false;
  return a;
}
