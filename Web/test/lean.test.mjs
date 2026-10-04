// What the page does with a host that sends a row's worth on each change, and a session's own
// entries only to the page showing it (#203).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { Work } = await load("test/bounded.ts");

function agent(id, extra = {}) {
  return {
    id, title: `Session ${id}`, cwd: "file:///w/p/", createdAt: 1, lastActivityAt: 1, runtimeID: "claude",
    state: "finished", advertisedOptions: [], availableCommands: [], startOptions: { extraArguments: [], values: {} }, ...extra,
  };
}

const commands = [{ name: "review" }];
const plans = [{ entries: [{ content: "Step", priority: "medium", status: "inProgress" }] }];

test("a lean change keeps the session's menus and a whole one is the truth, an emptied plan included", () => {
  const work = new Work();
  work.apply("agent/changed", agent("a", { availableCommands: commands, plans }), "mac");
  work.apply("agent/changed", agent("a", { title: "Renamed", listsLeftOut: true, lastActivityAt: 2 }), "mac");
  let held = work.agents.value.mac[0];
  assert.equal(held.title, "Renamed");
  assert.deepEqual(held.availableCommands, commands);
  assert.deepEqual(held.plans, plans);
  assert.equal(held.listsLeftOut, undefined, "the lists held are whole");
  work.apply("agent/changed", agent("a", { availableCommands: commands, lastActivityAt: 3 }), "mac");
  held = work.agents.value.mac[0];
  assert.equal(held.plans, undefined, "the plan finished");
  assert.deepEqual(held.availableCommands, commands);
});

test("an archived change for a session the page does not hold stays out", () => {
  const work = new Work();
  work.apply("agent/changed", agent("live"), "mac");
  work.apply("agent/changed", agent("gone", { state: "archived", listsLeftOut: true }), "mac");
  assert.deepEqual(work.agents.value.mac.map((a) => a.id), ["live"]);
  work.apply("agent/changed", agent("live", { state: "archived", listsLeftOut: true, lastActivityAt: 2 }), "mac");
  assert.equal(work.agents.value.mac[0].state, "archived", "one it holds is archived in place");
});

test("an entry too big to send holds its place, draws nothing, and is filled where it was", () => {
  const work = new Work();
  const asked = [];
  work.oversized = (host, agentID, entryID, index) => asked.push({ host, agentID, entryID, index });
  work.watch("mac", "s");
  const said = (id, text) => ({ id, at: 1, kind: { agentMessage: { messageID: id, text } } });
  work.apply("agent/entry", { agentID: "s", entry: said("e1", "before") }, "mac");
  work.apply("agent/entry", { agentID: "s", entry: { id: "big", at: 2, kind: { oversized: 90000 } }, index: 7, oversized: 90000 }, "mac");
  work.apply("agent/entry", { agentID: "s", entry: said("e3", "after") }, "mac");
  assert.deepEqual(asked, [{ host: "mac", agentID: "s", entryID: "big", index: 7 }]);
  assert.deepEqual(work.items.value.map((i) => i.id), ["e1", "e3"], "the stub draws nothing");
  work.fillOversized(said("big", "the whole of it"), "mac", "s");
  assert.deepEqual(work.entries.value.map((e) => e.id), ["e1", "big", "e3"]);
  assert.deepEqual(work.items.value.map((i) => i.id), ["e1", "big", "e3"]);
});
