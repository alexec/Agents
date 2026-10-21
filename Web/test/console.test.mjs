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
});

test("the Console's pages go under their headings in order", () => {
  const groups = c.grouped(c.consoleSections).map(([g]) => g);
  assert.deepEqual(groups, ["Organisation", "Rules", "Records"]);
  assert.deepEqual(c.apps.map((a) => c.appTitle[a]), ["Workspace", "Console", "Reports"]);
});
