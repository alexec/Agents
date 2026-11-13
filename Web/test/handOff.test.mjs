// An agent's hand_to_person (#3529): the answer as the window's and the Remote's HandOffCard
// send it, Done, or Can't do it with what stopped the person.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const h = await load("src/model/handOff.ts");

test("hand-off: the choice the host names, and a note only when one is typed", () => {
  assert.deepEqual(h.handOffAnswer(true), { outcome: "done" });
  assert.deepEqual(h.handOffAnswer(false, "  "), { outcome: "cannot" });
  assert.deepEqual(h.handOffAnswer(false, " It wants a phone number. "), { outcome: "cannot", outcome_note: "It wants a phone number." });
});

test("hand-off: a step in the agents' own Chrome says that window, as the Mac does (#5095)", () => {
  assert.equal(h.handOffWindowWords("the agents' Chrome (DevTools port 9233)", "your Mac"),
    "Do it in the agents' Chrome (DevTools port 9233) on your Mac.");
});
