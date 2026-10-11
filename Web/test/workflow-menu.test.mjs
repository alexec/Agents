// What a workflow row's menu offers (#547), as the window's WorkflowListRow's context menu.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { workflowActions } = await load("src/views/WorkflowRow.tsx");
const summary = (fields = {}) => ({ workflow: { workflowID: "n", triggers: [], mode: "new", prompt: "", settings: {}, unknownFields: {} },
  isArchived: false, isEnabled: true, isRunning: false, ...fields });

test("an approved one runs now, pins, turns off, archives and can be deleted (#605)", () => {
  assert.deepEqual(workflowActions(summary(), false), ["open", "runNow", "pin", "turnOff", "archive", "delete"]);
  assert.deepEqual(workflowActions(summary({ isEnabled: false }), true), ["open", "runNow", "unpin", "turnOn", "archive", "delete"]);
});

test("under Pinned it moves up and down too", () => {
  assert.deepEqual(workflowActions(summary(), true, ["n", "m"]), ["open", "runNow", "unpin", "moveUp", "moveDown", "turnOff", "archive", "delete"]);
});

test("one waiting for its OK is approved or denied here, not run (#391)", () => {
  assert.deepEqual(workflowActions(summary({ awaitingApproval: {} }), false), ["open", "approve", "deny", "pin", "turnOff", "archive", "delete"]);
  assert.deepEqual(workflowActions(summary({ deniedHere: true }), false), ["open", "approve", "pin", "turnOff", "archive", "delete"]);
});

test("an archived one can be brought back or deleted (#605)", () => {
  assert.deepEqual(workflowActions(summary({ isArchived: true }), false), ["open", "bringBack", "delete"]);
});
