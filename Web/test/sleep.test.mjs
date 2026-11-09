// Settings ▸ Machines ▸ Sleep (#4066): the two runtime pickers' words, as the window says them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const sleep = await load("src/model/sleep.ts");

test("the pickers go as far as the host keeps", () => {
  assert.deepEqual([...sleep.warmCounts], [0, 1, 2, 3, 4, 5, 6, 7, 8]);
  assert.equal(sleep.backgroundHourChoices[0], 1);
  assert.equal(sleep.backgroundHourChoices.at(-1), 24);
  assert.equal(sleep.backgroundHourChoices.length, 24);
});

test("each choice has words", () => {
  assert.deepEqual([0, 1, 3].map(sleep.sessionsLabel), ["None", "1 session", "3 sessions"]);
  assert.deepEqual([1, 4].map(sleep.hoursLabel), ["1 hour", "4 hours"]);
});

test("the footer says the warm pool's 10 minutes and the hours chosen, as the window does", () => {
  assert.equal(sleep.sleepFooter(4), "The sessions you are most likely to reply to keep their agent running for 10 minutes "
    + "after their turn ends, so the reply starts at once. An agent whose background processes still run (a dev server, "
    + "a build, a watcher) is kept for 4 hours, then ended with them. Neither keeps the Mac awake.");
  assert.match(sleep.sleepFooter(1), /kept for 1 hour, then/);
});
