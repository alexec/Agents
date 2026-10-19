// Undo after Archive (#1534), as ArchiveUndo.line says it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const a = await load("src/model/archiveWords.ts");

for (const { name, input, expected } of cases("archive/undo.json")) {
  test(`undo line: ${name}`, () => {
    assert.equal(a.undoLine(input.title, input.stopped), expected);
  });
}
