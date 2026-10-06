// The plan strip at the head of the chat and the time in a row's corner (#341), as
// Agent.planInForce, Plan.stripSummary and ActivityWords.short say them.
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
    assert.equal(plan && p.planSummary(plan), expected);
  });
}

for (const { name, input, expected } of cases("activity/short.json")) {
  test(`activity: ${name}`, () => {
    assert.equal(a.shortAgo(fromWireDate(input.lastActivityAt), fromWireDate(input.now)), expected);
  });
}
