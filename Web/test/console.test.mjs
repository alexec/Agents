// The control plane's three apps (#1804): the Console's and Reports' routes and pages.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/console.ts");

test("#/console and #/reports open their apps, with a page or without", async () => {
  const { parseRoute, routeHash } = await load("src/route.ts");
  assert.deepEqual(parseRoute("#/console"), { app: "console" });
  assert.deepEqual(parseRoute("#/console/audit"), { app: "console", section: "audit" });
  assert.deepEqual(parseRoute("#/reports/spend"), { app: "reports", section: "spend" });
  assert.equal(routeHash({ app: "reports", section: "spend" }, undefined), "#/reports/spend");
  assert.equal(routeHash({ app: "console" }, undefined), "#/console");
  assert.deepEqual(parseRoute(routeHash({ app: "console", section: "a b" }, undefined)), { app: "console", section: "a b" });
});

test("a page not built yet, or not known, opens the app's first", () => {
  assert.equal(c.openSection("console", undefined).id, "overview");
  assert.equal(c.openSection("console", "nowhere").id, "overview");
  assert.equal(c.openSection("reports", undefined).id, "spend");
  for (const s of c.consoleSections.filter((x) => !x.built)) assert.equal(c.openSection("console", s.id).id, "overview");
  assert.equal(c.openSection("console", "machines").id, "machines");
});

test("the Console's pages go under their headings in order", () => {
  const groups = c.grouped(c.consoleSections).map(([g]) => g);
  assert.deepEqual(groups, ["Organisation", "Rules", "Records"]);
  assert.deepEqual(c.apps.map((a) => c.appTitle[a]), ["Workspace", "Console", "Reports"]);
});

const machine = (over = {}, host = {}) => ({
  host: { id: "H1", name: "Bea's Mac", platform: "macOS arm64", version: "0.9.0", state: "online", reach: "dialOut", ...host },
  ownerName: "Bea", bot: false, ...over,
});

test("Machines: out of date is missing, needing an update or older than the control plane", () => {
  assert.equal(c.compareVersions("0.8.2", "0.9.0"), -1);
  assert.equal(c.compareVersions("0.10.0", "0.9.0"), 1);
  assert.equal(c.compareVersions("0.9", "0.9.0"), 0);
  assert.equal(c.compareVersions("dev", "0.9.0"), 0);
  assert.equal(c.outOfDate(machine({}, { version: "0.8.0" }), "0.9.0"), true);
  assert.equal(c.outOfDate(machine({}, { state: "needsUpdate" }), "0.9.0"), true);
  assert.equal(c.outOfDate(machine({}, { missing: ["host.wire/2"] }), undefined), true);
  assert.equal(c.outOfDate(machine(), "0.9.0"), false);
});

test("Machines: filters, the summary and each row's words", () => {
  const list = [machine(), machine({ ownerName: "Nightly", bot: true }, { id: "H2", state: "offline", version: "0.8.0" }),
    machine({ ownerName: "", running: 3 }, { id: "H3", workspace: { providerName: "DigitalOcean" } })];
  assert.deepEqual(c.fleetShown(list, "offline", "0.9.0").map((m) => m.host.id), ["H2"]);
  assert.deepEqual(c.fleetShown(list, "outOfDate", "0.9.0").map((m) => m.host.id), ["H2"]);
  assert.equal(c.fleetShown(list, "all", "0.9.0").length, 3);
  assert.equal(c.fleetSummary(list, "0.9.0"), "3 machines · 2 online · 1 out of date");
  assert.deepEqual(list.map(c.ownerWords), ["Bea", "Nightly (bot)", "Nobody"]);
  assert.deepEqual(list.map(c.kindWords), ["macOS arm64", "macOS arm64", "DigitalOcean"]);
  assert.deepEqual(list.map(c.runningWords), ["—", "—", "3"]);
});
