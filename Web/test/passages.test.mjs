// A live page's passages and merge, as Swift has them (research R7).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const p = await load("src/model/passages.ts");

for (const { name, input, expected } of cases("page/passages.json")) {
  test(`passages: ${name}`, () => {
    const passages = p.split(input.text);
    assert.deepEqual({
      passages,
      roundTrip: p.join(passages) === input.text,
      lineIndex: Array.from({ length: 13 }, (_, line) => p.indexContaining(line, passages)),
    }, expected);
  });
}

for (const { name, input, expected } of cases("page/merge.json")) {
  test(`merge: ${name}`, () => {
    const mine = p.split(input.base)[input.mine];
    assert.deepEqual(p.merge(input.base, input.theirs, mine, input.edited), expected);
  });
}
