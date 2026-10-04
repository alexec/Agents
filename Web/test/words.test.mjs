// Background words and labels, as Swift has them (research R7).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const background = await load("src/model/background.ts");
const labels = await load("src/model/labels.ts");

for (const { name, input, expected } of cases("background/words.json")) {
  test(`background: ${name}`, () => {
    assert.deepEqual({
      mark: background.backgroundMark(input.items),
      rows: input.items.map((item) => ({ id: item.id, noun: background.backgroundNoun(item),
        ending: background.backgroundEnding(item), ended: background.backgroundEnded(item),
        age: background.backgroundAge(item, input.now), isRunning: background.isRunning(item) })),
    }, expected);
  });
}

for (const { name, input, expected } of cases("labels/policy.json")) {
  test(`labels: ${name}`, () => {
    const split = labels.splitTyped(input.typed);
    assert.deepEqual({ ...split, accepted: labels.accepted(split.finished, input.existing) }, expected);
  });
}

for (const { name, input, expected } of cases("labels/query.json")) {
  test(`query: ${name}`, () => {
    const query = labels.parseQuery(input.query);
    assert.deepEqual({ ...query, matches: labels.queryMatches(query, input.agent) }, expected);
  });
}

// Who is asking at the head of a card (#121), as AgentsModel.askerLine says it.
const asker = await load("src/model/asker.ts");

for (const { name, input, expected } of cases("asker/line.json")) {
  test(`asker: ${name}`, () => {
    assert.equal(asker.askerFor(input.agents, input.agentID, (id) => input.runtimes[id], input.subagent ?? undefined), expected);
  });
}

const disk = await load("src/model/disk.ts");

for (const { name, input, expected } of cases("disk/lines.json")) {
  test(`disk: ${name}`, () => {
    assert.equal(disk.diskLine(input), expected);
  });
}
