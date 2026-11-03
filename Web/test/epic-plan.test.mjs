// The Plan section on an epic's page (#3268), as WorkPlanTests has it on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/epicPlan.ts");

const issue = (n) => ({ kind: "issue", ref: `github:alexec/Agents#${n}` });
const item = (n, state = "open", extra = {}) => ({ node: issue(n), title: `Issue ${n}`, state, labels: [], assignees: [], updatedAt: 0, comments: 0, ...extra });
const child = (n, step, { state = "open", blockedBy = [], outside } = {}) => ({
  item: item(n, state), blockedBy: blockedBy.map(issue), ...outside ? { blockedOutside: outside.map(issue) } : {}, step,
});
const cost = (usd) => ({ cost: usd ? { USD: usd } : {}, inputTokens: 0, outputTokens: 0, turns: 1, workingSeconds: 0, waitingSeconds: 0 });
const pr = (n, { outcome, failed, at = 0, sessions = [] } = {}) => ({
  node: { kind: "pr", ref: `github:alexec/Agents#${n}` }, banked: cost(0), lastAt: at, sessions: sessions.map((s) => `session:${s}`),
  ...outcome ? { outcome } : {}, ...failed ? { failedChecks: failed } : {},
});
const rollup = (n, usd = 0, parts = []) => ({ node: issue(n), own: cost(0), total: cost(usd), waste: cost(0), unlinked: cost(0),
  prsMerged: 0, prsClosed: 0, prsReverted: 0, failedChecks: 0, parts });

test("an issue with sub-issues or labelled epic has a plan", () => {
  assert.equal(p.hasPlan(item(1)), false);
  assert.equal(p.hasPlan(item(1, "open", { progress: { done: 0, total: 2 } })), true);
  assert.equal(p.hasPlan(item(1, "open", { level: "epic" })), true);
  assert.equal(p.hasPlan({ ...item(1, "open", { level: "epic" }), node: { kind: "pr", ref: "x" } }), false);
});

test("the PR of a child is an open one first, else the newest", () => {
  assert.equal(p.planPR(rollup(2, 0, [pr(10, { outcome: "merged", at: 50 }), pr(11), pr(12, { outcome: "closed", at: 100 })])).node.ref, "github:alexec/Agents#11");
  assert.equal(p.planPR(rollup(2, 0, [pr(10, { outcome: "merged", at: 50 }), pr(12, { outcome: "closed", at: 100 })])).node.ref, "github:alexec/Agents#12");
  assert.equal(p.planPR(rollup(2)), undefined);
});

test("the sessions of a child are its links, then its costs, each once", () => {
  const link = (s, n) => ({ from: { kind: "session", ref: `session:${s}` }, to: issue(n), rel: "works-on", source: "label", at: 0 });
  assert.deepEqual(p.planSessions(issue(2), [link("c", 2), link("d", 3)], rollup(2, 0, [pr(10, { sessions: ["a", "b"] }), pr(11, { sessions: ["a"] })])),
    ["C", "A", "B"]);
  assert.deepEqual(p.planSessions(issue(2), [], undefined), []);
});

test("the marks", () => {
  assert.equal(p.planMark(child(1, 1, { state: "closed" }), undefined, ["running"]), "✓");
  assert.equal(p.planMark(child(1, 1), undefined, ["waitingOnUser"]), "⚠");
  assert.equal(p.planMark(child(1, 1), pr(10, { failed: 1 }), []), "⚠");
  assert.equal(p.planMark(child(1, 1), pr(10), []), "◐");
  assert.equal(p.planMark(child(1, 1), undefined, ["running"]), "◐");
  assert.equal(p.planMark(child(1, 1, { outside: [99] }), undefined, ["finished"]), "⊘");
  assert.equal(p.planMark(child(1, 2), pr(10, { outcome: "closed" }), ["stopped"]), "○");
});

test("what works on a child", () => {
  assert.equal(p.planWorkWords(pr(10), ["running"]), "● lane running · PR #10 open");
  assert.equal(p.planWorkWords(pr(10, { failed: 2 }), ["waitingOnUser", "running"]), "● lane needs you · PR #10 open · 2 failed checks");
  assert.equal(p.planWorkWords(pr(10, { outcome: "merged" }), ["finished"]), "PR #10 merged");
  assert.equal(p.planWorkWords(undefined, []), undefined);
});

test("a child blocked outside the plan says by what", () => {
  assert.equal(p.blockedWords(child(1, 1, { outside: [17] })), "blocked by #17");
  assert.equal(p.blockedWords(child(1, 1, { state: "closed", outside: [17] })), undefined);
  assert.equal(p.blockedWords(child(1, 1)), undefined);
});

test("a step says the open children it waits for", () => {
  const plan = { item: item(1), children: [child(2, 1, { state: "closed" }), child(3, 1), child(4, 2, { blockedBy: [2, 3] }), child(5, 2, { blockedBy: [3] })],
    steps: [{ step: 1, nodes: [issue(2), issue(3)] }, { step: 2, nodes: [issue(4), issue(5)] }] };
  assert.equal(p.stepTitle(plan.steps[0], plan), "Step 1");
  assert.equal(p.stepTitle(plan.steps[1], plan), "Step 2 · waits for #3");
});

test("the header counts and adds up", () => {
  const plan = { item: item(1), children: [child(2, 1, { state: "closed" }), child(3, 1), child(4, 2)], steps: [] };
  assert.equal(p.progressWords(plan, 1, [rollup(2, 4.1), rollup(3, 1.2)]), "1/3 done · 1 running · $5.30");
  assert.equal(p.progressWords(plan, 0, []), "1/3 done");
});

test("the lead's words", () => {
  const lead = { session: "S", title: "Work pages lead", state: "running" };
  assert.equal(p.leadWords(lead, undefined), "Lead: “Work pages lead” (working)");
  assert.equal(p.leadWords(lead, "Renamed"), "Lead: “Renamed” (working)");
});

test("Start lead fills the lead skill's form", () => {
  const lead = p.leadStart({ prompt: "#3100: Work pages\n\nWork on this GitHub issue.", labels: ["#3100"], worktree: "3100 Work pages" },
    "https://github.com/alexec/Agents/issues/3100");
  assert.equal(lead.prompt, "#3100: Work pages\n\nLead this epic with the `lead` skill (`.agents/skills/lead/SKILL.md`): https://github.com/alexec/Agents/issues/3100");
  assert.deepEqual(lead.labels, ["#3100", "lead"]);
  assert.equal(lead.worktree, undefined);
});

test("Add child names an issue there or opens a new one (#3271)", () => {
  for (const there of ["#12", " alexec/Agents#12 ", "https://github.com/alexec/Agents/issues/12", "ENG-4"]) {
    assert.equal(p.namesIssue(there), true, there);
    assert.deepEqual(p.addChildRequest(issue(1), there, "task"), { node: issue(1), issue: there.trim() });
  }
  for (const title of ["Retire the rows", "Fix #12 in the list", "ENG-4 follow-up"]) assert.equal(p.namesIssue(title), false, title);
  assert.deepEqual(p.addChildRequest(issue(1), " Retire the rows ", "story"), { node: issue(1), title: "Retire the rows", level: "story" });
  assert.deepEqual(p.addChildRequest(issue(1), "Retire", ""), { node: issue(1), title: "Retire" });
});

test("Blocked by offers the other children with a tick on the blockers (#3271)", () => {
  const plan = { item: item(1), children: [child(2, 1), child(3, 1), child(4, 2, { blockedBy: [2] })], steps: [] };
  const choices = p.blockerChoices(plan.children[2], plan);
  assert.deepEqual(choices.map((c) => c.child.item.node), [issue(2), issue(3)]);
  assert.deepEqual(choices.map((c) => c.on), [true, false]);
  assert.deepEqual(p.blockedByRequest(plan.children[2], issue(3), true), { node: issue(4), add: [issue(3)] });
  assert.deepEqual(p.blockedByRequest(plan.children[2], issue(2), false), { node: issue(4), remove: [issue(2)] });
});
