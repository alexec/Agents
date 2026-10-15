// The bars of the Time page (#852), as AgentsKitCore's TimeChart works them out, so the page says
// what the window's and the Remote's say. Each bar is stacked by kind of time. Every stamp is the
// host's, counted back from history.now; nothing asks the browser's clock what today is.
import type { TimeBucket, TimeHistory } from "../protocol/generated";
import { dayStamp, hourStamp, stampDate, type UsageRange } from "./usage";

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

const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);

export function timeChart(history: TimeHistory, range: UsageRange): TimeChart {
  const now = stampDate(history.now) ?? new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const slots: { stamp: string; start: Date; keys: string[] }[] = [];
  const tier = range === "D" ? history.hours : history.days;
  if (range === "D") {
    for (let hour = 0; hour < 24; hour++) {
      const start = new Date(today.getFullYear(), today.getMonth(), today.getDate(), hour);
      slots.push({ stamp: hourStamp(start), start, keys: [hourStamp(start)] });
    }
  } else if (range === "W" || range === "M") {
    const count = range === "W" ? 7 : 30;
    for (let back = count - 1; back >= 0; back--) {
      const start = addDays(today, -back);
      slots.push({ stamp: dayStamp(start), start, keys: [dayStamp(start)] });
    }
  } else {
    for (let week = 12; week >= 0; week--) {
      const start = addDays(today, -(week * 7 + 6));
      const keys = [0, 1, 2, 3, 4, 5, 6].map((n) => dayStamp(addDays(start, n)));
      slots.push({ stamp: keys[0]!, start, keys });
    }
  }

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
