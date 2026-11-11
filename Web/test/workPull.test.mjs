// A pull request's page in the Work look (#4408), as WorkPullLookTests has it on the window (#4406): the merge box's
// rows and buttons, the checks' order, the state line and the actions a forge offers (#4361).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/workPull.ts");

const pr = (item = {}, extra = {}) => ({
  item: { node: { kind: "pr", ref: "github:alexec/Agents#4402" }, title: "A change", state: "open", labels: [], assignees: [], updatedAt: 0, ...item },
  body: "", comments: [], head: "abc", mergeMethods: ["squash", "merge"], ...extra,
});
const check = (name, state) => ({ name, state });

test("an approved pull request with green checks merges now, in green", () => {
  const box = p.mergeBox(pr({ review: "approved", mergeable: "mergeable" }, { checks: [check("a", "passing"), check("b", "skipped")] }));
  assert.equal(box.border, "pass");
  assert.deepEqual(box.rows.map((r) => [r.kind, r.title, r.line]), [
    ["review", "Approved", undefined], ["checks", "All checks passed", "1 passed, 1 skipped"], ["conflicts", "No conflicts with the base branch", undefined],
  ]);
  assert.equal(box.merges, true);
  assert.equal(box.waits, false);
  assert.equal(box.checksOpen, false);
  assert.equal(p.mergeMain(["squash"], box.waits), "Squash and merge");
});

test("a failed check opens the list, turns the border red, and the merge waits for a rerun", () => {
  const box = p.mergeBox(pr({ review: "review_required" }, { checks: [check("a", "passing"), check("b", "failing")], reviewThreads: 2 }));
  assert.equal(box.border, "fail");
  assert.equal(box.checksOpen, true);
  assert.equal(box.reruns, true);
  assert.equal(box.waits, true);
  assert.equal(box.rows[0].line, "No one approved yet · 2 unresolved threads");
  assert.equal(box.rows[1].title, "1 check failed");
  assert.equal(p.mergeMain(["squash"], box.waits), "Merge when checks pass");
  assert.deepEqual(p.checksInOrder([check("a", "passing"), check("b", "running"), check("c", "failing")]).map((c) => c.name), ["c", "b", "a"]);
});

test("a draft, conflicts and auto-merge take Merge away", () => {
  const draft = p.mergeBox(pr({ draft: true }));
  assert.equal(draft.rows[0].title, "This is a draft");
  assert.equal(draft.merges, false);
  assert.equal(draft.approves, false);
  const conflicts = p.mergeBox(pr({ mergeable: "conflicting" }));
  assert.equal(conflicts.border, "fail");
  assert.equal(conflicts.resolve, true);
  assert.equal(conflicts.merges, false);
  const auto = p.mergeBox(pr({ autoMerge: true }));
  assert.equal(auto.rows.at(-1).line, "Squash and merge when the checks pass");
  assert.equal(auto.merges, false);
});

test("only the actions the forge offers show (#4361); a merged one has no box", () => {
  assert.equal(p.mergeBox(pr({ state: "merged" })), undefined);
  const none = p.mergeBox(pr({}, { actions: ["comment"], checks: [check("b", "failing")] }));
  assert.equal(none.merges, false);
  assert.equal(none.approves, false);
  assert.equal(none.reruns, false);
  assert.equal(p.offers(pr(), "diff"), true);
  assert.equal(p.offers(pr({}, { actions: ["merge"] }), "diff"), false);
});

test("the state line, Files changed, Branch, Reviewers and the Checks page's words", () => {
  const now = new Date("2026-11-10T12:00:00Z");
  const updated = new Date("2026-11-10T10:00:00Z");
  assert.deepEqual(p.pullStateWords({ author: "sam", state: "open", updated, comments: 4 }, now),
    { wide: "sam opened this pull request · updated 2 h ago · 4 comments", short: "sam · 2 h · 4 comments" });
  assert.equal(p.pullStateWords({ author: "sam", state: "merged", comments: 0 }, now).wide, "sam’s pull request was merged");
  assert.deepEqual(p.pullStateWords({ author: "sam", state: "merged", updated, closed: new Date("2026-11-10T11:50:00Z"), comments: 0 }, now),
    { wide: "sam’s pull request was merged 10 min ago", short: "sam · 10 min" });
  assert.equal(p.pullStateWords({ author: "sam", state: "open", updated, created: new Date("2026-11-07T12:00:00Z"), comments: 0 }, now).wide,
    "sam opened this pull request 3 days ago");
  assert.equal(p.filesChangedWords(6), "Files changed 6");
  assert.equal(p.filesChangedWords(undefined), "Files changed");
  assert.equal(p.branchWords(1), "1 file");
  assert.equal(p.reviewersWords(undefined), "No one");
  assert.equal(p.checksPageWords([check("a", "failing"), check("b", "passing"), check("c", "running")]), "1 failed, 1 passed, 1 running");
});
