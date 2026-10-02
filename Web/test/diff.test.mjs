// An edit as a line diff, as LineDiff.rows has it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { lineDiff } = await load("src/model/diff.ts");
const kinds = (rows) => rows.map((r) => `${r.kind[0]} ${r.text}`);

test("a line added at the end keeps the rest as context", () => {
  assert.deepEqual(kinds(lineDiff("# Work\n\nA project.\n", "# Work\n\nA project.\n\nEdited.\n")),
    ["c # Work", "c ", "c A project.", "a ", "a Edited."]);
});

test("a changed line is removed then added", () => {
  assert.deepEqual(kinds(lineDiff("a\nb\nc", "a\nB\nc")), ["c a", "r b", "a B", "c c"]);
});

test("no old text is a file made; no new text a passage deleted", () => {
  assert.deepEqual(kinds(lineDiff(undefined, "x\ny\n")), ["a x", "a y"]);
  assert.deepEqual(kinds(lineDiff("x\ny", "")), ["r x", "r y"]);
});

const { wantsWhole } = await load("src/model/diff.ts");

test("a file with no edits to show is shown whole, where git can say (ChangeFileView)", () => {
  const git = { owned: { since: "abc" } };
  const file = (more) => ({ path: "/w/a", state: "untracked", editCount: 0, inProgress: false, outsideFolder: false, ...more });
  assert.equal(wantsWhole(file({}), git), true);
  assert.equal(wantsWhole(file({ editCount: 2 }), git), false);
  assert.equal(wantsWhole(file({ inProgress: true }), git), false);
  assert.equal(wantsWhole(file({ outsideFolder: true }), git), false);
  assert.equal(wantsWhole(file({ state: "binary" }), git), false);
  assert.equal(wantsWhole(file({}), { unavailable: { notARepository: {} } }), false);
  assert.equal(wantsWhole(undefined, git), false);
});
