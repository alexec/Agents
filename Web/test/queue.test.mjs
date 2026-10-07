// A queued helper's place in its project's queue (#362), as AgentsModel.queuedLine says it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const status = await load("src/model/status.ts");

for (const { name, input, expected } of cases("queue/lines.json")) {
  test(`queue: ${name}`, () => {
    const agent = input.agents.find((a) => a.id === input.agentID);
    assert.deepEqual({ line: status.queuedLine(agent, input.agents) }, expected);
  });
}

test("queue: ordinals as HelperLimit says them", () => {
  assert.deepEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 101].map(status.ordinal),
    ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "101st"]);
});
