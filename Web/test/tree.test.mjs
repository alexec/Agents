// Sessions under the session that started them (#835), as the window's and the Remote's
// `SidebarTree`: one indent whatever the depth, folded by default with the fold kept per row, a
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

test("every descendant sits one indent under the top session, oldest first", async () => {
  const { nest } = await load("src/model/tree.ts");
  const lead = agent("lead", 1);
  const lane = agent("lane", 2, { startedByAgent: "lead" });
  const helper = agent("helper", 3, { startedByAgent: "lane" });
  const other = agent("other", 4);
  const nested = nest([other, helper, lane, lead], none);
  assert.deepEqual(nested.map((n) => n.agent.id), ["other", "lead"]);
  assert.deepEqual(nested[1].children.map((a) => a.id), ["lane", "helper"]);
});

test("a child without its parent in the list stands alone, and is found through one listed elsewhere", async () => {
  const { nest } = await load("src/model/tree.ts");
  const lead = agent("lead", 1);
  const helper = agent("helper", 3, { startedByAgent: "lane" });
  assert.deepEqual(nest([helper], none).map((n) => [n.agent.id, n.children.length]), [["helper", 0]]);
  const through = nest([helper, lead], (id) => (id === "lane" ? "lead" : undefined));
  assert.deepEqual(through.map((n) => n.agent.id), ["lead"]);
  assert.deepEqual(through[0].children.map((a) => a.id), ["helper"]);
});

test("a loop ends, every session still listed", async () => {
  const { nest } = await load("src/model/tree.ts");
  const nested = nest([agent("a", 1, { startedByAgent: "b" }), agent("b", 2, { startedByAgent: "a" })], none);
  assert.equal(nested.flatMap((n) => [n.agent, ...n.children]).length, 2);
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
