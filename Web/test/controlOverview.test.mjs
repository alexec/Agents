// Settings ▸ Control plane ▸ Overview on the page this Mac serves (#4252): the switch's line says what the
// control plane says (071 R3), Try Again only while it is on and not serving, and the control plane's row.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const o = await load("src/model/controlOverview.ts");

test("served, it gives the address; off, it says off and where it would be", () => {
  assert.equal(o.serveLine({ port: 8792, served: true }), "At localhost:8792, for a browser on this Mac only.");
  const off = { port: 8792, served: false, reason: "off" };
  assert.equal(o.serveLine(off), "Off. Turn it on to use Agent Loops at localhost:8792, in a browser on this Mac only.");
  assert.equal(o.isOff(off), true);
  assert.equal(o.canTryAgain(off), false);
});

test("not serving, it says why, never the address, and offers Try Again", () => {
  const taken = { port: 8792, served: false, reason: "portInUse" };
  assert.equal(o.serveLine(taken), "Not serving: port 8792 is in use by another app.");
  assert.equal(o.canTryAgain(taken), true);
  assert.equal(o.serveLine({ port: 8792, served: false, reason: "failed", detail: "denied" }), "Not serving: port 8792 couldn’t be opened (denied).");
  assert.equal(o.canTryAgain({ port: 8792, served: true }), false);
  assert.equal(o.canTryAgain(undefined), false);
});

test("the control plane's row has its version, and since when it runs", () => {
  assert.equal(o.runningLine("0.42.0", undefined), "agents-control 0.42.0");
  assert.match(o.runningLine("0.42.0", 0), /^agents-control 0\.42\.0 · running since \d/);
});
