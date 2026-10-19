// Up and Down in the prompt bar (#1551), as PromptHistory.recall and PromptHistory.sent say them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const h = await load("src/model/promptHistory.ts");

for (const { name, input, expected } of cases("prompt/recall.json")) {
  test(`recall: ${name}`, () => {
    assert.deepEqual(h.recall(input.direction, input.text, input.sent, input.at), expected);
  });
}

for (const { name, input, expected } of cases("prompt/sent.json")) {
  test(`sent: ${name}`, () => {
    assert.deepEqual(h.sentPrompts(input.turns, input.entries), expected);
  });
}
