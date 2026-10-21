// Settings ▸ Groups (#1761): the same words as GroupWords in Packages/AgentsKit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const g = await load("src/model/teamGroups.ts");
const sam = { id: "sam", name: "Sam" };
const kim = { id: "kim", name: "Kim" };

test("groups: members are everyone or named", () => {
  assert.equal(g.members({ id: "g", name: "All", everyone: true, members: [] }, [sam]), "Everyone");
  assert.equal(g.members({ id: "g", name: "P", everyone: false, members: ["sam", "kim"] }, [sam, kim]), "Sam, Kim");
  assert.equal(g.members({ id: "g", name: "P", everyone: false, members: ["gone"] }, [sam]), "Someone removed");
  assert.equal(g.members({ id: "g", name: "P", everyone: false, members: [] }, []), "No one");
});

test("groups: a provider is for its group or the admins", () => {
  const platform = { id: "g1", name: "Platform", everyone: false, members: ["sam"] };
  const given = { id: "do", name: "DigitalOcean", group: "g1", mayUse: false };
  const none = { id: "dk", name: "Docker" };
  assert.equal(g.providerLine(given, [platform]), "For Platform");
  assert.equal(g.providerLine(none, [platform]), "For admins only");
  assert.equal(g.providerLine(none, []), null);
  assert.equal(g.providersOf(platform, [given, none]), "DigitalOcean");
  assert.equal(g.mayNotUse(given, [platform]), "Only Platform can start machines from DigitalOcean.");
  assert.equal(g.usable(given), false);
  assert.equal(g.usable(none), true);
});
