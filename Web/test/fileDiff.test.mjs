// A file's change as numbered rows, folds, breaks and pairs (#1472), as CodeText's HunkRowsTests.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { hunkRows, breaks, sideBySide, folds, diffItems } = await load("src/model/fileDiff.ts");
const hunk = (kinds, oldStart = 1, newStart = 1) => ({
  oldStart, newStart, lines: kinds.split("").map((k, i) => ({ kind: { c: "context", r: "removed", a: "added" }[k], text: `${k}${i}` })),
});

test("a hunk numbers both sides", () => {
  const rows = hunkRows([hunk("crac")]);
  assert.deepEqual(rows.map((r) => r.oldLine), [1, 2, undefined, 3]);
  assert.deepEqual(rows.map((r) => r.newLine), [1, undefined, 2, 3]);
  assert.equal(breaks(rows).size, 0);
});

test("a second hunk further on starts a break", () => {
  const rows = hunkRows([hunk("ca"), hunk("rc", 40, 41)]);
  assert.deepEqual([...breaks(rows)], [2]);
});

test("side by side pairs removed with added", () => {
  const rows = hunkRows([hunk("crraca")]);
  assert.deepEqual(sideBySide([0, 1, 2, 3, 4, 5], rows), [[0, 0], [1, 3], [2, undefined], [4, 4], [undefined, 5]]);
});

test("a long unchanged run is folded, three lines kept beside the change", () => {
  const rows = hunkRows([hunk("a" + "c".repeat(20))]);
  assert.deepEqual(folds(rows), [{ from: 4, to: 21 }]);
  const items = diffItems(rows, new Set(), false);
  assert.deepEqual(items.map((i) => i.kind), ["row", "row", "row", "row", "fold"]);
  assert.equal(diffItems(rows, new Set([4]), false).length, 21);
});
