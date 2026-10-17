// The agent's caret on a live page (#1236), as PageFollowerTests has it on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/caret.ts");
const p = await load("src/model/passages.ts");

const sources = (text) => p.split(text).map((x) => x.source);
const typedOut = (caret, after) => {
  let ticks = 0;
  while (caret.revealing) { caret = c.tick(caret, after); ticks++; }
  return ticks;
};

test("the pace is 8 characters every 40 ms, 200 a second", () => {
  assert.equal(c.typingStep, 8);
  assert.equal(c.typingTick, 40);
  assert.equal(c.typingStep * 1000 / c.typingTick, 200);
});

test("a write queues its passages for one caret in document order", () => {
  const before = sources("# Title\n\nOne.\n\nTwo.\n");
  const after = sources("# Title\n\nOne, more.\n\nTwo.\n\nThree.\n");
  let caret = c.reveal(before, after, [3, 1]);
  assert.equal(caret.revealing.index, 1);
  assert.deepEqual(caret.pending.map((r) => r.index), [3]);
  // The rewritten passage types from where it stopped agreeing, not from the top.
  assert.equal(c.shown(caret, 1, after[1]), "One");
  // The appended one is not on the page until its turn.
  assert.equal(c.shown(caret, 3, after[3]), "");
  assert.equal(c.shown(caret, 2, after[2]), "Two.");
  caret = c.tick(caret, after);
  assert.equal(c.shown(caret, 1, after[1]), "One, more.".slice(0, 3 + 8));
  typedOut(caret, after);
});

test("a long passage takes one tick per 8 characters", () => {
  const after = ["x".repeat(80)];
  assert.equal(typedOut(c.reveal([], after, [0]), after), 10);
});

test("a rewritten passage waiting its turn keeps its old words", () => {
  const before = ["A.", "Old words."];
  const after = ["A, again.", "New words."];
  const caret = c.reveal(before, after, [0, 1]);
  assert.equal(c.shown(caret, 1, after[1]), "Old words.");
});

test("nothing new to type is nothing queued", () => {
  assert.equal(c.reveal(["One.", "Two."], ["One."], [1]).revealing, null);
  assert.equal(c.reveal(["One, more."], ["One"], [0]).revealing, null);
});

test("opening a passage being typed gives it whole and moves the caret on", () => {
  const after = ["One, more.", "Two, more."];
  let caret = c.reveal(["One.", "Two."], after, [0, 1]);
  caret = c.skip(caret, 0);
  assert.equal(caret.revealing.index, 1);
  assert.equal(c.shown(caret, 0, after[0]), "One, more.");
  caret = c.skip(caret, 1);
  assert.equal(caret.revealing, null);
});

test("characters are counted whole, not in UTF-16 halves", () => {
  const after = ["😀".repeat(9)];
  const caret = c.tick(c.reveal([], after, [0]), after);
  assert.equal(c.shown(caret, 0, after[0]), "😀".repeat(8));
});
