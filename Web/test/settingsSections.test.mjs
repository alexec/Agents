// Settings' sections, one file each, listed in src/views/settings/sections.ts (#2020).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { settingsSections, sectionsIn } = await load("src/views/settings/sections.ts");
const store = (role) => ({ person: { value: role ? { role } : null } });

test("each group's sections are in their subject's order", () => {
  const names = (scope, role) => sectionsIn(scope, store(role)).map((s) => s.name);
  // By subject (#2157): Sidebar, Finished chats and Notifications are how this app works, though the Mac's host keeps them (#2079, #2805).
  assert.deepEqual(names("thisApp"), ["sidebar", "finishedChats", "notifications"]);
  assert.deepEqual(names("machines"), ["gitAccess", "machines", "backups", "desktopControl", "serverBackups", "agentRuntimes", "secrets"]);
  assert.deepEqual(names("agentConfiguration"), ["skills", "personas", "workflows"]);
  assert.deepEqual(names("controlPlane", "admin"), ["signIns", "people", "bots", "groups", "channels", "signInProviders", "policy", "providers"]);
  assert.deepEqual(names("controlPlane", "member"), ["signIns", "people", "groups", "channels", "policy", "providers"]);
});

test("the list is sorted by name, a line each, and no two share a place", () => {
  const names = settingsSections.map((s) => s.name);
  assert.deepEqual(names, [...names].sort());
  const places = settingsSections.map((s) => `${s.scope} ${s.order}`);
  assert.equal(new Set(places).size, places.length);
});
