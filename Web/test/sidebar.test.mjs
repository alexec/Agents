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
  const { todayTotals, totalWords, headroom, closeToFull, dayLimitReached, isOut, lifetimeTotals } = await load("src/views/Activity.tsx");
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
  assert.equal(closeToFull({ ...costs.mac, today: { USD: 1.69 } }), false, "80% is not close to full");
  assert.equal(closeToFull({ ...costs.mac, today: { USD: 1.7 } }), true, "85% matches the other clients");
  assert.equal(dayLimitReached({ ...costs.mac, today: { USD: 1.99 } }), false);
  assert.equal(dayLimitReached({ ...costs.mac, today: { USD: 2 } }), true);
  assert.deepEqual(lifetimeTotals([
    { costToDate: { USD: 2, GBP: 1 } }, { costToDate: { USD: 3 } },
  ]), { USD: 5, GBP: 1 });
  const runtime = { id: "codex", name: "Codex" };
  assert.equal(isOut({ runtime, availability: { missing: { lookedIn: [] } } }), false, "never in is not out");
  assert.equal(isOut({ runtime, availability: { available: { path: "/x", supportsResume: true } }, poolNote: "Out until 4pm" }), true);
});

test("Archived projects: every host's, the latest worked on first, apart from the live ones (#343)", async () => {
  globalThis.location = { hash: "" };
  globalThis.addEventListener = () => {};
  try {
    const { archivedProjects } = await load("src/views/Sidebar.tsx");
    const project = (name, lastActivityAt, archivedAt) => ({ name, lastActivityAt,
      project: { folder: `file:///w/${name}/`, addedAt: 0, ...(archivedAt === undefined ? {} : { archivedAt }) } });
    const hosts = [{ id: "mac", name: "This Mac" }, { id: "box", name: "box" }];
    const shown = archivedProjects(hosts, {
      mac: [project("live", 50), project("old", 10, 20)],
      box: [project("newer", 30, 40)],
    });
    assert.deepEqual(shown.map(({ host, project }) => `${host.id}:${project.name}`), ["box:newer", "mac:old"]);
    assert.deepEqual(archivedProjects(hosts, { mac: [project("live", 50)] }), [], "none archived, no fold");
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("Projects: this Mac's then each server's, oldest added first, however busy (#357)", async () => {
  globalThis.location = { hash: "" };
  globalThis.addEventListener = () => {};
  try {
    const { orderedProjects } = await load("src/views/Sidebar.tsx");
    const project = (name, addedAt, lastActivityAt = 0, archivedAt) => ({ name, lastActivityAt,
      project: { folder: `file:///w/${name}/`, addedAt, ...(archivedAt === undefined ? {} : { archivedAt }) } });
    const hosts = [{ id: "box", name: "box" }, { id: "mac", name: "This Mac" }];
    const names = (projects) => orderedProjects(hosts, projects).map(({ host, project }) => `${host.id}:${project.name}`);
    const listed = { mac: [project("busy", 20, 999), project("first", 10), project("gone", 5, 0, 30)],
                     box: [project("api", 1)] };
    assert.deepEqual(names(listed), ["mac:first", "mac:busy", "box:api"], "activity does not move a row");
    listed.mac.push(project("new", 40));
    assert.deepEqual(names(listed), ["mac:first", "mac:busy", "mac:new", "box:api"], "a new project lands at the end");
    assert.deepEqual(names({ mac: [project("b", 10), project("a", 10)] }), ["mac:a", "mac:b"], "same moment: by folder");
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("Activity is open until folded, and kept so", async () => {
  const { Folds } = await load("src/model/folds.ts");
  const storage = new Memory();
  const first = new Folds(storage);
  assert.equal(first.showsActivity.value, true, "open by default");
  first.setShowsActivity(false);
  assert.equal(new Folds(storage).showsActivity.value, false);
  first.setShowsActivity(true);
  assert.equal(new Folds(storage).showsActivity.value, true);
});

test("Archived projects is closed until opened, and kept so (#343)", async () => {
  const { Folds } = await load("src/model/folds.ts");
  const storage = new Memory();
  const first = new Folds(storage);
  assert.equal(first.showsArchivedProjects.value, false, "closed by default");
  first.setShowsArchivedProjects(true);
  assert.equal(new Folds(storage).showsArchivedProjects.value, true);
  first.setShowsArchivedProjects(false);
  assert.equal(new Folds(storage).showsArchivedProjects.value, false);
  const refusing = { getItem: () => { throw new Error("denied"); }, setItem: () => { throw new Error("quota"); } };
  const held = new Folds(refusing);
  assert.equal(held.showsArchivedProjects.value, false);
  held.setShowsArchivedProjects(true);
  assert.equal(held.showsArchivedProjects.value, true, "held for this visit");
});
