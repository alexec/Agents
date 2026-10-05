// The plan a plan approval shows (#256), held to ToolCall.planFile and planText.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const p = await load("src/model/plan.ts");

for (const { name, input, expected } of cases("plan/approval.json")) {
  test(`plan: ${name}`, () => {
    const plan = p.planOf(input);
    assert.deepEqual(plan && { file: plan.file ?? null, text: plan.text ?? null }, expected);
  });
}
