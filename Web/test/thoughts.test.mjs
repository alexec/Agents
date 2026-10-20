// Show thoughts (#1725): off leaves every thought off the chat, on draws them as #1315 did.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { showsThoughts, shownItems } = await load("src/model/thoughts.ts");

const entry = (id, kind) => ({ kind: "entry", id, entry: { id, kind } });
const thought = entry("t", { agentThought: { messageID: "m", text: "Planning" } });
const reply = entry("r", { agentMessage: { messageID: "n", text: "Done", blocks: [] } });

test("off at first", () => {
  assert.equal(showsThoughts.value, false);
});

test("off leaves the thoughts off and the rest on", () => {
  assert.deepEqual(shownItems([thought, reply], false).map((i) => i.id), ["r"]);
});

test("on keeps the thoughts", () => {
  assert.deepEqual(shownItems([thought, reply], true).map((i) => i.id), ["t", "r"]);
});
