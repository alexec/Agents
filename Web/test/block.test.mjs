// A blocked agent's wait lines (039, #152, #157), as AgentsModel.blockLines says them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const block = await load("src/model/block.ts");
const rowLines = await load("src/model/rowLines.ts");

for (const { name, input, expected } of cases("block/lines.json")) {
  test(`block: ${name}`, () => {
    const agent = input.agents.find((a) => a.id === input.agentID);
    const lines = block.blockLines(agent, input.agents);
    const open = block.openBlock(agent);
    const names = block.blockWaitNames(agent, input.agents);
    // The row's one line (#582), where it names someone, as AgentsModel.waitMark says it.
    const waitLine = names.length > 0
      ? rowLines.waitMark(agent, { names, lines: block.blockLines(agent, input.agents) }, null, () => undefined)?.line ?? "" : null;
    const checksAgain = open !== null && block.checkAgainLine(open) !== null;
    if (checksAgain) assert.match(lines.pop(), /^Checks again at \d{1,2}:\d{2}/);
    assert.deepEqual({ isBlocked: open !== null, lines, checksAgain, waitLine, carryOnHelp: block.carryOnHelp(agent) }, expected);
  });
}

test("block: a reason from a newer host reads as unrecognised", () => {
  assert.equal(block.endingSummary({ at: 0, how: { stopped: { _0: "somethingNew" } } }),
    "stopped for a reason we do not know");
});
