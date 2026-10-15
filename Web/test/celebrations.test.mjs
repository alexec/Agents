// The Blob's celebrations (#986): the same answers as CelebrationsTests in Swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/celebrations.ts");

test("one still waiting merges with the next, keeping its confetti", () => {
  const first = c.celebrate(null, true);
  assert.deepEqual(first, { id: 1, confetti: true });
  assert.deepEqual(c.celebrate(first, false), { id: 2, confetti: true });
  assert.deepEqual(c.celebrate(null, false), { id: 1, confetti: false });
});

test("a milestone celebrates only when earned while the page looked", () => {
  assert.equal(c.earnedMore(undefined, { earned: [{}] }), false);
  assert.equal(c.earnedMore({ earned: [] }, { earned: [{}] }), true);
  assert.equal(c.earnedMore({ earned: [{}] }, { earned: [{}] }), false);
});

test("on by default", () => {
  assert.equal(c.celebrationsOn.value, true);
});
