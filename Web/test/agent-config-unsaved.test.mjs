// Unsaved edits in the Skills, Personas and Workflows editor (#2745): a tab, Done or Escape
// asks before it drops them, and leaves at once when there are none.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { mayLeave, discardQuestion } = await load("src/views/AgentConfigEditor.tsx");

test("nothing unsaved leaves without asking", () => {
  assert.equal(mayLeave(false, () => assert.fail("asked")), true);
});

test("unsaved edits ask, and stay unless discarded", () => {
  const asked = [];
  assert.equal(mayLeave(true, (question) => { asked.push(question); return false; }), false);
  assert.equal(mayLeave(true, (question) => { asked.push(question); return true; }), true);
  assert.deepEqual(asked, [discardQuestion, discardQuestion]);
});
