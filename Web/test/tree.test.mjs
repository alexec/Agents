// Sessions under the session that started them (#835), as the window's and the Remote's
// `SidebarTree`: each under its own starter at every depth (#3553), folded by default with the fold kept per row, a
// tree in each list, and a folded parent's mark the most urgent of its own and its children's.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

class Memory {
  items = new Map();
  getItem(key) { return this.items.get(key) ?? null; }
  setItem(key, value) { this.items.set(key, String(value)); }
}

const agent = (id, createdAt, fields = {}) => ({ id, createdAt, lastActivityAt: createdAt, state: "finished",
  endedReason: "endTurn", cwd: "file:///w/a", title: id, ...fields });
const none = () => undefined;

test("each session sits under its own starter, at every depth", async () => {
  const { nest, treeRows } = await load("src/model/tree.ts");
  const list = [agent("other", 5), agent("helper", 4, { startedByAgent: "lane" }),
    agent("later", 3, { startedByAgent: "lead" }), agent("lane", 2, { startedByAgent: "lead" }), agent("lead", 1)];
  const nested = nest(list, none);
  assert.deepEqual(nested.tops.map((a) => a.id), ["other", "lead"]);
  assert.deepEqual(nested.children.get("lead").map((a) => a.id), ["lane", "later"]);
  assert.deepEqual(nested.children.get("lane").map((a) => a.id), ["helper"]);
  const rows = treeRows(list, none, () => true);
  assert.deepEqual(rows.map((r) => [r.agent.id, r.depth, r.children]),
    [["other", 0, 0], ["lead", 0, 2], ["lane", 1, 1], ["helper", 2, 0], ["later", 1, 0]]);
});

test("each parent folds, and a deep row is drawn no further in than the cap", async () => {
  const { treeRows } = await load("src/model/tree.ts");
  const chain = [0, 1, 2, 3, 4, 5].map((i) => agent(`s${i}`, i, i > 0 ? { startedByAgent: `s${i - 1}` } : {}));
  assert.deepEqual(treeRows(chain, none, () => true).map((r) => r.indent), [0, 1, 2, 3, 3, 3]);
  const folded = treeRows(chain, none, (id) => id !== "s2");
  assert.deepEqual(folded.map((r) => [r.agent.id, r.isUnfolded]), [["s0", true], ["s1", true], ["s2", false]]);
});

test("a child without its parent in the list stands alone, and is found through one listed elsewhere", async () => {
  const { nest } = await load("src/model/tree.ts");
  const lead = agent("lead", 1);
  const helper = agent("helper", 3, { startedByAgent: "lane" });
  const alone = nest([helper], none);
  assert.deepEqual(alone.tops.map((a) => a.id), ["helper"]);
  assert.equal(alone.children.size, 0);
  const through = nest([helper, lead], (id) => (id === "lane" ? "lead" : undefined));
  assert.deepEqual(through.tops.map((a) => a.id), ["lead"]);
  assert.deepEqual(through.children.get("lead").map((a) => a.id), ["helper"]);
});

test("a loop ends, every session still listed", async () => {
  const { treeRows } = await load("src/model/tree.ts");
  const rows = treeRows([agent("a", 1, { startedByAgent: "b" }), agent("b", 2, { startedByAgent: "a" })], none, () => true);
  assert.equal(rows.length, 2);
});

test("a parent starts folded, and its fold is kept and bounded", async () => {
  const { treeRows } = await load("src/model/tree.ts");
  const { Folds, sessionsKept } = await load("src/model/folds.ts");
  const storage = new Memory();
  const folds = new Folds(storage);
  const list = [agent("lane", 2, { startedByAgent: "lead" }), agent("lead", 1)];
  const folded = treeRows(list, none, (id) => folds.isSessionOpen(id));
  assert.deepEqual(folded.map((r) => [r.agent.id, r.children, r.isUnfolded]), [["lead", 1, false]]);
  folds.setSession("lead", true);
  const next = new Folds(storage);
  const open = treeRows(list, none, (id) => next.isSessionOpen(id));
  assert.deepEqual(open.map((r) => [r.agent.id, r.isChild]), [["lead", false], ["lane", true]]);
  for (let i = 0; i <= sessionsKept; i++) next.setSession(`s${i}`, true);
  assert.equal(next.openSessions.value.length, sessionsKept);
  assert.equal(next.isSessionOpen("lead"), false, "the oldest opened goes first");
});

test("a folded parent shows the most urgent mark of it and its live descendants", async () => {
  const { liveDescendants, markAgentOf } = await load("src/model/tree.ts");
  const all = [
    agent("lead", 1),
    agent("lane", 2, { state: "running", startedByAgent: "lead" }),
    agent("helper", 3, { state: "waitingOnUser", startedByAgent: "lane" }),
    agent("gone", 4, { state: "archived", startedByAgent: "lead" }),
  ];
  const below = liveDescendants(all, "lead");
  assert.deepEqual(below.map((a) => a.id), ["lane", "helper"]);
  assert.equal(markAgentOf(all[0], below).id, "helper");
  assert.equal(markAgentOf(all[0], [all[1]]).id, "lane");
  assert.equal(markAgentOf(all[0], []).id, "lead");
});
