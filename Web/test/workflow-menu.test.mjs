// What a workflow row's menu offers (#547), as the window's WorkflowListRow's context menu.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { workflowActions, lastRan } = await load("src/views/WorkflowRow.tsx");
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

test("an archived one can be unarchived or deleted (#605)", () => {
  assert.deepEqual(workflowActions(summary({ isArchived: true }), false), ["open", "unarchive", "delete"]);
});

test("the row's end says when it last ran, and nothing for one that never has (#755)", () => {
  assert.equal(lastRan(summary()), null);
  // Seconds since 2001, as the wire's dates are; the first of them is still a time.
  assert.equal(lastRan(summary({ lastFiredAt: 0 }))?.toISOString(), "2001-01-01T00:00:00.000Z");
  assert.equal(lastRan(summary({ lastFiredAt: 3_600, isRunning: true }))?.toISOString(), "2001-01-01T01:00:00.000Z");
});

test("on a host that can, Mute Notifications or Unmute after Turn Off (#2003)", () => {
  assert.deepEqual(workflowActions(summary(), false, undefined, true), ["open", "runNow", "pin", "turnOff", "mute", "archive", "delete"]);
  const muted = summary();
  muted.workflow.muted = true;
  assert.deepEqual(workflowActions(muted, false, undefined, true), ["open", "runNow", "pin", "turnOff", "unmute", "archive", "delete"]);
  assert.deepEqual(workflowActions(summary({ isArchived: true }), false, undefined, true), ["open", "unarchive", "delete"]);
});
