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
  assert.equal(p.planMark(child(1, 1, { state: "closed" }), undefined, ["running"]), "done");
  assert.equal(p.planMark(child(1, 1), undefined, ["waitingOnUser"]), "attention");
  assert.equal(p.planMark(child(1, 1), pr(10, { failed: 1 }), []), "attention");
  assert.equal(p.planMark(child(1, 1), pr(10), []), "working");
  assert.equal(p.planMark(child(1, 1), undefined, ["running"]), "working");
  assert.equal(p.planMark(child(1, 1, { outside: [99] }), undefined, ["finished"]), "blocked");
  assert.equal(p.planMark(child(1, 2), pr(10, { outcome: "closed" }), ["stopped"]), "waiting");
});

// #4418: a child's line 2 after its number, by its mark, as WorkPlan.lineWords.
test("what works on a child", () => {
  const plan = { item: item(1), children: [child(2, 1), child(3, 2, { blockedBy: [2] }), child(4, 1, { state: "closed" })], steps: [] };
  const [two, three, four] = plan.children;
  assert.equal(p.lineWords(two, "working", pr(10), ["running"], "Work look: epic page", plan), "Working · “Work look: epic page”");
  assert.equal(p.lineWords(two, "working", pr(10), [], undefined, plan), "Working · P#10 open");
  assert.equal(p.lineWords(two, "attention", pr(10, { failed: 2 }), ["waitingOnUser"], undefined, plan), "Needs you · its lane asks a question");
  assert.equal(p.lineWords(two, "attention", pr(10, { failed: 1 }), [], undefined, plan), "Needs you · 1 failed check");
  assert.equal(p.lineWords(three, "waiting", undefined, [], undefined, plan), "Waiting for #2");
  assert.equal(p.lineWords(two, "waiting", undefined, [], undefined, plan), undefined);
  // A WireDate is seconds from 2001-01-01; six hours before now.
  const now = Date.UTC(2026, 10, 10);
  const at = (now - Date.UTC(2001, 0, 1)) / 1000 - 6 * 3600;
  assert.equal(p.lineWords(four, "done", pr(11, { outcome: "merged", at }), [], undefined, plan, now), "merged P#11 · 6 h ago");
  assert.equal(p.lineWords(four, "done", undefined, [], undefined, plan), undefined);
  assert.equal(p.phoneWords("Working · “Work look”"), "Working");
  assert.equal(p.phoneWords("Blocked by #17, outside the plan"), "Blocked by #17");
  assert.equal(p.phoneWords(undefined), undefined);
});

test("a child blocked outside the plan says by what", () => {
  assert.equal(p.blockedWords(child(1, 1, { outside: [17] })), "Blocked by #17, outside the plan");
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
  assert.equal(p.progressWords(plan, 1, [rollup(2, 4.1), rollup(3, 1.2)]), "1 of 3 done · 1 running · $5.30 spent");
  assert.equal(p.progressWords(plan, 0, []), "1 of 3 done");
  const est = (n, usd) => ({ node: issue(n), cost: { USD: { p10: usd / 2, median: usd, p90: usd * 2 } } });
  assert.equal(p.progressWords(plan, 0, [], [est(2, 9), est(3, 1.5), est(4, 3.2)]), "1 of 3 done · about $4.70 to go");
  assert.deepEqual(p.planBar(plan, 1), { done: 1 / 3, running: 1 / 3 });
  assert.deepEqual(p.planBar({ ...plan, children: [] }, 0), { done: 0, running: 0 });
  assert.equal(p.estimateWords(est(3, 0.6)), "~$0.60");
  assert.equal(p.estimateWords({ node: issue(3), workingSeconds: { p10: 1, median: 7800, p90: 9 } }), "~2h 10m");
  assert.equal(p.estimateWords({ node: issue(3) }), undefined);
});

test("a step counts its children, and one all done starts folded", () => {
  const plan = { item: item(1), children: [child(2, 1, { state: "closed" }), child(3, 2, { state: "closed" }), child(4, 2)],
    steps: [{ step: 1, nodes: [issue(2)] }, { step: 2, nodes: [issue(3), issue(4)] }] };
  const costs = { [issue(2).ref]: rollup(2, 0.9) };
  assert.equal(p.stepWords(plan.steps[0], plan, costs), "1 of 1 done · $0.90");
  assert.equal(p.stepWords(plan.steps[1], plan, costs), "1 of 2 done");
  assert.equal(p.startsFolded(plan.steps[0], plan), true);
  assert.equal(p.startsFolded(plan.steps[1], plan), false);
  assert.equal(p.moreWords(19), "9 more");
  assert.equal(p.moreWords(10), undefined);
  assert.equal(p.priorityLabel(item(5, "open", { labels: [{ name: "bug" }, { name: "priority:high" }] }))?.name, "priority:high");
});

test("a standing epic's header has no end", () => {
  const standing = { labels: ["bug"], any: [], not: [], lanes: 1 };
  const plan = { item: item(1), children: [child(2, 1), child(3, 1)], steps: [], standing };
  assert.equal(p.standingWords(plan, 1, [rollup(2, 4.1)]), "2 open · 1 running · $4.10 spent");
  assert.equal(p.standingWords(plan, 0, []), "2 open");
  const full = { ...plan, children: Array.from({ length: 100 }, (_, i) => child(i + 2, 1)) };
  assert.equal(p.standingWords(full, 0, []), "100+ open");
  assert.equal(p.standingWords({ ...plan, children: [], standing: { ...standing, error: "no standing block" } }, 0, []), "");
});

test("a standing epic's query in words", () => {
  const q = (extra) => ({ labels: [], any: [], not: [], lanes: 1, ...extra });
  assert.equal(p.queryWords(q({ labels: ["bug"], milestone: "none" })), "Open issues labelled bug · no milestone · 1 lane at a time");
  assert.equal(p.queryWords(q({ any: ["polish", "competitor"], not: ["wontfix"], milestone: "1.0", lanes: 2 })),
    "Open issues labelled polish or competitor · not wontfix · milestone “1.0” · 2 lanes at a time");
  assert.equal(p.queryWords(q({ labels: ["ui"], any: ["bug", "polish"], milestone: "any" })),
    "Open issues labelled ui, and bug or polish · in a milestone · 1 lane at a time");
  assert.equal(p.queryWords(q({})), "Open issues · 1 lane at a time");
  assert.equal(p.queryWords(q({ labels: ["enhancement"], milestone: "none", parent: "none" })),
    "Open issues labelled enhancement · no milestone · no parent · 1 lane at a time");
  assert.equal(p.queryRestWords(q({ labels: ["enhancement"], milestone: "none", parent: "none" })), "· no milestone · no parent · 1 lane at a time");
  assert.equal(p.queryRestWords(q({ labels: ["bug"], milestone: "none" })), "· no milestone · 1 lane at a time");
  assert.equal(p.queryRestWords(q({ any: ["polish", "competitor"], not: ["wontfix"], lanes: 2 })), "· polish or competitor · not wontfix · 2 lanes at a time");
});

test("the lead's words", () => {
  assert.equal(p.leadWords("running"), "working");
  assert.equal(p.leadWords("waitingOnUser"), "needs you");
  assert.equal(p.leadWords("finished"), "waiting");
  assert.equal(p.leadWords("stopped"), "stopped");
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
