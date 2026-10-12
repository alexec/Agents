// The usage charts' bars (#823): the same answers as UsageHistoryTests in Swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const usage = await load("src/model/usage.ts");

const bucket = (b) => ({ cost: {}, inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0,
  cachedWriteTokens: 0, turns: 0, unpricedTurns: 0, ...b });

function history() {
  const h = { hours: {}, days: {}, now: "2026-10-12T16" };
  const add = (b, runtime, hour) => {
    (h.hours[hour] ??= {})[runtime] = b;
    const day = (h.days[hour.slice(0, 10)] ??= {});
    const was = day[runtime];
    day[runtime] = was ? bucket({ ...was, cost: { USD: (was.cost.USD ?? 0) + (b.cost.USD ?? 0) },
      inputTokens: was.inputTokens + b.inputTokens, unpricedTurns: was.unpricedTurns + b.unpricedTurns }) : b;
  };
  add(bucket({ cost: { USD: 4 }, inputTokens: 100, outputTokens: 50, cachedReadTokens: 9000, turns: 1 }), "claude", "2026-10-12T09");
  add(bucket({ cost: { USD: 1 }, inputTokens: 10, turns: 1 }), "codex", "2026-10-12T15");
  add(bucket({ cost: { USD: 6 }, turns: 1 }), "claude", "2026-10-10T11");
  add(bucket({ inputTokens: 5, turns: 1, unpricedTurns: 1 }), "grok", "2026-10-10T11");
  add(bucket({ cost: { USD: 100 } }), "claude", "2026-06-01T11");
  return h;
}

test("D is today by the hour", () => {
  const chart = usage.usageChart(history(), "D", "cost");
  assert.equal(chart.bars.length, 24);
  assert.equal(chart.bars[9].value, 4);
  assert.equal(chart.bars[15].value, 1);
  assert.equal(chart.total, 5);
  assert.equal(usage.usageHeadline(chart), "Total");
  assert.deepEqual(chart.shares.map((s) => s.runtime), ["claude", "codex"]);
});

test("W is seven days, and the average is over the days that have any", () => {
  const chart = usage.usageChart(history(), "W", "cost");
  assert.equal(chart.bars.length, 7);
  assert.equal(chart.bars[6].stamp, "2026-10-12");
  assert.equal(chart.bars[6].value, 5);
  assert.equal(chart.total, 11);
  assert.equal(chart.average, 5.5);
  assert.equal(chart.unpricedTurns, 1);
});

test("3M is thirteen weeks, the last ending today", () => {
  const chart = usage.usageChart(history(), "3M", "cost");
  assert.equal(chart.bars.length, 13);
  assert.equal(chart.bars[12].value, 11);
  assert.equal(chart.total, 11);
});

test("tokens draw what was asked and answered, and say the cache reads apart", () => {
  const chart = usage.usageChart(history(), "D", "tokens");
  assert.equal(chart.total, 160);
  assert.equal(chart.cachedReadTokens, 9000);
  assert.equal(chart.currency, null);
  assert.equal(usage.tokenWords(716_000_000), "716M");
});
