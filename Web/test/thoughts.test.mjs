// Show thoughts (#1725): off leaves every thought off the chat, on draws them as #1315 did.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { showsThoughts, shownItems, thoughtsItem } = await load("src/model/thoughts.ts");

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

// #1848: with thoughts hidden, the runs a thought split are joined; while their calls are the
// same, the joined run is the same object, so keepingTurns keeps the turn and it is not drawn again.
const { keepingTurns } = await load("src/model/turns.ts");
const call = (id) => ({ id, title: id });
const run = (id, calls) => ({ kind: "run", id, calls });

test("a joined run is the same object while its calls are (#1848)", () => {
  const first = run("a", [call("read")]);
  const second = run("b", [call("patch")]);
  const page = [first, thought, second, reply];
  // A new page per entry, as the store makes one, holding the same items.
  const before = shownItems([...page], false);
  const after = shownItems([...page], false);
  assert.notEqual(before, after);
  assert.equal(before.length, 2);
  assert.equal(after[0], before[0]);
  const turn = (items) => [{ id: "T", ask: reply, items }];
  const held = turn(before);
  assert.equal(keepingTurns(turn(after), held)[0], held[0]);
});

test("a joined run is made again when a call joins it (#1848)", () => {
  const first = run("a", [call("read")]);
  const before = shownItems([first, thought, run("b", [call("patch")])], false);
  const after = shownItems([first, thought, run("b", [call("patch"), call("test")])], false);
  assert.notEqual(after[0], before[0]);
  assert.deepEqual(after[0].calls.map((c) => c.id), ["read", "patch", "test"]);
  assert.equal(after[0].id, "a");
});

test("the chat menu's item says what it will do, as Show Inspector does (#2383)", () => {
  assert.equal(thoughtsItem(false).label, "Show Thoughts");
  assert.equal(thoughtsItem(true).label, "Hide Thoughts");
});
