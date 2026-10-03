// A blocked agent's wait lines (039, #152, #157), as AgentsModel.blockLines says them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const block = await load("src/model/block.ts");

for (const { name, input, expected } of cases("block/lines.json")) {
  test(`block: ${name}`, () => {
    const agent = input.agents.find((a) => a.id === input.agentID);
    const lines = block.blockLines(agent, input.agents);
    const open = block.openBlock(agent);
    const checksAgain = open !== null && block.checkAgainLine(open) !== null;
    if (checksAgain) assert.match(lines.pop(), /^Checks again at \d{1,2}:\d{2}/);
    assert.deepEqual({ isBlocked: open !== null, lines, checksAgain, carryOnHelp: block.carryOnHelp(agent) }, expected);
  });
}

test("block: a reason from a newer host reads as unrecognised", () => {
  assert.equal(block.endingSummary({ at: 0, how: { stopped: { _0: "somethingNew" } } }),
    "stopped for a reason we do not know");
});
