// What the chat's foot says to a screen reader (#2391): the working line's words as text, kept
// while a call's line has the tool mark, so a change of tool is read out.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const status = await load("src/model/status.ts");

test("a running tool is named, thinking is Working", () => {
  assert.equal(status.footStatusWords({ state: "running", runningTool: "swift test" }), "Running: swift test");
  assert.equal(status.footStatusWords({ state: "running", runningTool: "Bash" }), "Running: Bash");
  assert.equal(status.footStatusWords({ state: "running" }), "Working");
  assert.equal(status.footStatusWords({ state: "starting" }), "Working");
});

test("coming back says so; an idle chat says nothing", () => {
  assert.equal(status.footStatusWords({ state: "running" }, true), status.comingBackDescription);
  for (const state of ["finished", "stopped", "waitingOnUser", "queued", "archived"]) {
    assert.equal(status.footStatusWords({ state }), "");
  }
});
