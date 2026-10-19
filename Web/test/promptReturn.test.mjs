// Return in the prompt (#377): Return sends, and Shift-Return and Option-Return break the line (#1514),
// as in the window and the Remote.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { returnAction } = await load("src/model/promptWords.ts");

test("Return sends; Shift-Return and Option-Return are a line break", () => {
  assert.equal(returnAction({ altKey: false, shiftKey: false }), "send");
  assert.equal(returnAction({ altKey: false, shiftKey: true }), "lineBreak");
  assert.equal(returnAction({ altKey: true, shiftKey: false }), "lineBreak");
  assert.equal(returnAction({ altKey: true, shiftKey: true }), "lineBreak");
});

test("On a touch screen Return is a line break, as the Remote's on-screen keyboard (#543)", () => {
  assert.equal(returnAction({ altKey: false, shiftKey: false }, true), "lineBreak");
  assert.equal(returnAction({ altKey: false, shiftKey: true }, true), "lineBreak");
  assert.equal(returnAction({ altKey: false, shiftKey: false }, false), "send");
});
