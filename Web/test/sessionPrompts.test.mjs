// The Prompts list (#1658), as SessionPrompts.of and SessionPrompts.filtered say it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const p = await load("src/model/sessionPrompts.ts");

const row = ({ id, number, title, cost, seconds, ending }) => ({ id: id.toUpperCase(), number, title, cost, seconds, ending });

for (const { name, input, expected } of cases("prompts/list.json")) {
  test(`list: ${name}`, () => {
    assert.deepEqual(p.sessionPrompts(input.turns, input.entries, input.isRunning).map(row), expected);
  });
}

for (const { name, input, expected } of cases("prompts/filter.json")) {
  test(`filter: ${name}`, () => {
    const prompts = p.sessionPrompts(input.turns, input.entries, input.isRunning);
    assert.deepEqual(p.filteredPrompts(prompts, input.query).map((prompt) => prompt.number), expected);
  });
}
