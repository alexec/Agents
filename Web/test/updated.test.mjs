// The Needs You heading says when its count was last true while the link is lost (#1163).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { updatedLine } = await load("src/model/updated.ts");

test("the same day says the time alone", () => {
  const at = new Date(2026, 9, 16, 14, 2).getTime();
  assert.equal(updatedLine(at, new Date(2026, 9, 16, 18, 30).getTime()), "Updated 14:02");
});

test("an earlier day says which", () => {
  const at = new Date(2026, 9, 13, 9, 5).getTime();
  const said = updatedLine(at, new Date(2026, 9, 16, 9, 0).getTime());
  assert.match(said, /^Updated \S+ 09:05$/);
  assert.notEqual(said, "Updated 09:05");
});
