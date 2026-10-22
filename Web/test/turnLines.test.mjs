// A turn's lines (#759, #1315). Every turn draws its steps, with no control to close them (#2170).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const turns = await load("src/model/turns.ts");

test("a thought folds to its first words, as TranscriptItem.thoughtLine does", () => {
  assert.equal(turns.thoughtLine("**Planning the fix**\n\nRead   the file first."), "Thought: Planning the fix Read the file first.");
  const long = Array.from({ length: 30 }, (_, i) => String(i + 1)).join(" ");
  assert.equal(turns.thoughtLine(long), `Thought: ${Array.from({ length: 24 }, (_, i) => String(i + 1)).join(" ")}`);
  assert.equal(turns.thoughtLine(" \n "), "Thought");
});
