// The words for an estimate (#3560) on Work's issue and epic pages and in an epic's Plan, from
// lineage/estimate (#3559), as EstimateWords has them on the window. The figures are dollars, output
// tokens and the agents' working time. The line says a range with its typical value, rounded to one significant
// figure, as the median is often off by ×1.7 (#4530); lead time shows only as a range, as it varies with the queue
// (specs/3557-estimates).
import type { LineageEstimate, LineageEstimateRange } from "../protocol/generated";
import { money as moneyWords } from "./limits";
import { timeWords } from "./time";
import { tokenWords } from "./usage";
import { costWords, spent } from "./value";

export const notEnough = "Not enough past work to estimate";

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** Whether the estimate has a figure to show. */
export const hasFigures = (e: LineageEstimate) =>
  Object.keys(e.cost ?? {}).length > 0 || e.outputTokens !== undefined || e.workingSeconds !== undefined;

/** Whether the page shows an estimate for it: an issue, or an epic with open children. */
export const showsEstimate = (e: LineageEstimate) => e.openChildren === undefined || e.openChildren > 0;

/** The page's line: "Estimate: $1 to $10, typically $3; 30 min to 6 hours of agents' compute time (from 31 closed
 * stories)"; for an epic, "Estimate for 3 open children: …". Output tokens show only when there is no cost or time.
 * With too little history, "Not enough past work to estimate" and nothing else. */
export function estimateLine(e: LineageEstimate): string {
  if (!hasFigures(e)) return notEnough;
  const head = e.openChildren !== undefined ? `Estimate for ${plural(e.openChildren, "open child", "open children")}` : "Estimate";
  const parts: string[] = [];
  const priced = Object.entries(e.cost ?? {}).sort(([a], [b]) => a.localeCompare(b));
  if (priced.length > 0) {
    parts.push(priced.map(([currency, r]) => {
      const low = rough(r.p10, currency), high = rough(r.p90, currency), mid = rough(r.median, currency);
      return low === high ? `about ${mid}` : `${low} to ${high}, typically ${mid}`;
    }).join("; "));
  }
  if (e.workingSeconds) parts.push(`${roughTime(e.workingSeconds.p10, e.workingSeconds.p90)} of agents' compute time`);
  if (parts.length === 0 && e.outputTokens) parts.push(`${tokenWords(e.outputTokens.p10)} to ${tokenWords(e.outputTokens.p90)} output tokens`);
  return `${head}: ${parts.join("; ")} (from ${estimateSource(e)})`;
}

/** A value rounded to one significant figure: 3.2 → 3, 9.8 → 10, 0.42 → 0.4. */
export function roughly(v: number): number {
  if (!(v > 0) || !Number.isFinite(v)) return 0;
  const exp = Math.floor(Math.log10(v));
  return exp < 0 ? Math.round(v * 10 ** -exp) / 10 ** -exp : Math.round(v / 10 ** exp) * 10 ** exp;
}

/** Money to one significant figure: "$3", "$10", "$0.4". */
export function rough(v: number, currency: string): string {
  const r = roughly(v);
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency, minimumFractionDigits: 0, maximumSignificantDigits: 1 }).format(r);
  } catch {
    return moneyWords(r, currency);
  }
}

/** A time range to one significant figure, in one unit when both ends share it: "20 to 90 min", "30 min to 6 hours",
 * "5 to 20 hours"; "2 hours" when the ends are the same. Minutes below 100, then hours below 48, then days. */
export function roughTime(low: number, high: number): string {
  const split = (s: number): [number, string, string] => {
    if (roughly(s / 60) < 100) return [Math.max(1, roughly(s / 60)), "min", "min"];
    if (roughly(s / 3600) < 48) return [roughly(s / 3600), "hour", "hours"];
    return [roughly(s / 86400), "day", "days"];
  };
  const [a, oneA, manyA] = split(low), [b, oneB, manyB] = split(high);
  const n = (v: number) => String(Math.round(v * 10) / 10);
  if (a === b && manyA === manyB) return `${n(b)} ${b === 1 ? oneB : manyB}`;
  if (manyA === manyB) return `${n(a)} to ${n(b)} ${manyB}`;
  return `${n(a)} ${a === 1 ? oneA : manyA} to ${n(b)} ${b === 1 ? oneB : manyB}`;
}

/** What an epic's closed children spent: "Spent $4.10 on 2 closed children"; undefined for an issue or with nothing spent. */
export function estimateSpentWords(e: LineageEstimate): string | undefined {
  if (!e.spent || !spent(e.spent)) return undefined;
  const on = e.closedChildren !== undefined ? ` on ${plural(e.closedChildren, "closed child", "closed children")}` : "";
  return `Spent ${costWords(e.spent)}${on}`;
}

/** The range, for the line's title: "8 in 10 like it: $1.10 to $9.80, 12K to 140K output tokens, 30m to 6h of
 * work. Lead time 3h to 2d: it varies with the queue." */
export function estimateRangeWords(e: LineageEstimate): string | undefined {
  if (!hasFigures(e)) return undefined;
  let words = `8 in 10 like it: ${ranges(e).join(", ")}.`;
  if (e.leadTimeSeconds) words += ` Lead time ${timeWords(e.leadTimeSeconds.p10)} to ${timeWords(e.leadTimeSeconds.p90)}: it varies with the queue.`;
  return words;
}

/** A child's estimate in an epic's Plan, rounded as the line is: "est. $3 · 2 hours"; undefined with no figures. */
export function childEstimateWords(e: LineageEstimate): string | undefined {
  if (!hasFigures(e)) return undefined;
  const parts: string[] = [];
  const priced = Object.entries(e.cost ?? {}).sort(([a], [b]) => a.localeCompare(b));
  if (priced.length > 0) parts.push(priced.map(([currency, r]) => rough(r.median, currency)).join(" + "));
  if (e.workingSeconds) parts.push(roughTime(e.workingSeconds.median, e.workingSeconds.median));
  if (parts.length === 0 && e.outputTokens) parts.push(`${tokenWords(e.outputTokens.median)} output tokens`);
  return `est. ${parts.join(" · ")}`;
}

const levelWords: Record<string, [string, string]> = {
  story: ["story", "stories"], task: ["task", "tasks"], spike: ["spike", "spikes"], bug: ["bug", "bugs"],
};
const typeWords: Record<string, [string, string]> = { bug: ["bug", "bugs"], enhancement: ["enhancement", "enhancements"] };

/** The closed issues it was made from: "31 closed stories", "12 closed bugs", "40 closed issues". */
export function estimateSource(e: LineageEstimate): string {
  const kind = (e.matchedBy === "level" ? levelWords[e.level ?? ""] : e.matchedBy === "type" ? typeWords[e.type ?? ""] : undefined)
    ?? ["issue", "issues"];
  return plural(e.matches, `closed ${kind[0]}`, `closed ${kind[1]}`);
}

function ranges(e: LineageEstimate): string[] {
  const span = (r: LineageEstimateRange, words: (v: number) => string) => `${words(r.p10)} to ${words(r.p90)}`;
  const parts: string[] = [];
  const low = money(e.cost, "p10");
  const high = money(e.cost, "p90");
  if (low && high) parts.push(`${low} to ${high}`);
  if (e.outputTokens) parts.push(`${span(e.outputTokens, tokenWords)} output tokens`);
  if (e.workingSeconds) parts.push(`${span(e.workingSeconds, timeWords)} of work`);
  return parts;
}

function money(cost: Record<string, LineageEstimateRange> | undefined, at: "p10" | "p90"): string | undefined {
  const priced = Object.entries(cost ?? {}).sort(([a], [b]) => a.localeCompare(b));
  if (priced.length === 0) return undefined;
  return priced.map(([currency, r]) => moneyWords(r[at], currency)).join(" + ");
}

/** A closed issue's or epic's estimate against what it took (#3561): "Estimated $3.20, 2h 10m of work; actual
 * $4.10, 3h of work". Undefined while open, before work started, or when the estimate then had no figures. */
export function actualWords(e: LineageEstimate): string | undefined {
  const kept = e.kept;
  if (!kept || !e.actual) return undefined;
  const said: string[] = [];
  const priced = Object.entries(kept.cost ?? {}).sort(([a], [b]) => a.localeCompare(b));
  if (priced.length > 0) said.push(priced.map(([currency, v]) => moneyWords(v, currency)).join(" + "));
  if (kept.workingSeconds !== undefined) said.push(`${timeWords(kept.workingSeconds)} of work`);
  if (said.length === 0) return undefined;
  const took = [costWords(e.actual)];
  if (kept.workingSeconds !== undefined) took.push(`${timeWords(e.actual.workingSeconds)} of work`);
  return `Estimated ${said.join(", ")}; actual ${took.join(", ")}`;
}
