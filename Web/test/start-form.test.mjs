// The new session's form kept between starts (#257), as DraftKeeper keeps the window's.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const f = await load("src/model/startForm.ts");
const memory = () => {
  const held = new Map();
  return { getItem: (k) => held.get(k) ?? null, setItem: (k, v) => held.set(k, v) };
};

test("start form: kept and read back", () => {
  const storage = memory();
  f.keepForm(storage, { runtimeID: "codex", chosen: { model: "gpt" }, folders: ["file:///x/"] });
  assert.deepEqual(f.keptForm(storage), { runtimeID: "codex", chosen: { model: "gpt" }, folders: ["file:///x/"] });
});

test("start form: nothing kept, or unreadable, is an empty form", () => {
  assert.deepEqual(f.keptForm(memory()), { chosen: {}, folders: [] });
  const storage = memory();
  storage.setItem("agents.startForm", "{nope");
  assert.deepEqual(f.keptForm(storage), { chosen: {}, folders: [] });
});

test("start form: a runtime that can't start any more takes its choices with it", () => {
  const form = { runtimeID: "grok", chosen: { mode: "x" }, folders: ["file:///y/"] };
  assert.deepEqual(f.formFor(form, ["claude", "grok"]), form);
  assert.deepEqual(f.formFor(form, ["claude"]), { chosen: {}, folders: ["file:///y/"] });
});
