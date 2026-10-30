// Reports ▸ Features (#2165), as FeatureWords and FeatureUsage.merged have it on the window: which
// methods the clients and agents called on the person's own machines, from each host's counts.
import type { FeatureUsage, FeatureUse } from "../protocol/generated";

/** Every host's counts as one: a feature's uses added up, its clients joined, its last use the
 * latest and the earliest first day; the least used first, as each host sorts. */
export function mergeFeatures(all: readonly FeatureUsage[]): FeatureUsage {
  const byMethod = new Map<string, FeatureUse>();
  for (const usage of all) {
    for (const f of usage.features) {
      const m = byMethod.get(f.method) ?? { method: f.method, week: 0, quarter: 0, clients: [] };
      const last = f.lastUsed !== undefined && f.lastUsed > (m.lastUsed ?? "") ? f.lastUsed : m.lastUsed;
      byMethod.set(f.method, { method: f.method, week: m.week + f.week, quarter: m.quarter + f.quarter,
        clients: [...new Set([...m.clients, ...f.clients])].sort(), ...(last !== undefined ? { lastUsed: last } : {}) });
    }
  }
  const features = [...byMethod.values()].sort((a, b) => a.quarter - b.quarter || a.week - b.week || (a.method < b.method ? -1 : a.method > b.method ? 1 : 0));
  const since = all.map((u) => u.since).filter((s): s is string => s !== undefined).sort()[0];
  return { days: Math.max(90, ...all.map((u) => u.days)), features, ...(since !== undefined ? { since } : {}) };
}

/** "7 this week · 30 in 90 days · mac, web". */
export function featureLine(f: FeatureUse, days: number): string {
  const parts = [`${f.week} this week`, `${f.quarter} in ${days} days`];
  if (f.clients.length > 0) parts.push(f.clients.join(", "));
  return parts.join(" · ");
}

export const featureUnused = "Not used";

export const noFeatures = "No machine counts features yet. Update your machines to see them.";

export function featuresNote(usage: FeatureUsage): string {
  const since = usage.since !== undefined ? ` Counted since ${usage.since}.` : " Nothing counted yet.";
  return `Each method a client or an agent called on your machines, the least used first.${since} The counts stay on your machines; what a call said is never kept.`;
}
