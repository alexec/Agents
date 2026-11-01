import assert from "node:assert/strict";
import { test } from "node:test";
import { load } from "./load.mjs";

const status = await load("src/model/status.ts");

test("Needs You uses the question's first line", () => {
  assert.equal(status.needsYouLine({ state: "waitingOnUser" }, "May I run this?\nMore detail"), "May I run this?");
});

test("Needs You says why an agent stopped or finished without a report", () => {
  assert.equal(status.needsYouLine({ state: "stopped", endedReason: "daemonGone" }), "Stopped with the daemon");
  assert.equal(status.needsYouLine({ state: "finished", endedReason: "endTurn", outcomeAsked: true }),
    "Finished without saying how it went");
});

test("the report line returns when the session no longer needs you", () => {
  assert.equal(status.needsYouLine({ state: "finished", report: { outcome: "done" } }), null);
  assert.equal(status.needsYouLine({ state: "waitingOnUser" }, "  \n "), null);
});

test("a wait only the person can settle says what it asks of them (#3147)", () => {
  const wait = { id: "w", from: 4, since: 0, forPerson: true, patterns: [{ name: "review.requested", filters: {} }],
    serverEvents: [{ servers: ["github"], trigger: { event: "review.requested", arguments: { repo: "alexec/Agents", pr: 123 } } }] };
  const agent = { state: "finished", endedReason: "endTurn", eventWait: wait };
  assert.equal(status.needsYouLine(agent), "Review requested: alexec/Agents#123");
  assert.equal(status.statusWords(agent), "Review requested: alexec/Agents#123");
  assert.equal(status.statusWords({ ...agent, isUnread: true }), "Unread · Review requested: alexec/Agents#123");
  assert.equal(status.needsYouLine({ ...agent, eventWait: { ...wait, serverEvents: undefined, patterns: [{ name: "issue.assigned", filters: {} }] } }),
    "Issue assigned");
  assert.equal(status.needsYouLine({ ...agent, eventWait: { ...wait, ending: { timedOut: {} } } }), null);
  assert.equal(status.statusWords({ ...agent, report: { outcome: "needs_answer" } }), "Waiting on your answer");
});
