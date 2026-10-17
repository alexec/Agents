// The level turns start at, and opening and closing one (#993, #759, #1286).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const t = await load("src/model/turnDetail.ts");

test("three levels, and turns start at Messages when no level is kept", () => {
  assert.deepEqual([...t.turnDetails], ["messages", "steps", "details"]);
  assert.equal(t.savedDetail(null), "messages");
  assert.equal(t.savedDetail("bogus"), "messages");
  assert.equal(t.savedDetail("outcome"), "messages");
  assert.equal(t.savedDetail("collapsed"), "messages");
  for (const kept of ["messages", "steps", "details"]) assert.equal(t.savedDetail(kept), kept);
});

test("closing a turn collapses it, and opening it goes back to the level", () => {
  const closed = t.toggled(t.initialDetail, t.initialDetail);
  assert.equal(closed, "collapsed");
  assert.equal(t.toggled(closed, t.initialDetail), "messages");
  assert.equal(t.toggled("details", "details"), "collapsed");
  assert.equal(t.toggled("collapsed", "details"), "details");
});
