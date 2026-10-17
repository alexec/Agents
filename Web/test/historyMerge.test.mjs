// Every host's history in the viewer's own day (#1267): the same answers as HistoryMergeTests in
// Swift, a devbox in UTC and a browser in PDT, as in the #1136 walk.
process.env.TZ = "America/Los_Angeles";
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const usage = await load("src/model/usage.ts");
const time = await load("src/model/time.ts");

const usd = (amount) => ({ cost: { USD: amount }, inputTokens: 0, outputTokens: 0, thoughtTokens: 0,
  cachedReadTokens: 0, cachedWriteTokens: 0, turns: 1, unpricedTurns: 0 });
const mac = () => ({ hours: { "2026-10-16T09": { claude: usd(1) } }, days: { "2026-10-16": { claude: usd(1) } },
  now: "2026-10-16T20", timeZone: "America/Los_Angeles" });
const devbox = () => ({ hours: { "2026-10-17T02": { codex: usd(2) } },
  days: { "2026-10-17": { codex: usd(2) }, "2026-09-01": { codex: usd(5) } }, now: "2026-10-17T03", timeZone: "UTC" });

test("a server's hour goes in the viewer's hour and day, not its own", () => {
  const merged = usage.mergeUsage([mac(), devbox()]);
  assert.deepEqual(merged.hours["2026-10-16T19"].codex.cost, { USD: 2 });
  assert.equal(merged.hours["2026-10-17T02"], undefined);
  assert.deepEqual(merged.days["2026-10-16"].codex.cost, { USD: 2 });
  assert.deepEqual(merged.days["2026-10-16"].claude.cost, { USD: 1 });
  assert.equal(merged.days["2026-10-17"], undefined);
  assert.deepEqual(merged.days["2026-09-01"].codex.cost, { USD: 5 });
  assert.equal(merged.now, "2026-10-16T20");
});

test("the week chart counts the server's work on the 16th", () => {
  const merged = usage.mergeUsage([mac(), devbox()]);
  const week = usage.usageChart(merged, "W", "cost");
  assert.equal(week.bars.at(-1).stamp, "2026-10-16");
  assert.equal(week.bars.at(-1).value, 3);
  assert.equal(week.total, 3);
  const today = usage.usageChart(merged, "D", "cost");
  assert.equal(today.bars.find((b) => b.stamp === "2026-10-16T19").value, 2);
});

test("a host in the viewer's zone, too old to say, or in a zone unknown here, is added as it is", () => {
  const old = { ...mac(), timeZone: undefined };
  const odd = { ...mac(), timeZone: "Nowhere/Atlantis" };
  const merged = usage.mergeUsage([mac(), old, odd]);
  assert.deepEqual(merged.hours["2026-10-16T09"].claude.cost, { USD: 3 });
  assert.equal(merged.days["2026-10-16"].claude.turns, 3);
  assert.equal(usage.mergeUsage([]), undefined);
});

test("a zone with a half hour, and a summer-time change, read exactly", () => {
  assert.equal(usage.stampDateIn("2026-10-17T02", "Asia/Kolkata").toISOString(), "2026-10-16T20:30:00.000Z");
  assert.equal(usage.stampDateIn("2026-11-01T01", "America/New_York").toISOString(), "2026-11-01T05:00:00.000Z");
  assert.equal(usage.stampDateIn("2026-11-01T03", "America/New_York").toISOString(), "2026-11-01T08:00:00.000Z");
});

test("time moves the same way, and the recap stays the home host's", () => {
  const bucket = { agent: 600, tools: 0, others: 0, person: 0, turns: 1 };
  const home = { hours: {}, days: {}, now: "2026-10-16T20", timeZone: "America/Los_Angeles",
    recap: { "2026-10-16": { agents: 0, peakAgents: 3, longestClear: 0 } }, records: {} };
  const server = { hours: { "2026-10-17T02": { codex: bucket } }, days: { "2026-10-17": { codex: bucket } },
    now: "2026-10-17T03", timeZone: "UTC", recap: { "2026-10-17": { agents: 0, peakAgents: 9, longestClear: 0 } }, records: {} };
  const merged = time.mergeTime([home, server]);
  assert.equal(merged.days["2026-10-16"].codex.agent, 600);
  assert.deepEqual(merged.recap, home.recap);
  const week = time.timeChart(merged, "W");
  assert.equal(week.bars.at(-1).stamp, "2026-10-16");
  assert.equal(week.bars.at(-1).total, 600);
});
