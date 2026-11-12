// The Velocity bars (#4595, #4598): the pull requests that landed, from velocity/history, worked out
// as model/usage.ts works out Cost's, so the four Usage tabs read alike. One series: a merged revert
// is a PR that landed, and the line under the bars says how many of them were reverts (note 7).
import type { VelocityBucket, VelocityHistory } from "../protocol/generated";
import { mergeTiers, usageSlots, type UsageRange } from "./usage";

export interface VelocityBar { stamp: string; start: Date; value: number }
export interface VelocityShare { repo: string; value: number }

export interface VelocityChart {
  range: UsageRange;
  bars: VelocityBar[];
  /** By repository, largest first. */
  shares: VelocityShare[];
  total: number;
  reverted: number;
  /** Per day over the days with any PR; for D, the day's total. */
  average: number;
}

const emptyBucket = (): VelocityBucket => ({ merged: 0, reverted: 0 });
function add(into: VelocityBucket, b: VelocityBucket): void {
  into.merged += b.merged;
  into.reverted += b.reverted;
}

/** One host's history in this browser's days (#1267), as the usage charts move theirs. */
export function velocityHere(history: VelocityHistory): VelocityHistory {
  return mergeTiers([history], emptyBucket, add);
}

export function velocityChart(history: VelocityHistory, range: UsageRange): VelocityChart {
  const slots = usageSlots(history.now, range);
  const tier = range === "D" ? history.hours : history.days;
  const byRepo: Record<string, number> = {};
  const daysWithData = new Set<string>();
  let total = 0;
  let reverted = 0;
  const bars = slots.map((slot) => {
    let value = 0;
    for (const key of slot.keys) {
      const repos = tier[key];
      if (!repos) continue;
      for (const [repo, b] of Object.entries(repos)) {
        if (b.merged <= 0) continue;
        value += b.merged;
        reverted += b.reverted;
        byRepo[repo] = (byRepo[repo] ?? 0) + b.merged;
        daysWithData.add(key.slice(0, 10));
      }
    }
    total += value;
    return { stamp: slot.stamp, start: slot.start, value };
  });
  return {
    range, bars, total, reverted,
    shares: Object.entries(byRepo).map(([repo, value]) => ({ repo, value }))
      .sort((a, b) => b.value - a.value || a.repo.localeCompare(b.repo)),
    average: range === "D" ? total : total / Math.max(1, daysWithData.size),
  };
}

/** A repository as the shares say it: the PR node's repo without its forge (github:alexec/agents → alexec/agents). */
export const repoWords = (repo: string) => repo.replace(/^[a-z]+:/, "");

/** 46 PRs, 1 PR, 0.4 PRs: a figure of the chart, whole from 10 up. */
export function prWords(value: number): string {
  const n = new Intl.NumberFormat(undefined, { maximumFractionDigits: value < 10 ? 1 : 0 }).format(value);
  return `${n} ${n === "1" ? "PR" : "PRs"}`;
}

/** The fine line under the bars: always there, since none reverted is worth saying. */
export const revertWords = (chart: VelocityChart) =>
  chart.reverted === 0 ? "No reverts." : `Including ${chart.reverted} ${chart.reverted === 1 ? "revert" : "reverts"}.`;

/** Health's word above the figure: the daily average in every range, D's being the day's own (spec, Decisions). */
export const velocityHeadline = "PRs a day";
