// Cost ▸ Reports (#1811), as ReportTotals and ReportWords have it on the window and the
// Remote: a report's rows added up by person, project, machine or runtime, largest first.
import type { ReportFormat, ReportRange, ReportRow, ReportScope, UsageReport } from "../protocol/generated";
import { money } from "./limits";
import { timeWords } from "./time";
import { tokenWords } from "./usage";

export type ReportDimension = "person" | "project" | "machine" | "runtime" | "group";
export const dimensions: readonly ReportDimension[] = ["person", "project", "machine", "runtime"];
export const dimensionTitle: Record<ReportDimension, string> = { person: "Person", project: "Project", machine: "Machine", runtime: "Runtime", group: "Group" };
export const ranges: readonly ReportRange[] = ["day", "week", "month", "threeMonths"];
export const rangeShort: Record<ReportRange, string> = { day: "D", week: "W", month: "M", threeMonths: "3M" };
export const rangeSpan: Record<ReportRange, string> = { day: "The last 24 hours", week: "The last 7 days", month: "The last 30 days", threeMonths: "The last 90 days" };

export const removedOwner = "A removed machine";
export const noProject = "No project";
export const noRuntime = "No runtime";
export const noGroup = "No group";
export const empty = "Nothing was used in this time. Each machine sends what it used once an hour.";
/** Whose spend the Cost page's pane shows (#2071). Reports ▸ Spend is named only to someone it
 * offers more than Me: an admin or a group's lead (#2200). */
export function meNote(seesMore: boolean): string {
  return seesMore ? "Your machines. A group’s and everyone’s are in Reports ▸ Spend." : memberNote;
}
export const memberNote = "Your machines. An admin or a group’s lead sees more.";
/** Whether an answer is of the scope asked for: a late answer to an earlier scope is not shown (#2201). */
export function sameScope(answer: ReportScope | undefined, asked: ReportScope): boolean {
  return scopeKey(answer ?? { kind: "me" }) === scopeKey(asked);
}
export function scopeNote(scope: ReportScope, groupName?: string): string {
  switch (scope.kind) {
    case "me": return "Your machines.";
    case "org": return "Everyone’s machines.";
    case "group": return `The machines of ${groupName ?? "the group"}’s people.`;
  }
}
export const utcNote = "Hours and days are UTC, so machines in other time zones add up.";

export interface ReportGroup {
  id: string;
  name: string;
  cost: Record<string, number>;
  tokens: number;
  turns: number;
  unpricedTurns: number;
  workingSeconds: number;
  waitingSeconds: number;
}

export interface ReportTotals {
  groups: ReportGroup[];
  total: ReportGroup;
  currencies: string[];
  /** The largest group's cost in the first currency, or its tokens when nothing was priced: worked out once (#2057). */
  most: number;
}

const blank = (id: string, name: string): ReportGroup => ({ id, name, cost: {}, tokens: 0, turns: 0, unpricedTurns: 0, workingSeconds: 0, waitingSeconds: 0 });

function add(g: ReportGroup, r: ReportRow) {
  for (const [currency, amount] of Object.entries(r.cost)) g.cost[currency] = (g.cost[currency] ?? 0) + amount;
  g.tokens += r.inputTokens + r.outputTokens + r.thoughtTokens + r.cachedWriteTokens;
  g.turns += r.turns;
  g.unpricedTurns += r.unpricedTurns;
  g.workingSeconds += r.workingSeconds;
  g.waitingSeconds += r.waitingSeconds;
}

function keys(r: ReportRow, by: ReportDimension, runtimeName: (id: string) => string, groupNames: Record<string, string>): [string, string][] {
  // A person in two groups counts in each (#1804).
  if (by === "group") return r.groups?.length ? r.groups.map((g) => [g, groupNames[g] ?? g]) : [["", noGroup]];
  return [key(r, by, runtimeName)];
}

function key(r: ReportRow, by: Exclude<ReportDimension, "group">, runtimeName: (id: string) => string): [string, string] {
  switch (by) {
    case "person": return [r.person, r.person ? r.personName || r.person : removedOwner];
    case "project": return [r.project, r.project || noProject];
    case "machine": return [r.host, r.hostName || r.host];
    case "runtime": return [r.runtime, r.runtime ? runtimeName(r.runtime) : noRuntime];
  }
}

export function reportTotals(rows: readonly ReportRow[], by: ReportDimension, runtimeName: (id: string) => string = (id) => id,
  groupNames: Record<string, string> = {}): ReportTotals {
  const groups = new Map<string, ReportGroup>();
  const total = blank("", "Total");
  for (const r of rows) {
    for (const [id, name] of keys(r, by, runtimeName, groupNames)) {
      const g = groups.get(id) ?? blank(id, name);
      groups.set(id, g);
      add(g, r);
    }
    add(total, r);
  }
  const currencies = Object.entries(total.cost).sort(([a, x], [b, y]) => y - x || a.localeCompare(b)).map(([c]) => c);
  const first = currencies[0];
  const sorted = [...groups.values()].sort((a, b) => {
    const ca = first ? a.cost[first] ?? 0 : 0, cb = first ? b.cost[first] ?? 0 : 0;
    return cb - ca || b.tokens - a.tokens || b.workingSeconds - a.workingSeconds || a.name.localeCompare(b.name);
  });
  const most = Math.max(0, ...sorted.map((x) => first ? x.cost[first] ?? 0 : x.tokens));
  return { groups: sorted, total, currencies, most };
}

/** A group's share of the largest, 0 to 1: by the first currency's cost, or by tokens when nothing was priced. */
export function share(totals: ReportTotals, g: ReportGroup): number {
  const currency = totals.currencies[0];
  const value = currency ? g.cost[currency] ?? 0 : g.tokens;
  return totals.most > 0 ? value / totals.most : 0;
}

/** The figures under a name: cost, tokens, turns and working time. */
export function line(g: ReportGroup): string {
  const parts = Object.entries(g.cost).sort(([a], [b]) => a.localeCompare(b)).map(([c, v]) => money(v, c));
  parts.push(`${tokenWords(g.tokens)} tokens`, g.turns === 1 ? "1 turn" : `${g.turns} turns`, `${timeWords(g.workingSeconds)} working`);
  return parts.join(" · ");
}

const pad = (n: number) => String(n).padStart(2, "0");

/** "report-week-2026-10-21.csv". */
export function exportName(range: ReportRange, format: ReportFormat, now: Date = new Date()): string {
  return `report-${range}-${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}.${format}`;
}

// Scopes (#1804): one report, three zoom levels. Me is on all three clients; a group and the
// organisation are the web's, in Reports.

/** What a scope is called in a picker's value: "me", "org" or "group:<id>". */
export function scopeKey(scope: ReportScope): string {
  return scope.kind === "group" ? `group:${scope.group ?? ""}` : scope.kind;
}

/** The ways to add a report up: with nobody named, neither person nor machine; past Me, by group too. */
export function scopedDimensions(report: Pick<UsageReport, "scope" | "personsHidden"> | null): ReportDimension[] {
  const hidden = report?.personsHidden === true;
  const list = dimensions.filter((d) => !hidden || (d !== "person" && d !== "machine"));
  return report?.scope && report.scope.kind !== "me" ? [...list, "group"] : list;
}

export const hiddenNote = "You see this group’s totals. An admin’s policy names no person or machine to a group’s leads.";
export const groupNote = "A person in more than one group counts in each.";

/** This month's spend at today's pace, to its last day (UTC). */
export function forecastUSD(spent: number, now: Date = new Date()): number {
  const days = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 0)).getUTCDate();
  const elapsed = (now.getTime() - Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)) / 86_400_000;
  return elapsed > 0 ? spent / Math.min(days, elapsed) * days : spent;
}

/** "$182.40 of $250 this month · forecast $310.00, over budget". */
export function budgetWords(spent: number, budget: number, now: Date = new Date()): string {
  const forecast = forecastUSD(spent, now);
  const over = forecast > budget ? ", over budget" : "";
  return `${money(spent, "USD")} of ${money(budget, "USD")} this month · forecast ${money(forecast, "USD")}${over}`;
}
