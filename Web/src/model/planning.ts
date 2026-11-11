// Reports ▸ Planning (#4528): Value's figures (value.ts), and what comes next, from lineage/forecast (#4526): the
// burn against each weekly allowance, what a week and a month cost at the window's pace, each level's service level,
// each open epic's landing range, and how the kept forecasts scored. The loaded figures (#4524) sit beside the direct
// ones. The method is specs/4533-forecasting/spec.md.
import type { LineageEstimateRange, LineageForecast, LineageForecastAssumes, LineageForecastBurn, LineageForecastServiceLevel,
  LineageForecastWhatIf, LineageForecastWhatIfEffect, ReportForecastScore, ReportValue } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { roughTime } from "./estimate";
import { money as moneyWords } from "./limits";
import { costWords } from "./value";

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** A date as the page says it: the day and the hour within a week of now, "Fri 3 PM"; else the day, "Thu 20 Nov". */
export function dayWords(seconds: number, now = Date.now()): string {
  const t = fromWireDate(seconds as never);
  const near = Math.abs(t.getTime() - now) < 7 * 86400 * 1000;
  return t.toLocaleString(undefined, near ? { weekday: "short", hour: "numeric" } : { weekday: "short", day: "numeric", month: "short" });
}

/** Money to two significant figures, as a forecast is wide but a spend or a cost to complete is read closely: "$250",
 * "$1,100", "$4.20". */
export function money2(v: number, currency: string): string {
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency, maximumSignificantDigits: 2 }).format(v);
  } catch {
    return moneyWords(v, currency);
  }
}

/** A range by currency: "$220 to $280, typically $250". */
export function rangeWords(r: Record<string, LineageEstimateRange> | undefined): string | undefined {
  const priced = Object.entries(r ?? {}).sort(([a], [b]) => a.localeCompare(b));
  if (priced.length === 0) return undefined;
  return priced.map(([currency, v]) => {
    const low = money2(v.p10, currency), high = money2(v.p90, currency), mid = money2(v.median, currency);
    return low === high ? `about ${mid}` : `${low} to ${high}, typically ${mid}`;
  }).join("; ");
}

/** The direct figure with the loaded one beside it: "$220 to $280, typically $250 (about $260 all in)". */
function withLoaded(direct: Record<string, LineageEstimateRange> | undefined, loaded: Record<string, LineageEstimateRange> | undefined): string | undefined {
  const words = rangeWords(direct);
  if (!words) return undefined;
  const all = Object.entries(loaded ?? {}).sort(([a], [b]) => a.localeCompare(b));
  if (all.length === 0) return words;
  return `${words} (about ${all.map(([currency, v]) => money2(v.median, currency)).join(" + ")} all in)`;
}

/** What a week and a month cost at the window's pace: "A week: $40 to $90, typically $60 (about $100 all in)". */
export function spendLines(f: LineageForecast): string[] {
  if (!f.spend) return [];
  const week = withLoaded(f.spend.week, f.spend.loadedWeek), month = withLoaded(f.spend.month, f.spend.loadedMonth);
  return [week && `A week: ${week}`, month && `A month: ${month}`].filter((s): s is string => !!s);
}

const windowNames: Record<string, string> = {
  seven_day: "this week", weekly: "this week", seven_day_opus: "this week of Opus", seven_day_sonnet: "this week of Sonnet",
};

/** A weekly allowance's burn: "Claude, this week: 62% used; at this pace it runs out Thu 4 PM, before it resets Fri 3 PM",
 * or "… it lasts to the reset Fri 3 PM". */
export function burnLine(b: LineageForecastBurn, name: string, now = Date.now()): string {
  const used = `${name}, ${windowNames[b.window] ?? b.window}: ${Math.round(b.used * 100)}% used`;
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

/** An open epic's landing: "6 open children: P50 Thu 3 PM, P85 Fri 10 AM · $40 to $90, typically $60 (about $80 all
 * in) to complete", or why there is none. */
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
 * was ×1.30 over the last 14 days)". */
export function loadedLine(v: ReportValue): string | undefined {
  if (!v.loaded) return undefined;
  const ratio = v.overhead?.unlinkedRatio;
  const over = ratio !== undefined && v.overhead ? ` (the overhead was ×${(1 + ratio).toFixed(2)} over the last ${v.overhead.windowDays} days)` : "";
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

// What-if (#4531): a lane limit and a runtime mix, each "" as the window ran.

/** The lane limits to pick: as they ran, then 1 to 10. */
export function laneOptions(a: LineageForecastAssumes | undefined): [string, string][] {
  const ran = a && a.peakLanes > 0 ? `As they ran (up to ${a.peakLanes})` : "As they ran";
  return [["", ran], ...Array.from({ length: 10 }, (_, i): [string, string] => [String(i + 1), plural(i + 1, "lane", "lanes")])];
}

/** A runtime's shares to pick: as it ran (or, when another runtime is picked, the rest it takes now), then 0% to 100%
 * by tens. */
export function mixOptions(share: number, rest?: number): [string, string][] {
  return [["", rest === undefined ? `As it ran (${Math.round(share * 100)}%)` : `The rest (${Math.round(rest * 100)}%)`],
    ...Array.from({ length: 11 }, (_, i): [string, string] => [String(i * 10), `${i * 10}%`])];
}

/** The request's what-if from the picks: undefined when every pick is as it ran. The runtimes not picked share what the
 * picked ones leave, in the parts they ran with; the daemon scales the mix to add up to 1. */
export function whatIfOf(lanes: string, mix: Record<string, string>, a: LineageForecastAssumes | undefined): LineageForecastWhatIf | undefined {
  const w: LineageForecastWhatIf = {};
  if (lanes) w.lanes = Number(lanes);
  const picked = a ? a.runtimes.filter((r) => (mix[r.runtime] ?? "") !== "") : [];
  if (a && picked.length > 0) {
    const taken = picked.reduce((sum, r) => sum + Number(mix[r.runtime]) / 100, 0);
    const rest = a.runtimes.filter((r) => !picked.includes(r));
    const restRan = rest.reduce((sum, r) => sum + r.share, 0);
    w.mix = Object.fromEntries(a.runtimes.map((r) => [r.runtime, picked.includes(r) ? Number(mix[r.runtime]) / 100
      : restRan > 0 ? Math.max(0, 1 - taken) * r.share / restRan : 0]));
  }
  return w.lanes === undefined && w.mix === undefined ? undefined : w;
}

const perHour = (rate: Record<string, number>) => {
  const priced = Object.entries(rate).sort(([a], [b]) => a.localeCompare(b));
  return priced.length === 0 ? "" : ` at ${priced.map(([currency, v]) => money2(v, currency)).join(" + ")} an hour`;
};

/** What the window ran with: "The last 14 days had 3.2 issues in flight in an average hour, 7 at most; the mix was
 * Claude 75% at $10 an hour, Codex 25% at $2 an hour." */
export function assumesLine(a: LineageForecastAssumes, windowDays: number, name: (runtime: string) => string): string {
  const lanes = a.peakLanes === 0 ? `The last ${windowDays} days had no issue in flight`
    : `The last ${windowDays} days had ${(Math.round(a.lanes * 10) / 10).toLocaleString()} issues in flight in an average hour, ${a.peakLanes} at most`;
  if (a.runtimes.length === 0) return `${lanes}; no runtime’s hours are on this machine.`;
  return `${lanes}; the mix was ${a.runtimes.map((r) => `${name(r.runtime)} ${Math.round(r.share * 100)}%${perHour(r.rate)}`).join(", ")}.`;
}

/** What a what-if moved: "At 2 lanes: 64% of the landings, so the dates move out and a week costs less. With this mix,
 * the dollars are ×0.75; a mix does not move the dates, as a landing does not say its runtime." */
export function whatIfLines(e: LineageForecastWhatIfEffect, a: LineageForecastAssumes | undefined): string[] {
  const out: string[] = [];
  if (e.lanes !== undefined) {
    out.push(e.pace >= 0.995
      ? `At ${plural(e.lanes, "lane", "lanes")}: no hour of the window had more than ${a?.peakLanes ?? e.lanes} issues in flight, so this limit moves nothing. Nothing here says what more lanes than that would do.`
      : `At ${plural(e.lanes, "lane", "lanes")}: ${Math.round(e.pace * 100)}% of the window’s landings, so the dates move out and a week costs less. Each allowance burns slower by as much.`);
  }
  if (e.mix) {
    out.push(`With this mix, the dollars are ×${e.cost.toFixed(2)}, and each allowance burns at its runtime’s new share. A mix does not move the dates: a landing does not say its runtime.`);
  }
  return out;
}

export const whatIfNote = "A what-if is not kept and not scored: only the forecast as the window ran is.";

export const noNext = "Not enough history on this machine to say what comes next: it needs 7 days of issues landed with a merged pull request.";
export const nextNote = "What comes next is this machine’s: its last 14 days of landings, drawn 1,000 times. A range is P10 to P90; P50 is as likely early as late, and P85 holds about 85% of the time. An epic’s date counts the children filed now, so it moves when more are filed. “All in” adds the turns that went on no issue or pull request (a Scrum Master’s, a review’s); people’s time and CI minutes are in no figure.";
export const noNextOffline = "None of your machines is online, so nothing says what comes next. It shows when one is back.";
export const noNextHere = "This machine does not forecast yet. Update it to see what comes next.";
