// Move to Another Machine… and Run It Here Again… on the page (#4255): the sheet's buttons for each step, as the
// window's MachineMoveSheet and MachineReturnSheet, and the marks of its checks and stages.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/planeMove.ts");
const labels = (flow) => m.flowButtons(flow).map((b) => `${b.left ? "<" : ""}${b.label}${b.disabled ? " (off)" : ""}`);

test("a move goes key, check, told, moving with the sheet's buttons", () => {
  assert.deepEqual(labels({ kind: "move", step: "key", title: "" }), ["Cancel", "Continue"]);
  assert.deepEqual(labels({ kind: "move", step: "check", title: "" }), ["<Back", "Cancel", "Tell Everyone (off)"]);
  assert.deepEqual(labels({ kind: "move", step: "check", title: "", checked: true }), ["<Back", "Cancel", "Tell Everyone"]);
  assert.deepEqual(labels({ kind: "move", step: "told", title: "" }), ["<Withdraw", "Cancel", "Move Now"]);
  assert.deepEqual(labels({ kind: "move", step: "moving", title: "", taken: true }), ["Cancel (off)"]);
  assert.deepEqual(labels({ kind: "move", step: "moving", title: "", failed: true }), ["Close"]);
});

test("the way back offers Check Again until both ends pass", () => {
  assert.deepEqual(labels({ kind: "return", step: "check", title: "" }), ["<Check Again", "Cancel", "Tell Everyone (off)"]);
  assert.deepEqual(labels({ kind: "return", step: "check", title: "", checked: true }), ["Cancel", "Tell Everyone"]);
  assert.equal(m.stepTitle({ kind: "return", step: "check" }), "1 · Check both ends");
  assert.equal(m.stepTitle({ kind: "move", step: "moving" }), null);
});

test("a check's note shows once it is said, and Escape keeps the sheet while it moves", () => {
  assert.equal(m.lineMark({ label: "It answers", state: "yes" }), "✓");
  assert.equal(m.lineMark({ label: "Copying", state: "failed" }), "✗");
  assert.equal(m.showsNote({ label: "x", state: "waiting", note: "n" }), false);
  assert.equal(m.showsNote({ label: "x", state: "no", note: "n" }), true);
  assert.equal(m.keepsOpen({ kind: "move", step: "moving", title: "" }), true);
  assert.equal(m.keepsOpen({ kind: "move", step: "moving", title: "", failed: true }), false);
  assert.equal(m.keepsOpen({ kind: "move", step: "told", title: "" }), false);
});
