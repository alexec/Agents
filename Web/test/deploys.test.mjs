// Reports ▸ Planning ▸ Delivery (#5245, spec 5239 board 5): the address, the four tiles of a target and the words.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const d = await load("src/model/deploys.ts");
const nav = await load("src/model/nav.ts");
const r = await load("src/route.ts");

const fig = (value, count, extra = {}) => ({ count, weeks: [], ...(value === undefined ? {} : { value }), ...extra });
const target = (change = {}) => ({
  component: "alexec/agents", environment: "github-releases", environmentRef: "github:environment:alexec/agents#github-releases",
  tier: "production", ended: 21, failed: 3, rollbacks: 1,
  deploymentFrequency: fig(4.2, 18), leadTime: fig(17 * 3600 + 48 * 60, 40, { p90: 51 * 3600 }),
  changeFailureRate: fig(4 / 21, 21), recoveryTime: fig(2 * 3600, 3),
  ...change,
});

test("the page is under Planning, at #/reports/value/delivery, with its range and tier after the ?", () => {
  const route = r.parseRoute("#/reports/value/delivery?range=threeMonths&tier=all");
  assert.equal(nav.routePageID("reports", route), "delivery");
  assert.equal(r.routeHash(route), "#/reports/value/delivery?range=threeMonths&tier=all");
  assert.deepEqual(nav.pageRoute("reports", nav.navPages.reports.find((p) => p.id === "delivery")), { nav: "reports", section: "value", item: "delivery" });
  assert.deepEqual(d.parseDeploysQuery("range=threeMonths&tier=all"), { range: "threeMonths", tier: "" });
  // None named: the last 30 days, production. A day is not offered.
  assert.deepEqual(d.parseDeploysQuery(undefined), { range: "month", tier: "production" });
  assert.deepEqual(d.parseDeploysQuery("range=day&tier=staging"), { range: "month", tier: "staging" });
  assert.equal(d.deploysQuery({ range: "week", tier: "" }), "range=week&tier=all");
});

test("a target's four tiles, in DORA's order, with what each is made from", () => {
  const tiles = d.deployTiles(target());
  assert.deepEqual(tiles.map((t) => [t.title, t.value, t.detail]), [
    ["Deploy frequency", "4.2 a week", "18 deploys went out"],
    ["Lead time for changes", "17h 48m", "median of 40 changes · p90 2d 3h"],
    ["Change failure rate", "19%", "3 failed, 1 rollback of 21 deploys"],
    ["Time to restore", "2h", "median of 3 recoveries"],
  ]);
  assert.equal(d.targetTitle(target()), "alexec/agents @ github-releases");
  assert.equal(d.targetLine(target(), 30), "18 deploys went out, 3 failed, in 30 days");
});

test("the docs' many deploys are a day; no failure and no change known say so", () => {
  const docs = d.deployTiles(target({ deploymentFrequency: fig(235, 235), failed: 0, rollbacks: 0, ended: 236,
    leadTime: fig(undefined, 0), changeFailureRate: fig(1 / 236, 236), recoveryTime: fig(undefined, 0) }));
  assert.equal(docs[0].value, "34 a day");
  assert.equal(docs[1].value, "—");
  assert.equal(docs[2].value, "0.4%");
  assert.deepEqual([docs[3].value, docs[3].detail], ["No failure", "nothing to restore"]);
  const open = d.deployTiles(target({ recoveryTime: fig(undefined, 0) }))[3];
  assert.deepEqual([open.value, open.detail], ["—", "not restored yet"]);
});

test("the page's words: the tier, too few deploys, and nothing in the tier", () => {
  assert.equal(d.askLine("The last 30 days", { range: "month", tier: "production" }), "The last 30 days · Tier: production");
  assert.equal(d.fewWords(target({ ended: 2 })), "Too few deploys for a figure that means much (2); shown dimmed.");
  assert.equal(d.noTargetsWords({ range: "month", tier: "production" }, "The last 30 days", 3),
    "No deploy to a production environment ended in the last 30 days. 3 environments of other tiers had some: choose Every tier to see them.");
  assert.equal(d.noTargetsWords({ range: "week", tier: "" }, "The last 7 days", 0), "No deploy ended in the last 7 days.");
});
