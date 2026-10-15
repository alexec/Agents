// The Time page's bars (#852): the same answers as TimeHistoryTests in Swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const time = await load("src/model/time.ts");

const bucket = (b) => ({ agent: 0, tools: 0, others: 0, person: 0, turns: 0, ...b });

function history() {
  const h = { hours: {}, days: {}, now: "2026-10-12T15" };
  const add = (b, runtime, hour) => {
    (h.hours[hour] ??= {})[runtime] = b;
    (h.days[hour.slice(0, 10)] ??= {})[runtime] = b;
  };
  add(bucket({ agent: 3600, tools: 1800, turns: 2 }), "claude", "2026-10-12T09");
  add(bucket({ person: 600, turns: 1 }), "codex", "2026-10-10T09");
  return h;
}

test("W stacks each day by kind and averages over the days with time", () => {
  const chart = time.timeChart(history(), "W");
  assert.equal(chart.bars.length, 7);
  assert.equal(chart.bars[6].time.agent, 3600);
  assert.equal(time.timeTotal(chart.time), 6000);
  assert.equal(chart.average, 3000);
  assert.deepEqual(chart.shares.map((s) => s.runtime), ["claude", "codex"]);
  assert.equal(time.timePercent(chart, chart.time.person), "10%");
});

test("D is today by the hour, and its figure is the day's total", () => {
  const chart = time.timeChart(history(), "D");
  assert.equal(chart.bars.length, 24);
  assert.equal(chart.bars[9].total, 5400);
  assert.equal(chart.average, 5400);
});

test("times read at a glance", () => {
  assert.equal(time.timeWords(42), "42s");
  assert.equal(time.timeWords(12 * 60), "12m");
  assert.equal(time.timeWords(3 * 3600 + 20 * 60), "3h 20m");
  assert.equal(time.timeWords(2 * 3600), "2h");
  assert.equal(time.timeWords(140 * 3600 + 59), "140h");
});
