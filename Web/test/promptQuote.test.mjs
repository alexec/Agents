// Quote in Prompt (#1553), as PromptQuote.adding says it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const q = await load("src/model/promptQuote.ts");

for (const { name, input, expected } of cases("prompt/quote.json")) {
  test(`quote: ${name}`, () => {
    assert.equal(q.quoteInto(input.quote, input.text), expected);
  });
}
