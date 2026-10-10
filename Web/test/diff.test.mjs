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

const { wantsWhole, shownDiff, offersDiffChoice, otherAgentsNote, changeStops, changeStep, canOpenInFiles } = await load("src/model/diff.ts");

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

test("Edits or Whole file, only when both can be shown, and a chosen Whole file sticks", () => {
  const git = { owned: { since: "abc" } };
  const both = { path: "/w/a", state: "modified", editCount: 2, inProgress: false, outsideFolder: false };
  const commandWrote = { ...both, editCount: 0, state: "untracked" };
  assert.equal(offersDiffChoice(both, git), true);
  assert.equal(shownDiff(undefined, both, git), "edits");
  assert.equal(shownDiff("whole", both, git), "whole");
  assert.equal(shownDiff("edits", both, git), "edits");
  assert.equal(offersDiffChoice(commandWrote, git), false);
  assert.equal(shownDiff("edits", commandWrote, git), "whole");
  assert.equal(shownDiff("whole", { ...both, state: "binary" }, git), "edits");
  assert.equal(offersDiffChoice(both, { shared: { since: "abc" } }), true);
  assert.equal(offersDiffChoice(both, { unavailable: { notARepository: {} } }), false);
});

test("the other-agents note is the window's, for a shared folder and for no starting point", () => {
  assert.equal(otherAgentsNote({ shared: { since: "abc" } }),
    "Also shows what git sees changed in this folder since the agent started. That may include other agents' work, and yours.");
  assert.equal(otherAgentsNote({ sharedFromHead: {} }),
    "This agent started before its starting point was recorded, so git's part is only what is uncommitted, and may include others' work.");
  assert.equal(otherAgentsNote({ owned: { since: "abc" } }), null);
  assert.equal(otherAgentsNote({ unavailable: { folderGone: {} } }), null);
  assert.equal(otherAgentsNote(undefined), null);
});

test("Previous and Next land on the first line of each change, as LineDiff.changeStops", () => {
  const lines = lineDiff("a\nb\nc\nd\ne\nf", "a\nB\nc\nd\nE\nF");
  assert.deepEqual(changeStops(lines), [1, 5]);
  assert.deepEqual(changeStep([1, 5], undefined, "previous"), { to: 1, enabled: false });
  assert.deepEqual(changeStep([1, 5], undefined, "next"), { to: 1, enabled: true });
  assert.deepEqual(changeStep([1, 5], 1, "previous"), { to: 1, enabled: false });
  assert.deepEqual(changeStep([1, 5], 1, "next"), { to: 5, enabled: true });
  assert.deepEqual(changeStep([1, 5], 5, "previous"), { to: 1, enabled: true });
  assert.deepEqual(changeStep([1, 5], 5, "next"), { to: 5, enabled: false });
  assert.deepEqual(changeStops([{ kind: "added" }, { kind: "added" }, { kind: "context" }, { kind: "removed" }]), [0, 3]);
});

test("Open in Files is offered unless the file is gone", () => {
  const file = (state) => ({ path: "/w/a", state, editCount: 1, inProgress: false, outsideFolder: false });
  assert.equal(canOpenInFiles(file("modified")), true);
  assert.equal(canOpenInFiles(file("added")), true);
  assert.equal(canOpenInFiles(file("deleted")), false);
  assert.equal(canOpenInFiles(undefined), true);
});

const { wordMarks, markWords, tokens } = await load("src/model/diff.ts");

test("a line in words: words, spaces and each other character alone (WordDiff.tokens)", () => {
  assert.deepEqual(tokens("let x = f(a_1);").map((t) => t.text), ["let", " ", "x", " ", "=", " ", "f", "(", "a_1", ")", ";"]);
});

test("the words that changed are marked on each side, neighbours merged", () => {
  assert.deepEqual(wordMarks("let x = foo(bar);", "let x = baz(qux);"), { old: [[8, 11], [12, 15]], next: [[8, 11], [12, 15]] });
  assert.deepEqual(wordMarks("call(a)", "call(a, b)"), { old: [], next: [[6, 9]] });
  assert.deepEqual(wordMarks("foo(bar", "x"), null, "too little in common is a rewrite");
});

test("offsets are UTF-16, as the window's are", () => {
  assert.deepEqual(wordMarks("say 😀 hi", "say 😀 yo"), { old: [[7, 9]], next: [[7, 9]] });
});

test("too long a line is not compared", () => {
  const long = "a ".repeat(600);
  assert.equal(wordMarks(long, long + "b"), null);
});

test("removed and added lines of a block pair first with first (LineDiff.markWords)", () => {
  const rows = markWords(lineDiff("a\nlet x = 1;\nlet y = 2;\nz", "a\nlet x = 3;\nlet y = 2;\nnew\nz"));
  assert.deepEqual(rows.map((r) => [r.kind[0], r.text, r.changed]), [
    ["c", "a", undefined],
    ["r", "let x = 1;", [[8, 9]]],
    ["a", "let x = 3;", [[8, 9]]],
    ["c", "let y = 2;", undefined],
    ["a", "new", undefined],
    ["c", "z", undefined],
  ]);
});
