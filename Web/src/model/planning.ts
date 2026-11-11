// Reports ▸ Planning (#4528): Value's figures (value.ts), and what comes next, from lineage/forecast (#4526): the
// burn against each weekly allowance, what a week and a month cost at the window's pace, each level's service level,
// each open epic's landing range, and how the kept forecasts scored. The loaded figures (#4524) sit beside the direct
// ones. The method is specs/4533-forecasting/spec.md.
import type { LineageEstimateRange, LineageForecast, LineageForecastBurn, LineageForecastServiceLevel, ReportForecastScore,
  ReportValue } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { rough, roughTime } from "./estimate";
import { costWords } from "./value";

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** A date as the page says it: "Thu 13 Nov", with the hour when it is within two days of now: "Thu 3 PM". */
export function dayWords(seconds: number, now = Date.now()): string {
  const t = fromWireDate(seconds as never);
  const near = Math.abs(t.getTime() - now) < 2 * 86400 * 1000;
  return t.toLocaleString(undefined, near ? { weekday: "short", hour: "numeric" } : { weekday: "short", day: "numeric", month: "short" });
}

/** A range by currency, rounded as an estimate is: "$40 to $90, typically $60". */
export function rangeWords(r: Record<string, LineageEstimateRange> | undefined): string | undefined {
  const priced = Object.entries(r ?? {}).sort(([a], [b]) => a.localeCompare(b));
  if (priced.length === 0) return undefined;
  return priced.map(([currency, v]) => {
    const low = rough(v.p10, currency), high = rough(v.p90, currency), mid = rough(v.median, currency);
    return low === high ? `about ${mid}` : `${low} to ${high}, typically ${mid}`;
  }).join("; ");
}

/** The direct figure with the loaded one beside it: "$40 to $90, typically $60 (about $100 all in)". */
function withLoaded(direct: Record<string, LineageEstimateRange> | undefined, loaded: Record<string, LineageEstimateRange> | undefined): string | undefined {
  const words = rangeWords(direct);
  if (!words) return undefined;
  const all = Object.entries(loaded ?? {}).sort(([a], [b]) => a.localeCompare(b));
  if (all.length === 0) return words;
  return `${words} (about ${all.map(([currency, v]) => rough(v.median, currency)).join(" + ")} all in)`;
}

/** What a week and a month cost at the window's pace: "A week: $40 to $90, typically $60 (about $100 all in)". */
export function spendLines(f: LineageForecast): string[] {
  if (!f.spend) return [];
  const week = withLoaded(f.spend.week, f.spend.loadedWeek), month = withLoaded(f.spend.month, f.spend.loadedMonth);
  return [week && `A week: ${week}`, month && `A month: ${month}`].filter((s): s is string => !!s);
}

/** A weekly allowance's burn: "Claude, 7 days: 62% used; at this pace it runs out Fri 14 Nov, before it resets Sun 16 Nov",
 * or "… lasts to the reset Sun 16 Nov". */
export function burnLine(b: LineageForecastBurn, name: string, now = Date.now()): string {
  const used = `${name}, ${b.window}: ${Math.round(b.used * 100)}% used`;
  if (b.used >= 1) return `${used}; it ran out, and resets ${dayWords(b.resetsAt, now)}`;
  if (!b.lasts && b.runsOutAt !== undefined) return `${used}; at this pace it runs out ${dayWords(b.runsOutAt, now)}, before it resets ${dayWords(b.resetsAt, now)}`;
  return `${used}; at this pace it lasts to the reset ${dayWords(b.resetsAt, now)}`;
}

const levelNames: Record<string, string> = { story: "Stories", task: "Tasks", spike: "Spikes", bug: "Bugs", epic: "Epics" };

/** A level's service level: "Stories: half within 2 hours, 85% within 6 hours (31 landed)". */
export function serviceLevelLine(s: LineageForecastServiceLevel): string {
  const head = levelNames[s.level] ?? (s.level || "Issues");
  return `${head}: half within ${roughTime(s.p50Seconds, s.p50Seconds)}, 85% within ${roughTime(s.p85Seconds, s.p85Seconds)} (${s.closed} landed)`;
}

/** An open epic's landing: "6 open children: P50 Thu 13 Nov, P85 Fri 14 Nov · $40 to $90, typically $60 to complete
 * (about $100 all in)", or why there is none. */
export function landsLine(f: LineageForecast, now = Date.now()): string {
  const parts: string[] = [];
  if (f.lands) {
    parts.push(`${plural(f.lands.open, "open child", "open children")}: P50 ${dayWords(f.lands.p50, now)}, P85 ${dayWords(f.lands.p85, now)}`);
  } else {
    parts.push(f.noForecast ?? "No forecast");
  }
  const left = f.toComplete && withLoaded(f.toComplete.cost, f.toComplete.loaded);
  if (left) parts.push(`${left} to complete`);
  return parts.join(" · ");
}

/** How the kept forecasts scored: "The P85 date held 9 of 11 times (it should hold about 85%); the P50 held 6 of 11
 * (about half); the P50 was off by a median of 1 day". */
export function forecastScoreLine(s: ReportForecastScore | undefined): string | undefined {
  if (!s || s.epics === 0) return undefined;
  const parts = [`The P85 landing date held ${s.p85Held} of ${plural(s.epics, "epic", "epics")} (it should hold about 85%)`,
    `the P50 held ${s.p50Held} of ${s.epics} (about half)`];
  if (s.errorDays !== undefined) parts.push(`the P50 was off by a median of ${plural(Math.round(s.errorDays * 10) / 10, "day", "days")}`);
  return parts.join("; ");
}

/** The cost all in, beside the direct one: "$16.20 all in, with the turns on no issue or pull request (the overhead
 * was ×1.3 over the last 14 days)". */
export function loadedLine(v: ReportValue): string | undefined {
  if (!v.loaded) return undefined;
  const ratio = v.overhead?.unlinkedRatio;
  const over = ratio !== undefined && v.overhead ? ` (the overhead was ×${(1 + ratio).toFixed(1)} over the last ${v.overhead.windowDays} days)` : "";
  return `${costWords(v.loaded)} all in, with the turns on no issue or pull request${over}`;
}

/** Each allowance once, from every machine's answer: the newest reading of it. */
export function mergeBurns(all: readonly LineageForecast[]): LineageForecastBurn[] {
  const by = new Map<string, LineageForecastBurn>();
  for (const f of all) for (const b of f.burn) {
    const have = by.get(b.credentialKey);
    if (!have || b.at > have.at) by.set(b.credentialKey, b);
  }
  return [...by.values()].sort((a, b) => a.credentialKey.localeCompare(b.credentialKey));
}

/** The name of the allowance's runtime: the part of its key before the colon. */
export const burnRuntime = (b: LineageForecastBurn) => b.credentialKey.split(":", 1)[0] ?? b.credentialKey;

export const noNext = "Not enough history on this machine to say what comes next: it needs 7 days of issues landed with a merged pull request.";
export const nextNote = "What comes next is this machine’s: its last 14 days of landings, drawn 1,000 times. A range is P10 to P90; P50 is as likely early as late, and P85 holds about 85% of the time. An epic’s date counts the children filed now, so it moves when more are filed. “All in” adds the turns that went on no issue or pull request (a Scrum Master’s, a review’s); people’s time and CI minutes are in no figure.";
export const noNextHere = "This machine does not forecast yet. Update it to see what comes next.";
