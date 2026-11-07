// Move to Machine… (#3790): which machines a session can move to.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { moveTargets, whatGoes } = await load("src/model/moveToMachine.ts");

test("the others that are online, by name, never its own host", () => {
  const hosts = [
    { id: "mac", name: "Mac", state: "online" },
    { id: "pc2", name: "PC 10", state: "online" },
    { id: "pc1", name: "PC 9", state: "needsUpdate" },
    { id: "box", name: "Box", state: "offline" },
  ];
  assert.deepEqual(moveTargets(hosts, "mac").map((h) => h.id), ["pc1", "pc2"]);
  assert.deepEqual(moveTargets(hosts, "pc1").map((h) => h.id), ["mac", "pc2"]);
});

test("a working session is told its turn stops", () => {
  assert.match(whatGoes(true), /Its turn stops here, and it carries on there\.$/);
  assert.doesNotMatch(whatGoes(false), /turn stops/);
});
