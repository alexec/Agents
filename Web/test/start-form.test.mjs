// The new session's form kept between starts (#257), as DraftKeeper keeps the window's.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const f = await load("src/model/startForm.ts");
const memory = () => {
  const held = new Map();
  return { getItem: (k) => held.get(k) ?? null, setItem: (k, v) => held.set(k, v) };
};

test("start form: the folders are this browser's, the runtime and choices the Mac's (#1033)", async () => {
  const m = await load("test/preferences-entry.ts");
  const sent = [];
  m.sendPreferencesWith((changes) => sent.push(changes));
  m.preferencesSaid({});
  const storage = memory();
  m.keepForm(storage, { runtimeID: "codex", chosen: { model: "gpt" }, folders: ["file:///x/"] });
  assert.deepEqual(JSON.parse(storage.getItem("agents.startForm")), { folders: ["file:///x/"] });
  assert.deepEqual(sent, [{ startRuntimeID: "codex", startChoices: { codex: { model: "gpt" } } }]);
  assert.deepEqual(m.keptForm(storage), { runtimeID: "codex", chosen: { model: "gpt" }, folders: ["file:///x/"] });
  m.keepForm(storage, { runtimeID: "codex", chosen: { model: "gpt" }, folders: [] });
  assert.equal(sent.length, 1, "no change, nothing sent");
  m.preferencesSaid({ startRuntimeID: "claude", startChoices: { claude: { mode: "plan" } } });
  assert.deepEqual(m.keptForm(storage), { runtimeID: "claude", chosen: { mode: "plan" }, folders: [] });
});

test("start form: nothing kept, or unreadable, is an empty form", async () => {
  const m = await load("test/preferences-entry.ts");
  assert.deepEqual(m.keptForm(memory()), { chosen: {}, folders: [] });
  const storage = memory();
  storage.setItem("agents.startForm", "{nope");
  assert.deepEqual(m.keptForm(storage), { chosen: {}, folders: [] });
});

test("start form: a runtime that can't start any more takes its choices with it", () => {
  const form = { runtimeID: "grok", chosen: { mode: "x" }, folders: ["file:///y/"] };
  assert.deepEqual(f.formFor(form, ["claude", "grok"]), form);
  assert.deepEqual(f.formFor(form, ["claude"]), { chosen: {}, folders: ["file:///y/"] });
});
