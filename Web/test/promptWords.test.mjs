// The prompt bar's words for a queued helper and an empty options row (#542), as PromptWords says them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { promptPlaceholder, willQueue, sendLabel, nothingToAdjust } = await load("src/model/promptWords.ts");

test("a queued helper's prompt waits for it to start (#362)", () => {
  const agent = { state: "queued", queuedPrompts: [] };
  assert.equal(promptPlaceholder(agent), "Queued: what you type goes when it starts");
  assert.equal(willQueue(agent), true);
  assert.equal(sendLabel(willQueue(agent)), "Queue");
});

test("a finished agent's prompt goes at once", () => {
  const agent = { state: "finished", queuedPrompts: [] };
  assert.equal(promptPlaceholder(agent), "What do you want to do?");
  assert.equal(willQueue(agent), false);
});

test("nothing to adjust names the runtime", () => {
  assert.equal(nothingToAdjust("Claude"), "Claude has nothing to adjust.");
  assert.equal(nothingToAdjust(undefined), "This runtime has nothing to adjust.");
});
