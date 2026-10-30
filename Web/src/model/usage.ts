// The bars of a usage chart (#823), as AgentsKitCore's UsageChart works them out, so the page's
// Cost charts say what the window's and the Remote's say. Every stamp is the host's, counted
// back from history.now; nothing asks the browser's clock what today is. mergeUsage puts every
// host's stamps in this browser's days first (#1267).
import type { UsageBucket, UsageHistory } from "../protocol/generated";

export type UsageRange = "D" | "W" | "M" | "3M";
export type UsageMetric = "cost" | "tokens";
export const usageRanges: readonly UsageRange[] = ["D", "W", "M", "3M"];
/** Each range in words, in its Range select (#2142). */
export const usageRangeWords: Record<UsageRange, string> = { D: "Day", W: "Week", M: "Month", "3M": "3 months" };

export interface UsageBar { stamp: string; start: Date; value: number }
export interface UsageShare { runtime: string; value: number }

export interface UsageChart {
  range: UsageRange;
  metric: UsageMetric;
  /** The currency most was spent in; null for tokens or when nothing was priced. */
  currency: string | null;
  bars: UsageBar[];
  shares: UsageShare[];
  total: number;
  /** Per day over the days with any data; for D, the day's total. */
  average: number;
  cachedReadTokens: number;
  unpricedTurns: number;
  otherCurrencies: string[];
}

/** Seeded cost that spend.json never said the runtime of: UsageHistory.unattributed. */
export const unattributed = "";

const pad = (n: number) => String(n).padStart(2, "0");
export const dayStamp = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
export const hourStamp = (d: Date) => `${dayStamp(d)}T${pad(d.getHours())}`;

/** A stamp read back as a local date: UsageChart.date. */
export function stampDate(stamp: string): Date | null {
  const n = stamp.split(/[-T]/).map(Number);
  if (n.length < 3 || n.some(Number.isNaN)) return null;
  return new Date(n[0]!, n[1]! - 1, n[2]!, n[3] ?? 0);
}

/** One host's tiers, as UsageHistory and TimeHistory both hold them. */
export interface HistoryTiers<B> {
  hours: Record<string, Record<string, B>>;
  days: Record<string, Record<string, B>>;
  now: string;
  timeZone?: string;
}

/** UsageHistory.hoursKept: a host drops its oldest hours past this many. */
const hoursKept = 168;

const zoneFormats = new Map<string, Intl.DateTimeFormat>();

/** How far `zone`'s clock is ahead of UTC at `ms`, in ms. Throws for a zone the browser does not know. */
function zoneOffset(ms: number, zone: string): number {
  let format = zoneFormats.get(zone);
  if (!format) {
    format = new Intl.DateTimeFormat("en-US", { timeZone: zone, hourCycle: "h23", year: "numeric", month: "2-digit",
      day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
    zoneFormats.set(zone, format);
  }
  const parts = format.formatToParts(new Date(ms));
  const n = (type: string) => Number(parts.find((p) => p.type === type)?.value);
  return Date.UTC(n("year"), n("month") - 1, n("day"), n("hour"), n("minute"), n("second")) - Math.floor(ms / 1000) * 1000;
}

/** A stamp read back in another zone: UsageChart.date with the host's calendar. */
export function stampDateIn(stamp: string, zone: string): Date | null {
  const n = stamp.split(/[-T]/).map(Number);
  if (n.length < 3 || n.some(Number.isNaN)) return null;
  const wall = Date.UTC(n[0]!, n[1]! - 1, n[2]!, n[3] ?? 0);
  const guess = wall - zoneOffset(wall, zone);
  return new Date(wall - zoneOffset(guess, zone));
}

/**
 * Every host's tiers as one, in this browser's days (#1267): HistoryMerge in AgentsKitCore. A host's
 * hours move into this browser's hours exactly; its days are made again from those hours, which are
 * whole from the oldest kept onwards (all of them while none was dropped). A day older than that goes
 * in the day here that holds its middle.
 */
export function mergeTiers<B>(hosts: readonly HistoryTiers<B>[], empty: () => B, add: (into: B, b: B) => void): HistoryTiers<B> {
  const here = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const out: HistoryTiers<B> = { hours: {}, days: {}, now: "", timeZone: here };
  const fold = (runtimes: Record<string, B>, tier: Record<string, Record<string, B>>, key: string) => {
    const into = (tier[key] ??= {});
    for (const [runtime, b] of Object.entries(runtimes)) add(into[runtime] ??= empty(), b);
  };
  for (const host of hosts) {
    let zone = host.timeZone && host.timeZone !== here ? host.timeZone : undefined;
    if (zone) {
      try { zoneOffset(Date.now(), zone); } catch { zone = undefined; }
    }
    if (!zone) {
      for (const [key, runtimes] of Object.entries(host.hours)) fold(runtimes, out.hours, key);
      for (const [key, runtimes] of Object.entries(host.days)) fold(runtimes, out.days, key);
      if (host.now > out.now) out.now = host.now;
      continue;
    }
    const keys = Object.keys(host.hours).sort();
    // The first of the host's days that is whole in its hours: the oldest hour's day while none was dropped.
    const oldest = keys[0]?.slice(0, 10);
    const whole = oldest === undefined ? undefined : keys.length < hoursKept ? oldest : `${oldest}~`;
    for (const key of keys) {
      const start = stampDateIn(key, zone);
      if (!start) continue;
      const hour = hourStamp(start);
      fold(host.hours[key]!, out.hours, hour);
      if (whole !== undefined && key.slice(0, 10) >= whole) fold(host.hours[key]!, out.days, hour.slice(0, 10));
    }
    for (const [key, runtimes] of Object.entries(host.days)) {
      if (whole !== undefined && key >= whole) continue;
      const start = stampDateIn(key, zone);
      if (start) fold(runtimes, out.days, dayStamp(new Date(start.getTime() + 12 * 3600_000)));
    }
    const now = stampDateIn(host.now, zone);
    if (now && hourStamp(now) > out.now) out.now = hourStamp(now);
  }
  return out;
}

/** Every host's use added up in this browser's days (#1267): UsageHistory.merged. */
export function mergeUsage(histories: readonly UsageHistory[]): UsageHistory | undefined {
  if (histories.length === 0) return undefined;
  return mergeTiers(histories, emptyBucket, add);
}

/** What the work asked for and got back; cache reads are said apart. */
export function freshTokens(b: UsageBucket): number {
  return b.inputTokens + b.outputTokens + b.thoughtTokens + b.cachedWriteTokens;
}

function emptyBucket(): UsageBucket {
  return { cost: {}, inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0,
    cachedWriteTokens: 0, turns: 0, unpricedTurns: 0 };
}

function add(into: UsageBucket, b: UsageBucket): void {
  for (const [currency, amount] of Object.entries(b.cost)) into.cost[currency] = (into.cost[currency] ?? 0) + amount;
  into.inputTokens += b.inputTokens;
  into.outputTokens += b.outputTokens;
  into.thoughtTokens += b.thoughtTokens;
  into.cachedReadTokens += b.cachedReadTokens;
  into.cachedWriteTokens += b.cachedWriteTokens;
  into.turns += b.turns;
  into.unpricedTurns += b.unpricedTurns;
}

const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);

export function usageChart(history: UsageHistory, range: UsageRange, metric: UsageMetric): UsageChart {
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

  const merged = emptyBucket();
  const byRuntime: Record<string, UsageBucket> = {};
  const daysWithData = new Set<string>();
  const slotBuckets = slots.map((slot) => {
    const bucket = emptyBucket();
    for (const key of slot.keys) {
      const runtimes = tier[key];
      if (!runtimes) continue;
      for (const [runtime, b] of Object.entries(runtimes)) {
        add(bucket, b);
        add(merged, b);
        add(byRuntime[runtime] ??= emptyBucket(), b);
      }
      daysWithData.add(key.slice(0, 10));
    }
    return bucket;
  });
  const currencies = Object.entries(merged.cost).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  const currency = metric === "cost" ? currencies[0]?.[0] ?? null : null;
  const value = (b: UsageBucket) => metric === "tokens" ? freshTokens(b) : currency ? b.cost[currency] ?? 0 : 0;
  const total = value(merged);
  return {
    range, metric, currency,
    bars: slots.map((slot, i) => ({ stamp: slot.stamp, start: slot.start, value: value(slotBuckets[i]!) })),
    shares: Object.entries(byRuntime).map(([runtime, b]) => ({ runtime, value: value(b) }))
      .filter((s) => s.value > 0)
      .sort((a, b) => b.value - a.value || a.runtime.localeCompare(b.runtime)),
    total,
    average: range === "D" ? total : total / Math.max(1, daysWithData.size),
    cachedReadTokens: merged.cachedReadTokens,
    unpricedTurns: merged.unpricedTurns,
    otherCurrencies: metric === "cost" ? currencies.slice(1).map(([c]) => c).sort() : [],
  };
}

/** 1.2K, 34M, 5.6B: UsageChart.tokenWords. */
export function tokenWords(value: number): string {
  return new Intl.NumberFormat("en", { notation: "compact", maximumSignificantDigits: 3 }).format(Math.round(value));
}

/** A figure of the chart's metric, in whole units as the window's money is. */
export function usageWords(chart: UsageChart, value: number): string {
  if (chart.metric === "tokens") return tokenWords(value);
  const currency = chart.currency ?? "USD";
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency, maximumFractionDigits: 0 }).format(value);
  } catch {
    return `${Math.round(value)} ${currency}`;
  }
}

/** Health's word above the figure. */
export const usageHeadline = (chart: UsageChart) => chart.range === "D" ? "Total" : "Daily average";
