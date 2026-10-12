// The plan strip at the head of the chat and the time in a row's corner (#341), as
// Agent.planInForce, Plan.stripSummary, stripStep, stripDone and ActivityWords.short say them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const p = await load("src/model/currentPlan.ts");
const a = await load("src/model/activity.ts");
const { fromWireDate } = await load("src/protocol/dates.ts");

for (const { name, input, expected } of cases("plan/strip.json")) {
  test(`plan strip: ${name}`, () => {
    const plan = p.planInForce({ plans: input.plans });
    const made = plan && { line: p.planSummary(plan), step: p.planStep(plan), done: p.planDone(plan), total: plan.entries.length };
    assert.deepEqual(made, expected);
  });
}

for (const { name, input, expected } of cases("activity/short.json")) {
  test(`activity: ${name}`, () => {
    assert.equal(a.shortAgo(fromWireDate(input.lastActivityAt), fromWireDate(input.now)), expected);
  });
}
