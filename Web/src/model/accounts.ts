// Your setup ▸ Accounts (#3967): the words and sums, as the window's AccountsWords.
import type { OutsideAccount } from "../protocol/generated";

export const accountsTitle = "Accounts";
export const noSecrets = "No secret goes here: give a card or a token by its name in Secrets.";

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

export function sameAccount(a: OutsideAccount, b: OutsideAccount): boolean {
  return a.service.toLowerCase() === b.service.toLowerCase() && (a.address ?? "").toLowerCase() === (b.address ?? "").toLowerCase();
}

export type AccountFields = Record<string, string>;

export function accountFields(a: OutsideAccount): AccountFields {
  return {
    service: a.service, address: a.address ?? "", plan: a.plan ?? "", cost: a.monthlyCostUsd === undefined ? "" : String(a.monthlyCostUsd),
    card: a.card ?? "", secret: a.secret ?? "", twoFactor: a.twoFactor ?? "", issue: a.issue ?? "", made: a.made ?? "",
    tokenExpires: a.tokenExpires ?? "", notes: a.notes ?? "", projects: (a.projects ?? []).join(", "),
  };
}

/** The account the sheet's fields say; an empty field is no value. */
export function accountOf(f: AccountFields): OutsideAccount {
  const v = (key: string) => (f[key] ?? "").trim() || undefined;
  const a: OutsideAccount = { service: v("service") ?? "" };
  for (const key of ["address", "plan", "card", "secret", "twoFactor", "issue", "made", "tokenExpires", "notes"] as const) {
    const value = v(key);
    if (value) a[key] = value;
  }
  const cost = Number((v("cost") ?? "").replace("$", ""));
  if (v("cost") && !Number.isNaN(cost)) a.monthlyCostUsd = cost;
  const projects = (v("projects") ?? "").split(",").map((p) => p.trim()).filter((p) => p);
  if (projects.length) a.projects = projects;
  return a;
}
