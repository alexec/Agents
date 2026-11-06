// The estimate on Work's issue and epic pages (#3560), as EstimateWordsTests has it on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const e = await load("src/model/estimate.ts");

const issue = (n) => ({ kind: "issue", ref: `github:alexec/Agents#${n}` });
const range = (median, p10, p90) => ({ median, p10, p90 });
const story = {
  node: issue(1), type: "enhancement", level: "story", closedIssues: 40, matchedBy: "level", matches: 31,
  cost: { USD: range(3.2, 1.1, 9.8) }, outputTokens: range(45000, 12000, 140000), workingSeconds: range(7800, 1800, 21600),
  leadTimeSeconds: range(36000, 10800, 144000),
};

test("an issue's estimate says its figures, what it was made from and the range", () => {
  assert.equal(e.estimateLine(story), "Estimate: about $3.20, 45K output tokens, 2h 10m of work (from 31 closed stories)");
  assert.equal(e.estimateRangeWords(story),
    "8 in 10 like it: $1.10 to $9.80, 12K to 140K output tokens, 30m to 6h of work. Lead time 3h to 40h: it varies with the queue.");
  assert.equal(e.estimateSpentWords(story), undefined);
  assert.equal(e.showsEstimate(story), true);
  assert.equal(e.estimateSource({ ...story, matchedBy: "type", type: "bug" }), "31 closed bugs");
  assert.equal(e.estimateSource({ ...story, matchedBy: "all" }), "31 closed issues");
});

test("too little history says so and nothing else", () => {
  const none = { node: issue(2), closedIssues: 3, matches: 0 };
  assert.equal(e.estimateLine(none), "Not enough past work to estimate");
  assert.equal(e.estimateRangeWords(none), undefined);
  assert.equal(e.childEstimateWords(none), undefined);
});

test("an epic adds up its open children and says what its closed ones spent", () => {
  const epic = {
    node: issue(3), closedIssues: 40, matches: 60, cost: { USD: range(12, 6, 30) }, workingSeconds: range(36000, 18000, 72000),
    openChildren: 3, closedChildren: 2,
    spent: { cost: { USD: 4.1 }, inputTokens: 0, outputTokens: 0, turns: 2, workingSeconds: 0, waitingSeconds: 0 },
    children: [story],
  };
  assert.equal(e.estimateLine(epic), "Estimate for 3 open children: about $12.00, 10h of work (from 60 closed issues)");
  assert.equal(e.estimateSpentWords(epic), "Spent $4.10 on 2 closed children");
  assert.equal(e.childEstimateWords(story), "est. $3.20 · 2h 10m");
  assert.equal(e.showsEstimate({ ...epic, openChildren: 0 }), false);
});

test("a closed issue says the estimate at its start against the actual (#3561)", () => {
  assert.equal(e.actualWords(story), undefined);
  const kept = { at: 0, matchedBy: "level", matches: 31, cost: { USD: 3.2 }, workingSeconds: 7800 };
  assert.equal(e.actualWords({ ...story, kept }), undefined);
  const actual = { cost: { USD: 4.1 }, inputTokens: 0, outputTokens: 0, turns: 1, workingSeconds: 10800, waitingSeconds: 0 };
  assert.equal(e.actualWords({ ...story, kept, actual }), "Estimated $3.20, 2h 10m of work; actual $4.10, 3h of work");
  assert.equal(e.actualWords({ ...story, kept: { at: 0, matches: 0 }, actual }), undefined);
});
