// The goal card over the plan's (#2742), as Goal.statusWord, isStopped, progressLine,
// budgetFraction and summary say it (Model/Goal.swift).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const g = await load("src/model/goal.ts");

for (const { name, input, expected } of cases("goal/card.json")) {
  test(`goal card: ${name}`, () => {
    const goal = input.agent.goal;
    const made = goal ? {
      status: g.goalStatusWord(goal), stopped: g.goalIsStopped(goal), progress: g.goalProgress(goal),
      fraction: g.goalBudgetFraction(goal), summary: g.goalSummary(goal),
    } : null;
    assert.deepEqual(made, expected);
  });
}
