// Cost ▸ Reports (#1811), as ReportTotals and ReportWords have it on the window and the
// Remote: a report's rows added up by person, project, folder, machine or runtime, largest first.
import type { ReportFormat, ReportPage, ReportRange, ReportRow, ReportScope, ReportView, UsageReport } from "../protocol/generated";
import { money } from "./limits";
import { timeWords } from "./time";
import { tokenWords } from "./usage";

export type ReportDimension = "person" | "project" | "folder" | "machine" | "runtime" | "group" | "workflow";
export const dimensions: readonly ReportDimension[] = ["person", "project", "folder", "machine", "runtime"];
export const dimensionTitle: Record<ReportDimension, string> = { person: "Person", project: "Project", folder: "Folder", machine: "Machine", runtime: "Runtime", group: "Group",
  workflow: "Workflow" };
export const ranges: readonly ReportRange[] = ["day", "week", "month", "threeMonths"];
export const rangeShort: Record<ReportRange, string> = { day: "D", week: "W", month: "M", threeMonths: "3M" };
/** The range's name as a screen reader says it: "D" alone means nothing (#2440). */
export const rangeSpoken: Record<ReportRange, string> = { day: "Day", week: "Week", month: "Month", threeMonths: "3 months" };
/** What Spend's bars measure (#2440). */
export const spendBarCaption = "Each bar is the cost against the largest, or the tokens when nothing has a price.";
export const rangeSpan: Record<ReportRange, string> = { day: "The last 24 hours", week: "The last 7 days", month: "The last 30 days", threeMonths: "The last 90 days" };

export const removedOwner = "A removed machine";
export const noFolder = "No folder";
export const noProject = "No project";
export const noRuntime = "No runtime";
export const noGroup = "No group";
export const noWorkflow = "No workflow";
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
    case "workflow": return [r.workflow ?? "", r.workflow || noWorkflow];
    case "person": return [r.person, r.person ? r.personName || r.person : removedOwner];
    // The project the folder is in, across machines (#2670).
    case "project": return [r.project ?? "", r.project ? r.projectName ?? r.project : noProject];
    case "folder": return [r.folder, r.folder || noFolder];
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

// Outcomes and Time (#2019): what the agents did, from the counts each machine adds to its rows
// (ReportCounts). A machine before #2019 sends none, so its rows count as nothing done.

export interface OutcomeGroup {
  id: string;
  name: string;
  cost: Record<string, number>;
  sessions: number;
  opened: number;
  merged: number;
  reverted: number;
  mergeSeconds: number;
  workingSeconds: number;
  waitingSeconds: number;
  waits: number;
  /** The waits by length, as ReportCounts.waitBuckets. */
  buckets: number[];
  failed: number;
  runs: number;
  runFailures: number;
  turns: number;
  unpricedTurns: number;
}

const blankOutcome = (id: string, name: string): OutcomeGroup => ({ id, name, cost: {}, sessions: 0, opened: 0, merged: 0, reverted: 0,
  mergeSeconds: 0, workingSeconds: 0, waitingSeconds: 0, waits: 0, buckets: [0, 0, 0, 0, 0, 0], failed: 0, runs: 0, runFailures: 0, turns: 0,
  unpricedTurns: 0 });

function addOutcome(g: OutcomeGroup, r: ReportRow) {
  for (const [currency, amount] of Object.entries(r.cost)) g.cost[currency] = (g.cost[currency] ?? 0) + amount;
  g.workingSeconds += r.workingSeconds;
  g.waitingSeconds += r.waitingSeconds;
  g.turns += r.turns;
  g.unpricedTurns += r.unpricedTurns;
  const c = r.counts;
  if (!c) return;
  g.sessions += c.sessions;
  g.failed += c.failedSessions;
  g.runs += c.workflowRuns;
  g.runFailures += c.workflowFailures;
  g.opened += c.prsOpened;
  g.merged += c.prsMerged;
  g.reverted += c.prsReverted;
  g.mergeSeconds += c.mergeSeconds;
  g.waits += c.waits;
  c.waitBuckets.forEach((n, i) => { if (i < g.buckets.length) g.buckets[i]! += n; });
}

export interface OutcomeTotals {
  groups: OutcomeGroup[];
  total: OutcomeGroup;
}

/** How a page sorts its groups: merged first for Outcomes, waiting for Time, cost for Runtimes,
 * and failing for Workflows (the red list first). */
export type OutcomeOrder = "merged" | "waiting" | "cost" | "failing";

const firstCost = (g: OutcomeGroup) => Object.values(g.cost)[0] ?? 0;

/** The rows added up by a dimension, sorted by `order`. */
export function outcomeTotals(rows: readonly ReportRow[], by: ReportDimension, order: OutcomeOrder,
  runtimeName: (id: string) => string = (id) => id, groupNames: Record<string, string> = {}): OutcomeTotals {
  const groups = new Map<string, OutcomeGroup>();
  const total = blankOutcome("", "Total");
  for (const r of rows) {
    for (const [id, name] of keys(r, by, runtimeName, groupNames)) {
      const g = groups.get(id) ?? blankOutcome(id, name);
      groups.set(id, g);
      addOutcome(g, r);
    }
    addOutcome(total, r);
  }
  const by_ = {
    merged: (a: OutcomeGroup, b: OutcomeGroup) => b.merged - a.merged || b.opened - a.opened || b.sessions - a.sessions,
    waiting: (a: OutcomeGroup, b: OutcomeGroup) => waitingShare(b) - waitingShare(a) || b.waits - a.waits,
    cost: (a: OutcomeGroup, b: OutcomeGroup) => firstCost(b) - firstCost(a) || b.sessions - a.sessions,
    failing: (a: OutcomeGroup, b: OutcomeGroup) => b.runFailures - a.runFailures || b.runs - a.runs,
  }[order];
  const sorted = [...groups.values()].sort((a, b) => by_(a, b) || a.name.localeCompare(b.name));
  return { groups: sorted, total };
}

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** "3 merged of 4 opened · 1 revert · $7.90 a merged pull request · 2h 10m from start to merge · 5 sessions". */
export function outcomeLine(g: OutcomeGroup): string {
  const parts = [`${g.merged} merged of ${g.opened} opened`];
  if (g.reverted > 0) parts.push(plural(g.reverted, "revert", "reverts"));
  if (g.merged > 0) {
    for (const [c, v] of Object.entries(g.cost).sort(([a], [b]) => a.localeCompare(b))) parts.push(`${money(v / g.merged, c)} a merged pull request`);
    parts.push(`${timeWords(g.mergeSeconds / g.merged)} from start to merge`);
  }
  parts.push(plural(g.sessions, "session", "sessions"));
  return parts.join(" · ");
}

export const outcomesNote = "A pull or merge request counts when an agent made it on its own branch, and the machine heard of it: a workflow or a wait on pr.opened or pr.merged. A revert is one whose title starts with “Revert”. The time is from the agent’s start to the merge.";
export const noOutcomes = "No sessions or pull requests in this time. Each machine sends what its agents did once an hour.";

/** The share of the agents' time spent waiting for a person, 0 to 1. */
export function waitingShare(g: Pick<OutcomeGroup, "workingSeconds" | "waitingSeconds">): number {
  const all = g.workingSeconds + g.waitingSeconds;
  return all > 0 ? g.waitingSeconds / all : 0;
}

/** What each of ReportCounts.waitBuckets holds. */
export const waitBucketWords = ["under 1 minute", "1 to 5 minutes", "5 to 15 minutes", "15 to 60 minutes", "1 to 4 hours", "over 4 hours"];

/** The bucket the middle wait is in, or null with no waits. */
export function medianWait(buckets: readonly number[]): string | null {
  const all = buckets.reduce((a, b) => a + b, 0);
  if (all === 0) return null;
  let seen = 0;
  for (let i = 0; i < buckets.length; i++) {
    seen += buckets[i]!;
    if (seen * 2 >= all) return waitBucketWords[i] ?? null;
  }
  return null;
}

/** "Waiting for a person 38% of the time · 12 waits, the middle one 5 to 15 minutes · 6h 10m working". */
export function timeLine(g: OutcomeGroup): string {
  const parts = [`Waiting for a person ${Math.round(waitingShare(g) * 100)}% of the time`];
  const middle = medianWait(g.buckets);
  parts.push(middle ? `${plural(g.waits, "wait", "waits")}, the middle one ${middle}` : "no waits");
  parts.push(`${timeWords(g.workingSeconds)} working`);
  return parts.join(" · ");
}

export const timeNote = "Working is the agent, its tools and waiting on others. Waiting is a question, a form or a permission that waits for its person. When the agents wait a lot, the fix may be people, not machines.";

// Runtimes (R4), Adoption (R5) and Workflows (R6), #2019.

const percent = (part: number, all: number) => all > 0 ? `${Math.round(part / all * 100)}%` : "0%";

/** "$12.40 · 7 merged · $1.77 a merged pull request · 1 of 11 sessions failed (9%) · 3 turns not priced". */
export function runtimeLine(g: OutcomeGroup): string {
  const costs = Object.entries(g.cost).sort(([a], [b]) => a.localeCompare(b));
  const parts = costs.map(([c, v]) => money(v, c));
  parts.push(`${g.merged} merged`);
  if (g.merged > 0) for (const [c, v] of costs) parts.push(`${money(v / g.merged, c)} a merged pull request`);
  parts.push(`${g.failed} of ${plural(g.sessions, "session", "sessions")} failed (${percent(g.failed, g.sessions)})`);
  if (g.unpricedTurns > 0) parts.push(`${plural(g.unpricedTurns, "turn", "turns")} not priced`);
  return parts.join(" · ");
}

export const runtimesNote = "A session fails when it ends in an error that nobody chose, such as a crash, a refused sign-in or a spent allowance. Use this page to choose the runtimes and models a team starts with.";

/** "2 of 7 runs failed · $0.40 a run · 12m working a run". */
export function workflowLine(g: OutcomeGroup): string {
  const parts = [`${g.runFailures} of ${plural(g.runs, "run", "runs")} failed`];
  if (g.runs > 0) {
    for (const [c, v] of Object.entries(g.cost).sort(([a], [b]) => a.localeCompare(b))) parts.push(`${money(v / g.runs, c)} a run`);
    parts.push(`${timeWords(g.workingSeconds / g.runs)} working a run`);
  }
  return parts.join(" · ");
}

/** What each page's bars measure: each page's bar is a different thing (#2440). */
export const barCaption = {
  outcomes: "Each bar is the merged pull requests against the most.",
  time: "Each bar is the part of the time that waits for a person.",
  runtimes: "Each bar is the cost against the largest.",
  workflows: "Each bar is the part of the runs that failed.",
} as const;
export const workflowsNote = "The workflows with the most failed runs come first. A run fails when its agent ends in an error. By Person shows each bot’s runs under its name.";
export const noWorkflows = "No workflow ran in this time.";

/** The rows of a workflow's agents only. */
export function workflowRows(rows: readonly ReportRow[]): ReportRow[] {
  return rows.filter((r) => r.workflow);
}

export interface AdoptionWeek {
  /** The Monday the week starts on (UTC), "2026-10-19". */
  week: string;
  /** People and bots with a turn or a session; null when nobody is named. */
  people: number | null;
  sessions: number;
  runtimes: number;
  workflows: number;
}

/** The Monday (UTC) of a row's hour or day. */
export function weekOf(at: string): string {
  const day = new Date(`${at.slice(0, 10)}T00:00:00Z`);
  day.setUTCDate(day.getUTCDate() - (day.getUTCDay() + 6) % 7);
  return day.toISOString().slice(0, 10);
}

/** Each week's active people, sessions, runtimes and workflows in use, newest first. */
export function adoption(rows: readonly ReportRow[], hidden = false): AdoptionWeek[] {
  const weeks = new Map<string, { people: Set<string>; sessions: number; runtimes: Set<string>; workflows: Set<string> }>();
  for (const r of rows) {
    const used = r.turns > 0 || (r.counts?.sessions ?? 0) > 0;
    const k = weekOf(r.at);
    const w = weeks.get(k) ?? { people: new Set(), sessions: 0, runtimes: new Set(), workflows: new Set() };
    weeks.set(k, w);
    w.sessions += r.counts?.sessions ?? 0;
    if (!used) continue;
    if (r.person) w.people.add(r.person);
    if (r.runtime) w.runtimes.add(r.runtime);
    if (r.workflow) w.workflows.add(r.workflow);
  }
  return [...weeks].sort(([a], [b]) => b.localeCompare(a)).map(([week, w]) => ({ week, people: hidden ? null : w.people.size,
    sessions: w.sessions, runtimes: w.runtimes.size, workflows: w.workflows.size }));
}

/** "The week of 19 Oct". */
export function weekTitle(week: string): string {
  const d = new Date(`${week}T00:00:00Z`);
  return `The week of ${d.getUTCDate()} ${d.toLocaleString("en-GB", { month: "short", timeZone: "UTC" })}`;
}

/** "4 active people · 2.5 sessions a person · 3 runtimes · 2 workflows". */
export function adoptionLine(w: AdoptionWeek): string {
  const parts: string[] = [];
  if (w.people !== null) {
    parts.push(plural(w.people, "active person", "active people"));
    if (w.people > 0) parts.push(`${Math.round(w.sessions / w.people * 10) / 10} sessions a person`);
  } else {
    parts.push(plural(w.sessions, "session", "sessions"));
  }
  parts.push(plural(w.runtimes, "runtime", "runtimes"), plural(w.workflows, "workflow", "workflows"));
  return parts.join(" · ");
}

export const adoptionNote = "A person is active in a week when one of their machines, or a bot’s, ran a turn. Weeks start on Monday, UTC.";

// Saved views and digests (R8), #2019: a page with its scope, range and way to add up, kept on the
// control plane for the person who saved it, and its numbers as a few lines to paste.

export const reportPages: readonly ReportPage[] = ["spend", "outcomes", "time", "runtimes", "adoption", "workflows"];
export const pageTitle: Record<ReportPage, string> = { spend: "Spend", outcomes: "Outcomes", time: "Time", runtimes: "Runtimes",
  adoption: "Adoption", workflows: "Workflows" };

const isDimension = (by: string | undefined): by is ReportDimension =>
  by !== undefined && ["person", "project", "folder", "machine", "runtime", "group", "workflow"].includes(by);

/** A view's way to add up, when it says one this build knows. */
export function viewBy(view: Pick<ReportView, "by">): ReportDimension | undefined {
  return isDimension(view.by) ? view.by : undefined;
}

/** "Outcomes · Platform · The last 7 days · By Folder". */
export function viewWords(view: ReportView, scopeName: string): string {
  const by = viewBy(view);
  return [pageTitle[view.page], scopeName, rangeSpan[view.range], ...(by ? [`By ${dimensionTitle[by]}`] : [])].join(" · ");
}

export const noViews = "No saved views yet. On any page of Reports, choose Save View… to keep its scope, range and way to add up.";
export const viewsNote = "Your saved views are yours: nobody else sees them. Copy Digest gives a view’s numbers as text to paste into an email or a chat.";
export const noViewsHere = "This control plane keeps no saved views. Update it to save them.";
/** Copy Digest when the browser refuses the clipboard (#2263). */
export const noCopy = "Couldn’t copy. Select the text and copy it.";
/** Delete… asks first (#2262): a view took a scope, a range and a By to make, and nothing brings it back. */
export const deleteViewWords = (name: string) => `Delete ${name}?\n\nThe view goes for good. Its numbers stay in Reports.`;

/** A view's numbers as a few lines of text: what was spent, shipped and failed, and the middle wait. */
export function digestText(view: ReportView, scopeName: string, report: UsageReport): string {
  const all = outcomeTotals(report.rows, "person", "merged").total;
  const lines = [`${view.name}: ${scopeName}, ${rangeSpan[view.range].toLowerCase()}`];
  const spent = Object.entries(all.cost).sort(([a], [b]) => a.localeCompare(b));
  const first = [...spent.map(([c, v]) => `${money(v, c)} spent`), `${plural(all.merged, "pull request", "pull requests")} merged`];
  if (all.merged > 0) for (const [c, v] of spent) first.push(`${money(v / all.merged, c)} a merged pull request`);
  first.push(plural(all.sessions, "session", "sessions"));
  lines.push(first.join(" · "));
  const failing = outcomeTotals(workflowRows(report.rows), "workflow", "failing").groups.filter((g) => g.runFailures > 0);
  for (const g of failing.slice(0, 5)) lines.push(`Workflow ${g.name} failed ${g.runFailures} of ${plural(g.runs, "run", "runs")}.`);
  const middle = medianWait(all.buckets);
  if (middle) lines.push(`The middle wait for a person was ${middle}.`);
  if (all.failed > 0) lines.push(`${plural(all.failed, "session", "sessions")} ended in an error.`);
  return lines.join("\n");
}
