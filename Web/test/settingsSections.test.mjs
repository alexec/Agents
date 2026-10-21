// Settings' sections, one file each, listed in src/views/settings/sections.ts (#2020).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { settingsSections, sectionsIn } = await load("src/views/settings/sections.ts");
const store = (role) => ({ person: { value: role ? { role } : null } });

test("each group's sections are in the order the page has always drawn them", () => {
  const names = (scope, role) => sectionsIn(scope, store(role)).map((s) => s.name);
  assert.deepEqual(names("thisDevice"), ["appearance", "sidebar", "finishedChats"]);
  assert.deepEqual(names("you"), ["gitAccess", "machines", "backups", "serverBackups", "userScope", "signIns"]);
  assert.deepEqual(names("controlPlane", "admin"), ["people", "groups", "channels", "signInProviders", "providers"]);
  assert.deepEqual(names("controlPlane", "member"), ["people", "groups", "channels", "providers"]);
});

test("the list is sorted by name, a line each, and no two share a place", () => {
  const names = settingsSections.map((s) => s.name);
  assert.deepEqual(names, [...names].sort());
  const places = settingsSections.map((s) => `${s.scope} ${s.order}`);
  assert.equal(new Set(places).size, places.length);
});
