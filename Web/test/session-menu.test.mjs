// What a session's ··· menu offers (Agent.parkAction, AgentsModel.canStop, AgentRow's menu).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

// Branch opens the new session (#342), so the menu reads the page's address as it loads.
globalThis.location = { hash: "" };
globalThis.addEventListener = () => {};
const { sessionActions } = await load("src/views/SessionMenu.tsx");
delete globalThis.location;
delete globalThis.addEventListener;
const agents = Object.fromEntries(cases("groups/agents.json").map((c) => [c.name, c.input.agent]));
const labels = (name) => sessionActions(agents[name]).map((a) => a.label);

test("a running session can be stopped, parked, branched and archived", () => {
  assert.deepEqual(labels("running"), ["Stop", "Park", "Branch", "Archive"]);
  assert.deepEqual(labels("waiting on the person"), ["Stop", "Park", "Branch", "Archive"]);
});

test("a finished one can't be stopped, unless it sits in an open block, which Carry on leads (#250)", () => {
  assert.deepEqual(labels("done"), ["Park", "Mark as Unread", "Branch", "Archive"]);
  assert.deepEqual(labels("blocked on agents"), ["Carry on", "Stop", "Park", "Mark as Unread", "Branch", "Archive"]);
});

test("an unread finish offers Mark as Read; nothing else offers either (#70)", () => {
  assert.deepEqual(labels("done, unread"), ["Park", "Mark as Read", "Branch", "Archive"]);
  assert.deepEqual(labels("stopped by the person"), ["Park", "Branch", "Archive"]);
});

test("parked, or parking when the turn ends, offers Unpark", () => {
  assert.deepEqual(labels("parked, done"), ["Unpark", "Mark as Unread", "Branch", "Archive"]);
  assert.deepEqual(labels("parked when the turn ends, running"), ["Stop", "Unpark", "Branch", "Archive"]);
});

test("archived offers Bring Back, and no Park or Branch", () => {
  assert.deepEqual(labels("archived"), ["Bring Back"]);
});

test("given whether it is pinned, Pin or Unpin before Branch and Archive; never on archived (#180, #342)", () => {
  assert.deepEqual(sessionActions(agents["running"], false).map((a) => a.label), ["Stop", "Park", "Pin", "Branch", "Archive"]);
  assert.deepEqual(sessionActions(agents["done"], true).map((a) => a.label), ["Park", "Mark as Unread", "Unpin", "Branch", "Archive"]);
  assert.deepEqual(sessionActions(agents["archived"], true).map((a) => a.label), ["Bring Back"]);
});
