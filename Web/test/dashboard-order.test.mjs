// The Dashboard's order (#147), as DashboardModel and DashboardOrder say it for the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const d = await load("src/model/dashboard.ts");

const tile = (id, section, made, hidden) => ({
  id, made, keeper: { kind: "agent", id: "a", name: "Lead", state: "active" }, changedOutside: false,
  points: [], recent: [], keeperChanges: [],
  tile: { title: id, type: "status", keeper: { agent: "a" }, ...(section ? { section } : {}), ...(hidden ? { hidden } : {}) },
});
const snapshot = (order) => ({
  folder: "file:///p", now: 0, ...(order ? { order } : {}),
  tiles: [tile("a", undefined, 1), tile("b", undefined, 2), tile("c", "Ship", 3), tile("h", undefined, 4, true)],
});
const shown = (s, hidden = true) => d.sections(s, hidden).map((g) => `${g.title ?? "-"}: ${g.tiles.map((t) => t.id).join(" ")}`);

test("with no order the tiles are in made order, in their own sections", () => {
  assert.deepEqual(shown(snapshot()), ["-: a b h", "Ship: c"]);
});

test("an order puts tiles and sections where it lists them, and the rest after", () => {
  const s = snapshot({ sections: [{ title: "Ship", tiles: ["b", "c"] }, { tiles: ["gone", "a"] }] });
  assert.deepEqual(shown(s), ["Ship: b c", "-: a h"]);
  assert.deepEqual(shown(s, false), ["Ship: b c", "-: a"]);
});

test("moving, after, sections and stepping edit the whole order", () => {
  const s = snapshot();
  const order = d.arrangement(s);
  assert.deepEqual(order, { sections: [{ tiles: ["a", "b", "h"] }, { title: "Ship", tiles: ["c"] }] });
  assert.deepEqual(d.moving(order, ["a"], "Ship", "c").sections, [{ tiles: ["b", "h"] }, { title: "Ship", tiles: ["a", "c"] }]);
  assert.deepEqual(d.movingAfter(order, ["a"], "b").sections[0].tiles, ["b", "a", "h"]);
  assert.deepEqual(d.movingSection(order, "Ship", null).sections.map((x) => x.title ?? null), ["Ship", null]);
  // Move Down among the shown tiles steps past the hidden one's neighbour, not onto it.
  assert.deepEqual(d.stepping(s, "a", 1, false).sections[0].tiles, ["b", "a", "h"]);
  assert.equal(d.stepping(s, "a", -1, false), null);
});

test("cleaning keeps each tile and heading once and drops empty sections", () => {
  assert.deepEqual(d.cleaned({ sections: [{ title: "", tiles: ["a", "a"] }, { tiles: ["b", "x"] }, { title: "E", tiles: [] }] },
    new Set(["a", "b"])), { sections: [{ tiles: ["a", "b"] }] });
});

test("a page tile (#159) is wide and never stale", () => {
  const page = { ...tile("p", undefined, 5), tile: { title: "Roadmap", type: "page", keeper: { agent: "a" }, page: { file: "docs/roadmap.md" } } };
  assert.equal(d.isWide(page), true);
  assert.equal(d.isStale(page, 10 ** 12), false);
});
