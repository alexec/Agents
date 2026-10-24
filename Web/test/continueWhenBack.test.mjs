// An allowance failure can continue when it is back (#1859), as ContinueWhenBackWords says it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const w = await load("src/model/continueWhenBack.ts");
const f = await load("src/model/fileToSeeWords.ts");
const g = await load("src/model/groups.ts");
const s = await load("src/model/status.ts");

// Wire dates are seconds since 2001-01-01.
const wire = (date) => date.getTime() / 1000 - 978_307_200;
const allowanceFailure = {
  id: "A", runtimeID: "claude", cwd: "file:///p/", state: "stopped", startOptions: {}, advertisedOptions: [],
  availableCommands: [], createdAt: 0, lastActivityAt: 0, endedReason: "allowanceSpent",
};

test("an allowance failure offers Continue, at the reset time when it is known", () => {
  const now = new Date(2026, 9, 21, 3, 0);
  assert.equal(w.offersContinue(allowanceFailure), true);
  assert.equal(w.offersContinue({ ...allowanceFailure, endedReason: "cancelled" }), false);
  assert.match(w.continueButton(new Date(2026, 9, 21, 7, 0), now), /^Continue at /);
  assert.equal(w.continueButton(null, now), "Continue when it is back");
});

test("a waiting chat says when it continues, on its row too, under Waiting", () => {
  const now = new Date(2026, 9, 21, 3, 0);
  const at = wire(new Date(2026, 9, 21, 7, 0));
  const waiting = { ...allowanceFailure, continueWhenBack: { at, resetKnown: true } };
  assert.match(w.continueLine(waiting, now), /^Continues at /);
  assert.match(w.continueLine({ ...allowanceFailure, continueWhenBack: { at, resetKnown: false } }, now), /^Continues when it is back · tries at /);
  assert.equal(w.continueLine(allowanceFailure), null);
  assert.match(f.reportLine(waiting), /^Continues /);
  assert.equal(w.offersContinue(waiting), false);
  assert.equal(g.groupOf(waiting), "waiting");
  assert.equal(g.groupOf(allowanceFailure), "needsAttention");
  assert.equal(s.shapeOf(allowanceFailure), "needsYou");
  assert.equal(s.statusWords(waiting), "Waiting for an allowance");
});

test("the reset time comes from the runtime's out row", () => {
  const until = wire(new Date(2026, 9, 21, 7, 0));
  const allowances = { at: 0, rows: [{ credentialKey: "claude:sign-in", state: { status: { out: { until, why: "allowanceSpent" } } } }] };
  assert.equal(w.resetsAt(allowances, "claude")?.getHours(), 7);
  assert.equal(w.resetsAt(allowances, "codex"), null);
  assert.equal(w.resetsAt(undefined, "claude"), null);
});

test("the workflow page's switch says what a run does (#1918)", () => {
  assert.equal(w.workflowContinueSwitch, "Continue when the allowance is back");
  assert.equal(w.workflowContinueSentence(true), "A run whose allowance is spent waits, and carries on when it is back.");
  assert.equal(w.workflowContinueSentence(false), "A run whose allowance is spent stops until somebody chooses Continue.");
});
