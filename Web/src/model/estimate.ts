// The words for an estimate (#3560) on Work's issue and epic pages and in an epic's Plan, from
// lineage/estimate (#3559), as EstimateWords has them on the window. The figures are dollars, output
// tokens and the agents' working time; lead time shows only as a range, as it varies with the queue
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

/** The page's line: "Estimate: about $3.20, 45K output tokens, 2h 10m of work (from 31 closed stories)"; for
 * an epic, "Estimate for 3 open children: …". With too little history, "Not enough past work to estimate" and nothing else. */
export function estimateLine(e: LineageEstimate): string {
  if (!hasFigures(e)) return notEnough;
  const head = e.openChildren !== undefined ? `Estimate for ${plural(e.openChildren, "open child", "open children")}` : "Estimate";
  return `${head}: about ${figures(e, true).join(", ")} (from ${estimateSource(e)})`;
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
  let words = `8 in 10 like it: ${figures(e, false).join(", ")}.`;
  if (e.leadTimeSeconds) words += ` Lead time ${timeWords(e.leadTimeSeconds.p10)} to ${timeWords(e.leadTimeSeconds.p90)}: it varies with the queue.`;
  return words;
}

/** A child's estimate in an epic's Plan: "est. $3.20 · 2h 10m"; undefined with no figures. */
export function childEstimateWords(e: LineageEstimate): string | undefined {
  if (!hasFigures(e)) return undefined;
  const parts: string[] = [];
  const m = money(e.cost, "median");
  if (m) parts.push(m);
  if (e.workingSeconds) parts.push(timeWords(e.workingSeconds.median));
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

function figures(e: LineageEstimate, median: boolean): string[] {
  const span = (r: LineageEstimateRange, words: (v: number) => string) => median ? words(r.median) : `${words(r.p10)} to ${words(r.p90)}`;
  const parts: string[] = [];
  if (median) {
    const m = money(e.cost, "median");
    if (m) parts.push(m);
  } else {
    const low = money(e.cost, "p10");
    const high = money(e.cost, "p90");
    if (low && high) parts.push(`${low} to ${high}`);
  }
  if (e.outputTokens) parts.push(`${span(e.outputTokens, tokenWords)} output tokens`);
  if (e.workingSeconds) parts.push(`${span(e.workingSeconds, timeWords)} of work`);
  return parts;
}

function money(cost: Record<string, LineageEstimateRange> | undefined, at: "median" | "p10" | "p90"): string | undefined {
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
