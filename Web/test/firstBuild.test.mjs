// The question page (#5051): the ideas, held to the fixture the Mac window reads too, and who
// sees the page, as GetStarted.card in Swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const m = await load("src/model/firstBuild.ts");

const newcomer = { loaded: true, hasMachine: true, hasFolder: false, hasAgent: false, ranAgent: false };

function storage() {
  const items = new Map();
  return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v) };
}

test("the ideas are the fixture's, in its order", () => {
  assert.deepEqual(m.firstBuildIdeas.map((i) => ({ ...i })), cases("first-build/ideas.json")[0].expected);
});

test("the ideas go round", () => {
  assert.equal(m.nextIdea(0), 1);
  assert.equal(m.nextIdea(m.firstBuildIdeas.length - 1), 0);
});

test("a newcomer sees the page once every machine has answered", () => {
  assert.equal(m.weigh(null, { ...newcomer, loaded: false }, false), null);
  assert.equal(m.weigh(null, newcomer, false), "showing");
});

test("no machine yet: not until one is there", () => {
  assert.equal(m.weigh(null, { ...newcomer, hasMachine: false }, false), null);
});

test("a person set up already never sees it", () => {
  for (const set of [{ hasFolder: true }, { hasAgent: true }, { ranAgent: true }]) {
    assert.equal(m.weigh(null, { ...newcomer, ...set }, false), "gone");
  }
  assert.equal(m.weigh("gone", newcomer, false), "gone");
});

test("showing stays until set up some other way, and for the plan page once sent", () => {
  assert.equal(m.weigh("showing", newcomer, false), "showing");
  assert.equal(m.weigh("showing", { ...newcomer, hasFolder: true }, false), "gone");
  assert.equal(m.weigh("showing", { ...newcomer, hasAgent: true }, true), "showing");
});

test("the browser keeps whether it shows and the idea it sent", () => {
  const kept = storage();
  const first = new m.FirstBuildStore(kept);
  first.take(newcomer);
  first.send("  A page for my band  ");
  first.send("   ");
  const again = new m.FirstBuildStore(kept);
  assert.equal(again.kept.value, "showing");
  assert.equal(again.sent.value, "A page for my band");
});
