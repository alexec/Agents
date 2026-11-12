// Move to Machine… (#3790): which machines a session can move to, and how a move goes (#4641).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { moveTargets, movingLine, whatGoes } = await load("src/model/moveToMachine.ts");
const { Work } = await load("src/model/store.ts");

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

test("the row says the branch's bytes from a megabyte, then the session", () => {
  assert.equal(movingLine("pc", 0, 0, false), "Moving to pc: sending its branch…");
  assert.equal(movingLine("pc", 4_200_000, 12_000_000, false), "Moving to pc: sending its branch, 4.2 MB of 12 MB…");
  assert.equal(movingLine("pc", 12_000_000, 12_000_000, true), "Moving to pc: sending the session…");
});

test("move/changed keeps a move under way and one that stopped, and drops one that is there", () => {
  const work = new Work();
  const move = { agentID: "A1", machine: "pc-id", machineName: "pc", folder: "/home/p/app", startedAt: 0,
    sent: 0, total: 0, branchSent: false, finished: false };
  work.apply("move/changed", move, "mac");
  assert.equal(work.moves.value.A1.machineName, "pc");
  work.apply("move/changed", { ...move, sent: 5, total: 9 }, "mac");
  assert.equal(work.moves.value.A1.sent, 5);
  work.apply("move/changed", { ...move, finished: true, problem: "“Fix” was not moved to pc: pc is offline. It stays here." }, "mac");
  assert.match(work.moves.value.A1.problem, /It stays here\.$/);
  work.apply("move/changed", { ...move, branchSent: true, finished: true }, "mac");
  assert.equal(work.moves.value.A1, undefined);
});
