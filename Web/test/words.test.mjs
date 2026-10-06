// Background words and labels, as Swift has them (research R7).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const background = await load("src/model/background.ts");
const labels = await load("src/model/labels.ts");

test("background transcript lines include starts, subagents and failure tint wording", () => {
  const item = { id: "work", kind: "task", name: "Build", state: "running", canStop: true, isStopping: false, startedAt: 0 };
  assert.equal(background.backgroundEntryLine(item), "Started “Build” in the background");
  assert.equal(background.backgroundEntryLine({ ...item, kind: "subagent", state: "paused" }), "Started subagent “Build” in the background");
  assert.equal(background.backgroundEntryLine({ ...item, state: "failed" }), "Task “Build” failed");
});

const sandboxWords = await load("src/model/sandboxWords.ts");

test("sandbox failure card explains the recovery and preserves the two choices", () => {
  const record = { runtimeID: "codex", detail: "sandbox unavailable", hang: false, recoveryOffered: true, completedToolCalls: 2 };
  const card = sandboxWords.sandboxCard(record);
  assert.equal(card.title, "Codex’s sandbox could not start");
  assert.match(card.body, /could not isolate commands/);
  assert.match(card.offer, /Full access/);
  assert.match(card.offer, /asks it to carry on/);
  assert.equal(sandboxWords.keepStopped, "Keep stopped");
  assert.equal(sandboxWords.continueWithout, "Continue without sandbox");
});

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
