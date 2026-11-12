import assert from "node:assert/strict";
import { test } from "node:test";
import { load } from "./load.mjs";

const words = await load("src/model/driveApproval.ts");

test("Browser and Desktop control are Ask, Always Approve or Off, in the approval words (#4264)", () => {
  assert.deepEqual(words.driveApprovals.map((m) => m.label), ["Ask", "Always Approve", "Off"]);
  for (const { mode } of words.driveApprovals) {
    assert.ok(words.screenFooter(mode).length > 0 && words.browserFooter(mode).length > 0);
  }
  assert.match(words.screenFooter("ask"), /Needs you/);
});

test("a host before #4264 says only enabled: On is Always Approve, Off is Off", () => {
  assert.equal(words.shownMode({ enabled: true }), "always");
  assert.equal(words.shownMode({ enabled: false }), "off");
  assert.equal(words.shownMode({ enabled: true, mode: "ask" }), "ask");
});
