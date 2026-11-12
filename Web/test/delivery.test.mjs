// Reports ▸ Planning's Delivery row (#4555): a card a figure, its words, its band and its line of weeks.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const d = await load("src/model/delivery.ts");

const weeks = (...values) => values.map((v, i) => ({ since: i * 604800, count: v === null ? 0 : 1, ...(v === null ? {} : { value: v }) }));
const none = { count: 0, weeks: weeks(null, null, null, null) };
const delivery = {
  since: 0, at: 2419200, windowDays: 28,
  leadTime: { value: 7200, p90: 36000, count: 12, weeks: weeks(3600, 7200, null, 9000), band: "elite" },
  deploymentFrequency: { value: 2.5, count: 10, weeks: weeks(2, 3, 2, 3), band: "high" },
  changeFailureRate: { value: 0.125, count: 40, weeks: weeks(0, 0.1, 0.2, 0.1), band: "medium" },
  recoveryTime: none,
  reworkRate: { value: 0.3, count: 1, weeks: weeks(null, null, null, 0.3) },
  flowEfficiency: none,
  approvalWait: { value: 1800, p90: 5400, count: 5, weeks: weeks(null, 1800, 1200, 2400) },
  approvalShare: { value: 0.2, count: 40, weeks: weeks(0, 0, 0, 0) },
  ciTimeToGreen: { value: 600, p90: 1200, count: 40, weeks: weeks(500, 600, 700, 600) },
  failedRounds: { value: 0.4, count: 40, weeks: weeks(0, 0, 0, 0) },
};

test("a card a figure, in the row's order, with its words, its band and what it is made from", () => {
  const cards = d.deliveryCards(delivery);
  assert.deepEqual(cards.map((c) => c.key), ["leadTime", "deploymentFrequency", "changeFailureRate", "recoveryTime", "reworkRate",
    "flowEfficiency", "approvalWait", "ciTimeToGreen"]);
  const [lead, freq, failure, recovery, rework, , wait, ci] = cards;
  assert.deepEqual([lead.value, lead.detail, lead.band], ["2h", "median of 12 issues · p90 10h", "Elite"]);
  assert.deepEqual([freq.value, freq.detail, freq.band], ["2.5 a week", "10 releases", "High"]);
  assert.deepEqual([failure.value, failure.detail, failure.band], ["13%", "of 40 merged PRs", "Medium"]);
  assert.deepEqual([recovery.value, recovery.band, recovery.weeks], ["—", undefined, [null, null, null, null]]);
  assert.equal(rework.detail, "of 1 PR");
  assert.equal(wait.detail, "median of 5 PRs · p90 1h 30m · 20% of PRs waited");
  assert.equal(ci.detail, "median of 40 PRs · p90 20m · 0.4 failed rounds a PR");
  assert.deepEqual(lead.weeks, [3600, 7200, null, 9000]);
  // Past 2 days, in days and hours.
  const long = d.deliveryCards({ ...delivery, leadTime: { ...delivery.leadTime, value: 51 * 3600 + 300, p90: 112 * 3600 } })[0];
  assert.deepEqual([long.value, long.detail], ["2d 3h", "median of 12 issues · p90 4d 16h"]);
});

test("a repo's name is its owner and name", () => {
  assert.equal(d.repoTitle("github:repo:#alexec/agents"), "alexec/agents");
  assert.equal(d.repoTitle("linear:repo:#eng"), "eng");
  assert.equal(d.repoTitle("github:alexec/agents"), "alexec/agents");
});

test("the line breaks at a week with no value, and a lone week is a tick", () => {
  assert.equal(d.sparkPath([null, null, null, null], 90, 20), "");
  assert.equal(d.sparkPath([1, 2, null, 3], 90, 20), "M0 20 L30 10 M90 0 L88 0");
  assert.equal(d.sparkPath([null, 5, null, null], 90, 20), "M30 10 L32 10");
  // All the same: a flat line through the middle.
  assert.equal(d.sparkPath([2, 2, 2, 2], 90, 20), "M0 10 L30 10 L60 10 L90 10");
});

test("the note says where the bands come from", () => {
  assert.match(d.deliveryNote, /Bands are DORA’s, from teams of people; agents merge many small PRs/);
});
