import assert from "node:assert/strict";
import { test } from "node:test";
import { load } from "./load.mjs";

const status = await load("src/model/status.ts");

test("Needs You uses the question's first line", () => {
  assert.equal(status.needsYouLine({ state: "waitingOnUser" }, "May I run this?\nMore detail"), "May I run this?");
});

test("Needs You says why an agent stopped or finished without a report", () => {
  assert.equal(status.needsYouLine({ state: "stopped", endedReason: "daemonGone" }), "Stopped with the daemon");
  assert.equal(status.needsYouLine({ state: "finished", endedReason: "endTurn", outcomeAsked: true }),
    "Finished without saying how it went");
});

test("the report line returns when the session no longer needs you", () => {
  assert.equal(status.needsYouLine({ state: "finished", report: { outcome: "done" } }), null);
  assert.equal(status.needsYouLine({ state: "waitingOnUser" }, "  \n "), null);
});
