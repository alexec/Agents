// The bars of the Time page (#852), as AgentsKitCore's TimeChart works them out, so the page says
// what the window's and the Remote's say. Each bar is stacked by kind of time. Every stamp is the
// host's, counted back from history.now; nothing asks the browser's clock what today is.
import type { LineageDeliveryFigure, TimeBucket, TimeHistory } from "../protocol/generated";
import { mergeTiers, usageSlots, type UsageRange } from "./usage";

export type TimeKind = "agent" | "tools" | "others" | "person";
/** Drawn in this order from the bottom: TimeKind.allCases. */
export const timeKinds: readonly TimeKind[] = ["agent", "tools", "others", "person"];
export const timeKindTitles: Record<TimeKind, string> = {
  agent: "Agent", tools: "Tools", others: "Waiting on others", person: "Waiting for you",
};

export interface TimeBar { stamp: string; start: Date; time: TimeBucket; total: number }
export interface TimeShare { runtime: string; time: TimeBucket; total: number }

export interface TimeChart {
  range: UsageRange;
  bars: TimeBar[];
  /** The whole range, by kind. */
  time: TimeBucket;
  /** The whole range, by runtime, most time first. */
  shares: TimeShare[];
  /** Per day over the days with any time; for D, the day's total. */
  average: number;
}

export function emptyTime(): TimeBucket {
  return { agent: 0, tools: 0, others: 0, person: 0, turns: 0 };
}

export const timeTotal = (b: TimeBucket) => b.agent + b.tools + b.others + b.person;

function add(into: TimeBucket, b: TimeBucket): void {
  into.agent += b.agent;
  into.tools += b.tools;
  into.others += b.others;
  into.person += b.person;
  into.turns += b.turns;
}

/**
 * Every host's time added up in this browser's days (#1267): TimeHistory.merged. The recap and the
 * records are the first history's, the home host's: one host's figures, which do not add up.
 */
export function mergeTime(histories: readonly TimeHistory[]): TimeHistory | undefined {
  const first = histories[0];
  if (!first) return undefined;
  return { ...mergeTiers(histories, emptyTime, add), recap: first.recap, records: first.records };
}

export function timeChart(history: TimeHistory, range: UsageRange): TimeChart {
  const slots = usageSlots(history.now, range);
  const tier = range === "D" ? history.hours : history.days;
  const merged = emptyTime();
  const byRuntime: Record<string, TimeBucket> = {};
  const daysWithData = new Set<string>();
  const bars = slots.map((slot) => {
    const bucket = emptyTime();
    for (const key of slot.keys) {
      const runtimes = tier[key];
      if (!runtimes) continue;
      for (const [runtime, b] of Object.entries(runtimes)) {
        add(bucket, b);
        add(byRuntime[runtime] ??= emptyTime(), b);
      }
      if (Object.values(runtimes).some((b) => timeTotal(b) > 0)) daysWithData.add(key.slice(0, 10));
    }
    add(merged, bucket);
    return { stamp: slot.stamp, start: slot.start, time: bucket, total: timeTotal(bucket) };
  });
  const total = timeTotal(merged);
  return {
    range, bars, time: merged,
    shares: Object.entries(byRuntime).map(([runtime, time]) => ({ runtime, time, total: timeTotal(time) }))
      .filter((s) => s.total > 0)
      .sort((a, b) => b.total - a.total || a.runtime.localeCompare(b.runtime)),
    average: range === "D" ? total : total / Math.max(1, daysWithData.size),
  };
}

/** A share of the whole, as a whole percent: TimeChart.percent. */
export function timePercent(chart: TimeChart, seconds: number): string {
  const total = timeTotal(chart.time);
  return total > 0 ? `${Math.round((seconds / total) * 100)}%` : "0%";
}

/** 45s, 12m, 3h 20m, 140h: TimeChart.words. */
export function timeWords(seconds: number): string {
  const s = Math.max(0, seconds);
  if (s < 60) return `${Math.round(s)}s`;
  const minutes = Math.round(s / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours >= 100) return `${hours}h`;
  const rest = minutes % 60;
  return rest === 0 ? `${hours}h` : `${hours}h ${rest}m`;
}

/** Reports ▸ Time's line on how long PRs waited for the person (#4553), from a host's time/history: the median
 * over its 4 weeks. Null when no PR had an answer, or the host is too old to say. */
export function approvalWaitWords(wait: LineageDeliveryFigure | undefined): string | null {
  if (!wait || wait.value === undefined || wait.count === 0) return null;
  const prs = wait.count === 1 ? "1 PR" : `${wait.count} PRs`;
  return `PRs waited a median of ${timeWords(wait.value)} for a person's answer (${prs}, last ${wait.weeks.length || 4} weeks).`;
}
