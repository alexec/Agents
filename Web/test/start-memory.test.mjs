// The new session's form ready at once (#1171): drawn from what the runtime offered last time,
// then put right by the draft's answer, with the choices still offered kept.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/startMemory.ts");

const select = (id, values, current) => ({
  id, name: id, type: "select", currentValue: current, options: values.map((value) => ({ value, name: value })),
});

test("start memory: one list for each runtime on each host", () => {
  assert.equal(m.rememberedOptions("mac", "claude"), undefined);
  m.rememberOptions("mac", "claude", [select("model", ["opus"], "opus")]);
  m.rememberOptions("server-1", "claude", [select("model", ["sonnet"], "sonnet")]);
  m.rememberOptions("mac", "claude", [select("model", ["opus", "fable"], "fable")]);
  assert.equal(m.rememberedCount(), 2);
  assert.equal(m.rememberedOptions("mac", "claude")[0].options.length, 2);
  assert.equal(m.rememberedOptions("server-1", "claude")[0].currentValue, "sonnet");
  assert.equal(m.rememberedOptions("mac", "codex"), undefined);
});

test("start memory: an answer that changes the options keeps the valid choices", () => {
  const remembered = [select("model", ["opus", "sonnet"], "opus"), select("mode", ["default", "plan"], "default")];
  const opened = m.keep(remembered, { model: "sonnet", mode: "plan" });
  assert.deepEqual(opened, { model: "sonnet", mode: "plan" });
  const answered = [select("model", ["opus", "fable"], "opus"), select("mode", ["default", "plan"], "default"),
    select("effort", ["high"], "high")];
  assert.deepEqual(m.keep(answered, opened), { model: "opus", mode: "plan", effort: "high" });
});

test("start memory: a switch keeps its choice and an option gone is let go", () => {
  const fast = { id: "fast", name: "Fast", type: "boolean", currentValue: false };
  assert.deepEqual(m.keep([fast], { fast: true, gone: "x" }), { fast: true });
});
