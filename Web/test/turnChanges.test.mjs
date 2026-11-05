// What a turn changed, and its undo (#3437), as TurnChangesTests checks it in Swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const turns = await load("src/model/turns.ts");
const words = await load("src/model/turnChanges.ts");

const changes = { turn: "u", files: [{ path: "/r/a.txt", relativePath: "a.txt", state: "modified" }, { path: "/r/n.txt", state: "added" }], more: 3 };

test("the card stands at the end of its turn, at every level", () => {
  const entries = [
    { id: "u", at: 0, kind: { userMessage: { _0: "Fix it" } } },
    { id: "m", at: 1, kind: { agentMessage: { text: "Fixed." } } },
    { id: "c", at: 2, kind: { turnChanged: { _0: changes } } },
  ];
  const items = turns.display(entries);
  const [turn] = turns.turns(items);
  assert.ok(turns.turnParts(turn.items, false).outcome.some((i) => i.id === "c"));
  assert.equal(words.changedTitle(changes), "Changed 5 files");
});

// The undo is said on the card, and is no line of its own.
test("an undo is said on the card", () => {
  const entries = [
    { id: "c", at: 2, kind: { turnChanged: { _0: changes } } },
    { id: "d", at: 3, kind: { turnUndone: { _0: { turn: "u", putBack: ["/r/a.txt"] } } } },
  ];
  const items = turns.display(entries);
  assert.deepEqual(items.map((i) => i.id), ["c"]);
  assert.deepEqual(items[0].entry.kind.turnChanged._0.undone, { turn: "u", putBack: ["/r/a.txt"] });
  assert.equal(words.undoneWords(items[0].entry.kind.turnChanged._0.undone), "Undone: 1 file is back as it was before this turn.");
  // One whose card is on an earlier page is left out.
  assert.deepEqual(turns.display([entries[1]]), []);
});

test("the question names the files, as on the Mac", () => {
  assert.equal(words.confirmMessage(["/r/a.txt", "/r/b.txt"]),
    "a.txt and b.txt changed again after this turn. Undo puts them back as before the turn, and the later changes go too.");
  assert.equal(words.cannotUndoWords(["/elsewhere/x.txt"]), "Undo cannot put back x.txt: it is outside the folder or ignored by git.");
});
