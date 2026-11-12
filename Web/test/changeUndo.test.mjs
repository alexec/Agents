// Undo after Unarchive, Rename, the labels, Mute or Later (#4793), as SessionUndo.swift says it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const u = await load("src/model/changeUndo.ts");

for (const { name, input, expected } of cases("undo/lines.json")) {
  test(`change undo: ${name}`, () => {
    assert.equal(u.changeUndoLine(input.change, input.title), expected.line);
    assert.equal(u.changeUndoMenu(input.change), expected.menu);
  });
}

const agent = (over = {}) => ({ id: "a1", title: "Fix the parser", state: "finished", labels: [], ...over });

test("unarchive is undone by archive", () => {
  assert.deepEqual(u.unarchivedUndo(agent({ state: "archived" })).inverse, { kind: "archive", agentID: "a1" });
  assert.equal(u.unarchivedUndo(agent()), null);
});

test("rename gives the title it had", () => {
  assert.deepEqual(u.renamedUndo(agent(), "Parser").inverse, { kind: "rename", agentID: "a1", title: "" });
  const mine = agent({ title: "Mine", titleIsPersons: true });
  assert.deepEqual(u.renamedUndo(mine, "").inverse, { kind: "rename", agentID: "a1", title: "Mine" });
  assert.equal(u.renamedUndo(mine, " Mine "), null);
});

test("labels undo only what changed", () => {
  const held = agent({ labels: [{ value: "bug", owner: "person", addedAt: "2026-11-12T00:00:00Z" }] });
  assert.deepEqual(u.labelsUndo(held, ["bug", "ui"], ["Bug"]).inverse,
    { kind: "labels", agentID: "a1", add: ["bug"], remove: ["ui"] });
  assert.equal(u.labelsUndo(held, ["bug"], []), null);
});

test("mute is set back", () => {
  assert.deepEqual(u.mutedUndo(agent(), true).inverse, { kind: "mute", agentID: "a1", muted: false });
  assert.equal(u.mutedUndo(agent(), false), null);
});

test("later is undone by bring back", () => {
  assert.deepEqual(u.laterUndo({ id: "r1", title: "Approve the push" }).inverse, { kind: "bringBack", request: "r1" });
});
