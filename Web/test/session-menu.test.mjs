// What a session's ··· menu offers (Agent.parkAction, AgentsModel.canStop, AgentRow's menu).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const { sessionActions } = await load("src/views/SessionMenu.tsx");
const agents = Object.fromEntries(cases("groups/agents.json").map((c) => [c.name, c.input.agent]));
const labels = (name) => sessionActions(agents[name]).map((a) => a.label);

test("a running session can be stopped, parked and archived", () => {
  assert.deepEqual(labels("running"), ["Stop", "Park", "Archive"]);
  assert.deepEqual(labels("waiting on the person"), ["Stop", "Park", "Archive"]);
});

test("a finished one can't be stopped, unless it sits in an open block", () => {
  assert.deepEqual(labels("done"), ["Park", "Mark as Unread", "Archive"]);
  assert.deepEqual(labels("blocked on agents"), ["Stop", "Park", "Mark as Unread", "Archive"]);
});

test("an unread finish offers Mark as Read; nothing else offers either (#70)", () => {
  assert.deepEqual(labels("done, unread"), ["Park", "Mark as Read", "Archive"]);
  assert.deepEqual(labels("stopped by the person"), ["Park", "Archive"]);
});

test("parked, or parking when the turn ends, offers Unpark", () => {
  assert.deepEqual(labels("parked, done"), ["Unpark", "Mark as Unread", "Archive"]);
  assert.deepEqual(labels("parked when the turn ends, running"), ["Stop", "Unpark", "Archive"]);
});

test("archived offers Bring Back, and no Park", () => {
  assert.deepEqual(labels("archived"), ["Bring Back"]);
});
