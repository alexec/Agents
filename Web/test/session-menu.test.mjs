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
  assert.deepEqual(labels("done"), ["Park", "Archive"]);
  assert.deepEqual(labels("blocked on agents"), ["Stop", "Park", "Archive"]);
});

test("parked, or parking when the turn ends, offers Unpark", () => {
  assert.deepEqual(labels("parked, done"), ["Unpark", "Archive"]);
  assert.deepEqual(labels("parked when the turn ends, running"), ["Stop", "Unpark", "Archive"]);
});

test("archived offers Bring Back, and no Park", () => {
  assert.deepEqual(labels("archived"), ["Bring Back"]);
});
