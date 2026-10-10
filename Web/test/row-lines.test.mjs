// A session row's lines beyond its report (#251), in the words of LeaseStatus, WaitStatus,
// AgentsModel.startedByAgentLabel and WorktreeBadge.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const lines = await load("src/model/rowLines.ts");
/** A Date as the wire writes it: seconds since 2001-01-01. */
const wire = (date) => date.getTime() / 1000 - 978_307_200;
const titles = { a: "Fix login", b: "Ship it" };
const title = (id) => titles[id];

test("ordinals and clocks as LeaseWords says them", () => {
  assert.deepEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 101].map(lines.ordinal),
    ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "101st"]);
  assert.equal(lines.clock(new Date(2026, 9, 4, 9, 5)), "09:05");
});

test("a lease held is the row's mark, a wait after it is one more", () => {
  const now = new Date(2026, 9, 4, 14, 0);
  const snapshot = { at: wire(now), resources: [
    { name: "screen", kind: "screen", displayName: "The screen", isGone: false, line: [], endingSoon: false,
      holds: [{ resource: "screen", displayName: "The screen", holder: "me", grantedAt: wire(now),
        expiresAt: wire(new Date(now.getTime() + 18 * 60_000)), warned: false }] },
    { name: "build", kind: "named", displayName: "build", isGone: false, endingSoon: false,
      line: [{ agentID: "x", askedAt: 0, isCallOpen: true }, { agentID: "me", askedAt: 0, isCallOpen: true }],
      holds: [{ resource: "build", displayName: "build", holder: "a", grantedAt: wire(now),
        expiresAt: wire(new Date(2026, 9, 4, 14, 12)), warned: false }] },
  ] };
  const mark = lines.leaseMark("me", snapshot, title);
  assert.equal(mark.mark, "▣ Holds Screen · 18 min");
  assert.equal(mark.more, 1);
  assert.equal(mark.full, "Holding The screen, 18 min left, until 14:18. Waiting for build, held by “Fix login” until 14:12, 2nd in line.");
  assert.equal(lines.leaseMark("nobody", snapshot, title), null);
  assert.equal(lines.leaseMark("x", snapshot, title).mark, "◷ Waiting for build · 1st in line");
  // A row shows only what it holds (#582); what it waits for is the wait line's.
  assert.deepEqual(mark.holds, { mark: "▣ Holds Screen · 18 min", more: 0, full: "Holding The screen, 18 min left, until 14:18." });
  assert.deepEqual(mark.waitingNames, ["build"]);
  assert.equal(lines.leaseMark("x", snapshot, title).holds, null);
});

test("a lease in its last five minutes says left", () => {
  const now = new Date(2026, 9, 4, 14, 0);
  const snapshot = { at: wire(now), resources: [{ name: "screen", kind: "screen", displayName: "Screen", isGone: false,
    line: [], endingSoon: true, holds: [{ resource: "screen", displayName: "Screen", holder: "me", grantedAt: wire(now),
      expiresAt: wire(new Date(now.getTime() + 3 * 60_000)), warned: true }] }] };
  assert.equal(lines.leaseMark("me", snapshot, title).mark, "▣ Holds Screen · 3 min left");
});

test("a wait on agents finishing reads as a block does; any other wait by its patterns", () => {
  const wait = (patterns, ending) => ({ state: "finished", eventWait: { id: "w", patterns, from: 0, since: 0, ...(ending ? { ending } : {}) } });
  assert.equal(lines.eventWaitMark(wait([{ name: "agent.finished", filters: { agent: "a" } }]), title), "◷ Waiting for “Fix login” to finish");
  assert.equal(lines.eventWaitMark(wait([{ name: "agent.finished", filters: { agent: "a" } }, { name: "agent.finished", filters: { agent: "b" } }]), title),
    "◷ Waiting for “Fix login” and “Ship it” to finish");
  assert.equal(lines.eventWaitMark(wait([{ name: "workflow.completed", filters: { workflow: "nightly", outcome: "done|failed" },
    anyOf: { outcome: ["done", "failed"] } }]), title), "◷ Waiting for workflow.completed outcome done|failed workflow nightly");
  assert.equal(lines.eventWaitMark(wait([{ name: "agent.finished", filters: { agent: "a" } }], { timedOut: {} }), title), null);
  assert.equal(lines.eventWaitMark({ state: "running" }, title), null);
});

test("a waiting row is one line: the first thing it waits for and how many more (#582)", () => {
  assert.equal(lines.rowWaitLine([]), null);
  assert.equal(lines.rowWaitLine(["“Fix login”"]), "◷ Waiting for “Fix login”");
  assert.equal(lines.rowWaitLine(["“Fix login”", "“Ship it”", "build"]), "◷ Waiting for “Fix login” (+2)");
  const waiting = { state: "finished", eventWait: { id: "w", from: 0, since: 0,
    patterns: [{ name: "agent.finished", filters: { agent: "a" } }, { name: "mac.wake", filters: {} }] } };
  assert.deepEqual(lines.eventWaitThings(waiting, title), ["“Fix login”", "mac.wake"]);
  const lease = { waitingNames: ["build"], waitingFull: ["Waiting for build, held by “Ship it”, 1st in line"] };
  const mark = lines.waitMark(waiting, { names: ["“Docs”"], lines: ["Docs — still working"] }, lease, title);
  assert.equal(mark.line, "◷ Waiting for “Docs” (+3)");
  assert.equal(mark.detail.split("\n")[0], "Docs — still working");
  assert.equal(mark.detail.split("\n")[2], "Waiting for build, held by “Ship it”, 1st in line");
  assert.equal(lines.waitMark({ state: "running" }, { names: [], lines: [] }, null, title), null);
  assert.equal(lines.waitMark({ state: "finished" }, { names: [], lines: ["Checks again at 14:30"] }, null, title).line,
    "◷ Checks again at 14:30");
});

test("who started it, and the worktree's help", () => {
  assert.equal(lines.startedByAgentLabel({ startedByAgent: "a" }, title), "Started by “Fix login”");
  assert.equal(lines.startedByAgentLabel({ startedByAgent: "gone" }, title), "Started by another agent");
  assert.equal(lines.startedByAgentLabel({}, title), null);
  const worktree = { name: "fix", root: "file:///w/Agents%20wt/fix/", branch: "agents/fix", project: "file:///w/Agents/", madeByApp: true };
  assert.equal(lines.worktreeHelp(worktree, false), "agents/fix — /w/Agents wt/fix/");
  assert.equal(lines.worktreeHelp({ ...worktree, branch: undefined }, true), "detached — /w/Agents wt/fix/, which is not there any more");
});

test("the chat's capsules: one a lease or wait, and an event wait's line and hint (#254)", () => {
  const now = new Date(2026, 9, 4, 14, 0);
  const snapshot = { at: wire(now), resources: [{ name: "screen", kind: "screen", displayName: "Screen", isGone: false,
    endingSoon: false, line: [{ agentID: "me", askedAt: 0, isCallOpen: true }],
    holds: [{ resource: "screen", displayName: "Screen", holder: "a", grantedAt: wire(now), expiresAt: wire(new Date(2026, 9, 4, 14, 12)), warned: false }] }] };
  assert.deepEqual(lines.leaseMark("me", snapshot, title).capsules, ["◷ Waiting for Screen · held by “Fix login” until 14:12 · 1st"]);
  const agent = { state: "finished", eventWait: { id: "w", from: 0, since: wire(new Date(2026, 9, 4, 23, 30)),
    deadline: wire(new Date(2026, 9, 5, 9, 0)), patterns: [{ name: "workflow.completed", filters: { workflow: "nightly" } }] } };
  assert.deepEqual(lines.eventWaitCapsule(agent, title), {
    line: "◷ Waiting for workflow.completed workflow nightly · since 23:30 · until 09:00",
    hint: "Sending will cancel the wait on workflow.completed workflow nightly.",
  });
  assert.equal(lines.eventWaitCapsule({ state: "running" }, title), null);
});
