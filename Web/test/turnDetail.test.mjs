// Opening and closing a turn (#993, #759, #1315).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const t = await load("src/model/turnDetail.ts");
const turns = await load("src/model/turns.ts");

test("a turn starts open, and its N steps closes it and opens it again", () => {
  assert.equal(t.initialDetail, "open");
  assert.equal(t.toggled(t.initialDetail), "collapsed");
  assert.equal(t.toggled("collapsed"), "open");
});

test("a thought folds to its first words, as TranscriptItem.thoughtLine does", () => {
  assert.equal(turns.thoughtLine("**Planning the fix**\n\nRead   the file first."), "Thought: Planning the fix Read the file first.");
  const long = Array.from({ length: 30 }, (_, i) => String(i + 1)).join(" ");
  assert.equal(turns.thoughtLine(long), `Thought: ${Array.from({ length: 24 }, (_, i) => String(i + 1)).join(" ")}`);
  assert.equal(turns.thoughtLine(" \n "), "Thought");
});
