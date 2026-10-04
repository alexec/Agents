// The one sidebar (#151): folds kept in localStorage by host and folder, Activity pages in the
// address, and what the Activity rows say at a glance.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

class Memory {
  items = new Map();
  getItem(key) { return this.items.get(key) ?? null; }
  setItem(key, value) { this.items.set(key, String(value)); }
}

test("a fold is kept, and read back by the next visit", async () => {
  const { Folds } = await load("src/model/folds.ts");
  const storage = new Memory();
  const first = new Folds(storage);
  first.set("mac", "file:///w/Agents/", true);
  first.set("box", "file:///w/Agents", true, "archivedSessions");
  const next = new Folds(storage);
  assert.equal(next.isOpen("mac", "file:///w/Agents"), true, "a trailing slash is the same folder");
  assert.equal(next.isOpen("box", "file:///w/Agents"), false, "the same folder on another host folds apart");
  assert.equal(next.isOpen("box", "file:///w/Agents", "archivedSessions"), true);
  next.set("mac", "file:///w/Agents", false);
  assert.equal(new Folds(storage).isOpen("mac", "file:///w/Agents"), false);
});

test("a session group and Workflows start open, and a fold of one is kept (#181)", async () => {
  const { Folds } = await load("src/model/folds.ts");
  const storage = new Memory();
  const first = new Folds(storage);
  assert.equal(first.isOpen("mac", "file:///w/a", "group.running"), true, "open until folded");
  assert.equal(first.isOpen("mac", "file:///w/a", "workflows"), true);
  first.set("mac", "file:///w/a", false, "group.running");
  first.set("mac", "file:///w/a", false, "workflows");
  const next = new Folds(storage);
  assert.equal(next.isOpen("mac", "file:///w/a", "group.running"), false, "kept folded");
  assert.equal(next.isOpen("mac", "file:///w/a", "group.finished"), true, "only that group");
  assert.equal(next.isOpen("box", "file:///w/a", "workflows"), true, "only that host's");
  assert.equal(next.isOpen("mac", "file:///w/a"), false, "the project's own fold is untouched");
  next.set("mac", "file:///w/a", true, "group.running");
  assert.equal(new Folds(storage).isOpen("mac", "file:///w/a", "group.running"), true);
  assert.deepEqual(JSON.parse(storage.getItem("agents.sidebar.folded")), ["workflows:mac|file:///w/a"]);
});

test("folds stored badly, or a storage that refuses, leave everything folded", async () => {
  const { Folds } = await load("src/model/folds.ts");
  const storage = new Memory();
  storage.setItem("agents.sidebar.folds", "{not json");
  const folds = new Folds(storage);
  assert.equal(folds.isOpen("mac", "file:///w/a"), false);
  const refusing = { getItem: () => null, setItem: () => { throw new Error("quota"); } };
  const held = new Folds(refusing);
  held.set("mac", "file:///w/a", true);
  assert.equal(held.isOpen("mac", "file:///w/a"), true, "held for this visit");
});

test("an Activity page is in the address on its own, and an unknown one is ignored", async () => {
  globalThis.location = { hash: "" };
  globalThis.addEventListener = () => {};
  try {
    const { parseRoute, routeHash } = await load("src/route.ts");
    assert.equal(routeHash({ activity: "events", host: "mac", project: "file:///w/a" }), "#/a/events");
    assert.deepEqual(parseRoute("#/a/spending"), { activity: "spending" });
    assert.deepEqual(parseRoute("#/a/settings"), {});
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("Activity rows: spending added up by currency, headroom, out of the pool", async () => {
  const { todayTotals, totalWords, headroom, closeToFull, isOut } = await load("src/views/Activity.tsx");
  const costs = {
    mac: { day: "2026-10-03", today: { USD: 1.5 }, limits: { daily: { amount: 2, currency: "USD" } } },
    box: { day: "2026-10-03", today: { USD: 0.25, GBP: 1 }, limits: {} },
  };
  assert.deepEqual(todayTotals(costs), { USD: 1.75, GBP: 1 });
  assert.match(totalWords(todayTotals(costs)), /1\.00 \+ .*1\.75/);
  assert.equal(totalWords({}), null);
  assert.match(headroom(costs.mac), /0\.50 left$/);
  assert.equal(headroom(costs.box), null, "no limit, nothing left to say");
  assert.equal(closeToFull(costs.mac), false);
  assert.equal(closeToFull({ ...costs.mac, today: { USD: 1.7 } }), true);
  const runtime = { id: "codex", name: "Codex" };
  assert.equal(isOut({ runtime, availability: { missing: { lookedIn: [] } } }), false, "never in is not out");
  assert.equal(isOut({ runtime, availability: { available: { path: "/x", supportsResume: true } }, poolNote: "Out until 4pm" }), true);
});
