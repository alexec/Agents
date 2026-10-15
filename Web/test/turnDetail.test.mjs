// The level turns start at, and opening and closing one (#993, #759).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const t = await load("src/model/turnDetail.ts");

test("turns start at Messages when no level is kept, and a kept one stays", () => {
  assert.equal(t.savedDetail(null), "messages");
  assert.equal(t.savedDetail("bogus"), "messages");
  for (const kept of ["outcome", "messages", "steps", "details"]) assert.equal(t.savedDetail(kept), kept);
});

test("closing a turn goes to the outcome, and opening it goes back", () => {
  const closed = t.toggled(t.initialDetail, t.initialDetail);
  assert.equal(closed, "outcome");
  assert.equal(t.toggled(closed, t.initialDetail), "messages");
  assert.equal(t.toggled("details", "details"), "outcome");
  assert.equal(t.toggled("outcome", "details"), "details");
  assert.equal(t.toggled("outcome", "outcome"), "messages");
});
