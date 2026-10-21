// Cost ▸ Reports (#1811), as ReportTotals and ReportWords have it on the window and the
// Remote: a report's rows added up by person, project, machine or runtime, largest first.
import type { ReportFormat, ReportRange, ReportRow } from "../protocol/generated";
import { money } from "./limits";
import { timeWords } from "./time";
import { tokenWords } from "./usage";

export type ReportDimension = "person" | "project" | "machine" | "runtime";
export const dimensions: readonly ReportDimension[] = ["person", "project", "machine", "runtime"];
export const dimensionTitle: Record<ReportDimension, string> = { person: "Person", project: "Project", machine: "Machine", runtime: "Runtime" };
export const ranges: readonly ReportRange[] = ["day", "week", "month", "threeMonths"];
export const rangeShort: Record<ReportRange, string> = { day: "D", week: "W", month: "M", threeMonths: "3M" };
export const rangeSpan: Record<ReportRange, string> = { day: "The last 24 hours", week: "The last 7 days", month: "The last 30 days", threeMonths: "The last 90 days" };

export const removedOwner = "A removed machine";
export const noProject = "No project";
export const noRuntime = "No runtime";
export const empty = "Nothing was used in this time. Each machine sends what it used once an hour.";
export const memberNote = "You see your own machines. An admin sees everyone's.";
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

function key(r: ReportRow, by: ReportDimension, runtimeName: (id: string) => string): [string, string] {
  switch (by) {
    case "person": return [r.person, r.person ? r.personName || r.person : removedOwner];
    case "project": return [r.project, r.project || noProject];
    case "machine": return [r.host, r.hostName || r.host];
    case "runtime": return [r.runtime, r.runtime ? runtimeName(r.runtime) : noRuntime];
  }
}

export function reportTotals(rows: readonly ReportRow[], by: ReportDimension, runtimeName: (id: string) => string = (id) => id): ReportTotals {
  const groups = new Map<string, ReportGroup>();
  const total = blank("", "Total");
  for (const r of rows) {
    const [id, name] = key(r, by, runtimeName);
    const g = groups.get(id) ?? blank(id, name);
    groups.set(id, g);
    add(g, r);
    add(total, r);
  }
  const currencies = Object.entries(total.cost).sort(([a, x], [b, y]) => y - x || a.localeCompare(b)).map(([c]) => c);
  const first = currencies[0];
  const sorted = [...groups.values()].sort((a, b) => {
    const ca = first ? a.cost[first] ?? 0 : 0, cb = first ? b.cost[first] ?? 0 : 0;
    return cb - ca || b.tokens - a.tokens || b.workingSeconds - a.workingSeconds || a.name.localeCompare(b.name);
  });
  return { groups: sorted, total, currencies };
}

/** A group's share of the largest, 0 to 1: by the first currency's cost, or by tokens when nothing was priced. */
export function share(totals: ReportTotals, g: ReportGroup): number {
  const currency = totals.currencies[0];
  if (currency) {
    const most = Math.max(0, ...totals.groups.map((x) => x.cost[currency] ?? 0));
    return most > 0 ? (g.cost[currency] ?? 0) / most : 0;
  }
  const most = Math.max(0, ...totals.groups.map((x) => x.tokens));
  return most > 0 ? g.tokens / most : 0;
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
