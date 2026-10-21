// The Prompts list (#1658), as SessionPrompts.of and SessionPrompts.filtered say it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const p = await load("src/model/sessionPrompts.ts");

const row = ({ id, number, title, cost, seconds, ending }) => ({ id: id.toUpperCase(), number, title, cost, seconds, ending });

for (const { name, input, expected } of cases("prompts/list.json")) {
  test(`list: ${name}`, () => {
    assert.deepEqual(p.sessionPrompts(input.turns, input.entries, input.isRunning, input.earlier).map(row), expected);
  });
}

for (const { name, input, expected } of cases("prompts/filter.json")) {
  test(`filter: ${name}`, () => {
    const prompts = p.sessionPrompts(input.turns, input.entries, input.isRunning);
    assert.deepEqual(p.filteredPrompts(prompts, input.query).map((prompt) => prompt.number), expected);
  });
}

const wire = (ms) => (ms - Date.UTC(2001, 0, 1)) / 1000;
const sent = { id: "A", number: 1, text: "Fix it", title: "Fix it", at: wire(Date.UTC(2026, 9, 20, 14, 5)), cost: null, seconds: null, ending: null };

test("line: cost, duration and time, each left out when not known", () => {
  const now = new Date(Date.UTC(2026, 9, 20, 18, 0));
  assert.equal(p.promptLine(sent, now, "UTC"), "14:05");
  assert.equal(p.promptLine({ ...sent, seconds: 190 }, now, "UTC"), "3m · 14:05");
  const line = p.promptLine({ ...sent, cost: { amount: 0.12, currency: "USD" }, seconds: 45 }, now, "UTC");
  assert.match(line, /0\.12 · 45s · 14:05$/);
});

test("line: the day on another day, and the year in another year", () => {
  assert.equal(p.promptLine(sent, new Date(Date.UTC(2026, 9, 22, 9, 0)), "UTC"), "20 Oct 14:05");
  assert.equal(p.promptLine(sent, new Date(Date.UTC(2027, 0, 2, 9, 0)), "UTC"), "20 Oct 2026 14:05");
});

test("the mark's words", () => {
  assert.equal(p.endingLabel("stopped"), "Stopped");
  assert.equal(p.endingLabel("failed"), "Failed");
});

test("Up and Down stop at the ends; none chosen is the newest", () => {
  assert.equal(p.movedTo(null, 0, true), null);
  assert.equal(p.movedTo(null, 3, false), 2);
  assert.equal(p.movedTo(2, 3, true), 2);
  assert.equal(p.movedTo(2, 3, false), 1);
  assert.equal(p.movedTo(0, 3, false), 0);
});
