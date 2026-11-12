// Velocity's bars (#4598): the PRs that landed, from velocity/history, in the usage charts' ranges.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const velocity = await load("src/model/velocity.ts");

function history() {
  const h = { hours: {}, days: {}, now: "2026-10-12T16" };
  const add = (repo, hour, merged, reverted = 0) => {
    const into = ((h.hours[hour] ??= {})[repo] ??= { merged: 0, reverted: 0 });
    into.merged += merged; into.reverted += reverted;
    const day = ((h.days[hour.slice(0, 10)] ??= {})[repo] ??= { merged: 0, reverted: 0 });
    day.merged += merged; day.reverted += reverted;
  };
  add("github:alexec/agents", "2026-10-12T09", 3);
  add("github:alexec/agents-site", "2026-10-12T15", 1, 1);
  add("github:alexec/agents", "2026-10-10T11", 6);
  add("github:alexec/agents", "2026-08-01T11", 50);
  return h;
}

test("D is today by the hour, and its figure is the day's", () => {
  const chart = velocity.velocityChart(history(), "D");
  assert.equal(chart.bars.length, 24);
  assert.equal(chart.bars[9].value, 3);
  assert.equal(chart.bars[15].value, 1);
  assert.equal(chart.total, 4);
  assert.equal(chart.average, 4);
  assert.equal(chart.reverted, 1);
});

test("W is seven days; the average is over the days with any PR; shares by repository, largest first", () => {
  const chart = velocity.velocityChart(history(), "W");
  assert.equal(chart.bars.length, 7);
  assert.equal(chart.bars[6].value, 4);
  assert.equal(chart.bars[4].value, 6);
  assert.equal(chart.total, 10);
  assert.equal(chart.average, 5);
  assert.deepEqual(chart.shares, [{ repo: "github:alexec/agents", value: 9 }, { repo: "github:alexec/agents-site", value: 1 }]);
});

test("3M is thirteen weeks, ending today, and reaches back to August", () => {
  const chart = velocity.velocityChart(history(), "3M");
  assert.equal(chart.bars.length, 13);
  assert.equal(chart.bars[12].value, 10);
  assert.equal(chart.total, 60);
});

test("an empty range has no bars to draw", () => {
  const chart = velocity.velocityChart({ hours: {}, days: {}, now: "2026-10-12T16" }, "M");
  assert.equal(chart.bars.length, 30);
  assert.equal(chart.total, 0);
  assert.equal(chart.average, 0);
  assert.equal(velocity.revertWords(chart), "No reverts.");
});

test("the words: PRs, the repository without its forge, and the reverts", () => {
  assert.equal(velocity.prWords(46), "46 PRs");
  assert.equal(velocity.prWords(1), "1 PR");
  assert.equal(velocity.prWords(0), "0 PRs");
  assert.equal(velocity.prWords(2.25), "2.3 PRs");
  assert.equal(velocity.prWords(46.4), "46 PRs");
  assert.equal(velocity.repoWords("github:alexec/agents"), "alexec/agents");
  assert.equal(velocity.revertWords({ reverted: 1 }), "Including 1 revert.");
  assert.equal(velocity.revertWords({ reverted: 4 }), "Including 4 reverts.");
  assert.equal(velocity.velocityHeadline, "PRs a day");
});
