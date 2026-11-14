// Reports ▸ Planning ▸ Builds (#5327): the control plane's copy answers when it keeps one, else a machine.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const r = await load("src/model/buildsRead.ts");

/** A store whose link records each call, and a control plane with these capabilities. */
function fake(capabilities) {
  const calls = [];
  const store = {
    planeHas: (c) => capabilities.includes(c),
    link: { call: async (method, params, host) => { calls.push({ method, params, host }); return { method }; } },
  };
  return { store, calls };
}

const ask = { repo: "github:alexec/agents", from: 0, to: 1 };

test("with builds.read/1 the page reads the control plane's copy, of the person's own machines", async () => {
  const { store, calls } = fake(["builds.read/1"]);
  assert.equal(r.planeReadsBuilds(store), true);
  await r.readHistory(store, ask, null);
  await r.readRun(store, { repo: ask.repo, ref: "github:run:alexec/agents#1" }, null);
  assert.deepEqual(calls.map((c) => [c.method, c.params.scope, c.host]), [
    ["builds/historyAll", { kind: "me" }, undefined],
    ["builds/runAll", { kind: "me" }, undefined],
  ]);
});

test("an older control plane: the page asks a machine, with no scope", async () => {
  const { store, calls } = fake([]);
  assert.equal(r.planeReadsBuilds(store), false);
  await r.readHistory(store, ask, "mac");
  await r.readRun(store, { repo: ask.repo, ref: "x" }, "mac");
  assert.deepEqual(calls.map((c) => [c.method, c.params.scope, c.host]), [["builds/history", undefined, "mac"], ["builds/run", undefined, "mac"]]);
});

test("a failed read says who was asked", () => {
  assert.equal(r.readProblem(new Error("x"), null), "The control plane can’t be reached.");
  assert.equal(r.readProblem(new Error("x"), "mac"), "The machine can’t be reached.");
});
