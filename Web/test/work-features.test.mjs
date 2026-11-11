// Work ▸ Features (#3269), as WorkFeaturesTests has it on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const f = await load("src/model/workFeatures.ts");
const nav = await load("src/model/nav.ts");

const node = (n) => ({ kind: "issue", ref: `github:alexec/Agents#${n}` });
const issue = (n, { level, parent, progress, state = "open", at = 0 } = {}) => ({
  node: node(n), title: `Issue ${n}`, state, labels: [], assignees: [], updatedAt: at, comments: 0,
  ...level ? { level } : {}, ...parent ? { parent: node(parent) } : {}, ...progress ? { progress: { done: progress[0], total: progress[1] } } : {},
});
const agent = (id, labels, state, at = 0) => ({ id, state, createdAt: at, labels: labels.map((value) => ({ value, owner: "agent", addedAt: 0 })) });

test("a feature says its name and counts", () => {
  assert.equal(f.featureTitle("work"), "Work");
  assert.equal(f.featureTitle(""), "");
  assert.equal(f.featureCountWords({ name: "work", epics: 3, open: 2 }), "3 epics · 2 open");
  assert.equal(f.featureCountWords({ name: "hosted", epics: 1, open: 0 }), "1 epic · 0 open");
  assert.equal(f.featureCountWords({ name: "work", epics: 1, open: 0, issues: 0 }), "1 epic · 0 open");
  assert.equal(f.featureCountWords({ name: "work", epics: 1, open: 0, issues: 1 }), "1 epic · 0 open · 1 open issue");
  assert.equal(f.featureCountWords({ name: "work", epics: 2, open: 1, issues: 4 }), "2 epics · 1 open · 4 open issues");
});

test("a feature with no open work is finished", () => {
  const groups = f.featureGroups([
    { name: "browser", epics: 1, open: 0, issues: 0 },
    { name: "lineage", epics: 2, open: 1, issues: 0 },
    { name: "old", epics: 1, open: 0 },
    { name: "work", epics: 3, open: 0, issues: 2 },
  ]);
  assert.deepEqual(groups.map((g) => g.group), ["idle", "finished"]);
  assert.deepEqual(groups[0].features.map((x) => x.name), ["lineage", "old", "work"]);
  assert.deepEqual(groups[1].features.map((x) => x.name), ["browser"]);
  assert.equal(f.groupWords.finished, "Finished");
});

// #4115: each feature in the first group it matches, from the sessions labelled with its work.
test("features are in Needs you, In flight, Idle and Finished", () => {
  const feature = (name, refs, { waiting = [], at = 0 } = {}) => ({
    name, epics: 1, open: 1, issues: 1, refs: refs.map((n) => node(n).ref), waiting: waiting.map((n) => node(n).ref), updatedAt: at,
  });
  const features = [
    feature("asked", [10]), feature("approval", [20]), feature("todo", [30], { waiting: [30] }),
    feature("busy", [40, 41]), feature("new", [50], { at: 100 }), feature("old", [60], { at: -100 }),
    feature("stale", [70]), { name: "done", epics: 1, open: 0, issues: 0 },
  ];
  const agents = [
    agent("a", ["#10"], "waitingOnUser"), agent("b", ["#20", "P#200"], "stopped"),
    agent("c", ["#40"], "running"), agent("d", ["#41", "lead"], "finished"), agent("e", ["#40"], "archived"),
    agent("f", ["#70"], "archived"), agent("g", ["#5"], "running"),
  ];
  const groups = f.featureGroups(features, agents, [node(200).ref]);
  assert.deepEqual(groups.map((g) => g.group), ["needsYou", "inFlight", "idle", "finished"]);
  assert.deepEqual(groups.map((g) => g.features.map((x) => x.name)),
    [["asked", "approval", "todo"], ["busy"], ["old", "stale", "new"], ["done"]]);
  assert.equal(f.featureSessions(features[3], agents).length, 2);
  assert.equal(f.sessionWords(1), "1 session");
  assert.equal(f.sessionWords(3), "3 sessions");
  // Without the approval, a stopped session that waits for it is still in flight.
  assert.deepEqual(f.featureGroups([features[1]], agents).map((g) => g.group), ["inFlight"]);
  assert.deepEqual(f.featureGroupOrder.map((g) => f.groupWords[g]), ["Needs you", "In flight", "Idle", "Finished"]);
});

test("several machines' features add up by name", () => {
  const merged = f.mergeFeatures([
    [{ name: "work", color: "#1d76db", epics: 2, open: 1 }, { name: "lineage", epics: 4, open: 0 }],
    [{ name: "Work", epics: 1, open: 1 }],
  ]);
  assert.deepEqual(merged.map((x) => x.name), ["lineage", "work"]);
  assert.deepEqual([merged[1].epics, merged[1].open, merged[1].color], [3, 2, "#1d76db"]);
  const counted = f.mergeFeatures([[{ name: "work", epics: 1, open: 0, issues: 1 }], [{ name: "work", epics: 1, open: 0, issues: 2 }],
    [{ name: "docs", epics: 1, open: 0, issues: 0 }], [{ name: "docs", epics: 1, open: 0 }]]);
  assert.deepEqual(counted.map((x) => x.issues), [undefined, 3]);
  const refs = f.mergeFeatures([[{ name: "work", epics: 1, open: 1, refs: ["a#1", "a#2"], waiting: ["a#2"], updatedAt: 0 }],
    [{ name: "work", epics: 1, open: 1, refs: ["a#2", "b#3"], updatedAt: 9 }]]);
  assert.deepEqual([refs[0].refs, refs[0].waiting, refs[0].updatedAt], [["a#1", "a#2", "b#3"], ["a#2"], 9]);
});

test("an opened feature shows its epics and its loose issues", () => {
  const shown = f.openedFeature([
    issue(3265, { level: "epic", progress: [1, 6], at: 10 }),
    issue(3269, { level: "story", parent: 3265, at: 20 }),
    issue(3100, { progress: [5, 7], at: 30 }),
    issue(3131, { at: 5 }),
    issue(3000, { level: "epic", state: "closed" }),
    issue(3265, { level: "epic", progress: [1, 6], at: 10 }),
  ]);
  assert.deepEqual(shown.epics.map((i) => i.node.ref), ["github:alexec/Agents#3100", "github:alexec/Agents#3265"]);
  assert.deepEqual(shown.loose.map((i) => i.node.ref), ["github:alexec/Agents#3131"]);
  assert.equal(f.epicProgressWords(shown.epics[1]), "1 of 6");
  assert.equal(f.epicProgressWords(issue(1, { level: "epic" })), "0 of 0");
});

test("the lead is the live session labelled lead and the epic", () => {
  const ended = agent("ended", ["#3265", "lead"], "stopped", 100);
  const live = agent("live", ["#3265", "lead"], "running");
  const lane = agent("lane", ["#3265"], "running", 200);
  const other = agent("other", ["#3100", "lead"], "running", 300);
  const archived = agent("archived", ["#3265", "lead"], "archived", 400);
  assert.equal(f.epicLead(node(3265), [ended, live, lane, other, archived])?.id, "live");
  assert.equal(f.epicLead(node(3265), [ended, lane])?.id, "ended");
  assert.equal(f.epicLead(node(3265), [lane, other]), undefined);
  assert.equal(f.epicLead({ kind: "issue", ref: "linear:ENG-5" }, [agent("l", ["ENG-5", "lead"], "finished")])?.id, "l");
});

test("the lead says its state", () => {
  assert.equal(f.leadRowWords(undefined), "—");
  assert.equal(f.leadRowWords("running"), "● lead working");
  assert.equal(f.leadRowWords("waitingOnUser"), "● lead needs you");
  assert.equal(f.leadRowWords("stopped"), "lead stopped");
});

// #4418: a feature's bar and what waits for the person on it.
test("a feature's bar is its epics closed of all", () => {
  assert.equal(f.epicsDone({ name: "work", epics: 4, open: 1 }), 0.75);
  assert.equal(f.epicsDone({ name: "work", epics: 0, open: 0 }), undefined);
  assert.equal(f.epicsDoneWords({ name: "work", epics: 2, open: 1 }), "1 of 2 epics done");
  assert.equal(f.epicsDoneWords({ name: "work", epics: 1, open: 1 }), "0 of 1 epic done");
});

test("a Needs you feature says what waits", () => {
  const feature = { name: "work", epics: 1, open: 1, waiting: [node(4290).ref] };
  const approval = [agent("a", ["#4300", "P#4405"], "stopped")];
  assert.equal(f.needsWords(feature, approval, [{ kind: "pr", ref: "github:alexec/Agents#4405" }.ref]), "P#4405 waits for your approval");
  assert.equal(f.needsWords(feature, [], []), "#4290 waits for you");
  const asks = { ...agent("b", ["#4300"], "waitingOnUser"), title: "Work look: epic page" };
  assert.equal(f.needsWords({ ...feature, waiting: [] }, [asks], []), "“Work look: epic page” needs you");
  assert.equal(f.needsWords({ ...feature, waiting: [] }, [], []), undefined);
});

test("Work lists Features after Pull requests", () => {
  assert.deepEqual(nav.navPages.work.map((p) => p.title), ["Issues", "Pull requests", "Features", "Releases", "Timeline"]);
  assert.deepEqual(nav.navPages.work[2].draw, { kind: "features" });
  // Work has no Milestones list now (#3878): an old #/work/milestone opens the Work default.
  assert.equal(nav.openPage("work", "milestone", true).id, "issue");
});

// #4589: Features as a delivery view (features-delivery.md).
const plan = (children, steps) => ({ item: issue(10, { level: "epic" }), children, steps: steps.map((s) => ({ step: s, nodes: [] })) });
const child = (n, step, { state = "open", outside = [] } = {}) => ({
  item: issue(n, { state }), blockedBy: [], step, ...outside.length ? { blockedOutside: outside.map(node) } : {},
});

test("features in Needs you and In flight start open; Idle only when nothing is in flight", () => {
  assert.equal(f.startsOpen("needsYou", ["needsYou", "idle"]), true);
  assert.equal(f.startsOpen("inFlight", ["inFlight"]), true);
  assert.equal(f.startsOpen("idle", ["inFlight", "idle"]), false);
  assert.equal(f.startsOpen("idle", ["idle", "finished"]), true);
  assert.equal(f.startsOpen("finished", ["finished"]), false);
});

test("a child in flight says what works on it", () => {
  const approvals = new Set(["P#45"]);
  const withLabel = (n, name) => ({ ...issue(n), labels: [{ name }] });
  assert.deepEqual(f.inFlight(issue(13), [agent("a", ["#13", "P#45"], "finished")], approvals),
    { item: issue(13), mark: "attention", words: "P#45 waits for your approval", pr: "P#45" });
  assert.equal(f.inFlight(issue(33), [agent("a", ["#33"], "waitingOnUser")], approvals)?.words, "Needs you · the lane asks a question");
  assert.equal(f.inFlight(withLabel(7, "alex-todo"), [], approvals)?.words, "waits for you (alex-todo)");
  const lane = { ...agent("b", ["#12", "P#44"], "running"), title: "Gift card part-payment" };
  assert.deepEqual(f.inFlight(issue(12), [lane], approvals), { item: issue(12), mark: "working", words: "Working · “Gift card part-payment”", pr: "P#44" });
  // A lead labels its epic; an archived lane and a closed child are not in flight.
  assert.equal(f.inFlight(issue(10), [agent("l", ["#10", "lead"], "running")], approvals), undefined);
  assert.equal(f.inFlight(issue(12), [agent("x", ["#12"], "archived")], approvals), undefined);
  assert.equal(f.inFlight(issue(12, { state: "closed" }), [lane], approvals), undefined);
});

test("the children in flight: Needs you first, then the most recently updated", () => {
  const line = (n, mark, at) => ({ item: issue(n, { at }), mark, words: "", pr: undefined });
  assert.deepEqual(f.flightOrder([line(1, "working", 5), line(2, "attention", 1), line(3, "working", 9)]).map((l) => l.item.node.ref),
    [node(2).ref, node(3).ref, node(1).ref]);
});

test("an epic says where it is in its plan", () => {
  assert.equal(f.whereWords(plan([child(1, 1, { state: "closed" }), child(2, 2), child(3, 3)], [1, 2, 3])), "step 2 of 3");
  assert.equal(f.whereWords(plan([child(4, 1, { outside: [10] }), child(5, 2)], [1, 2])), "step 1 of 2 · waits for #10");
  assert.equal(f.whereWords(plan([child(1, 1, { state: "closed" })], [1])), undefined);
});

test("the bars count children: done, in flight and not started", () => {
  const p = plan([child(1, 1, { state: "closed" }), child(2, 1), child(3, 2), child(4, 2)], [1, 2]);
  const d = f.planDelivery(p, 1);
  assert.deepEqual(d, { done: 1, flight: 1, total: 4 });
  assert.deepEqual(f.deliveryShares(d), { done: 0.25, flight: 0.25 });
  assert.deepEqual(f.progressDelivery(issue(9, { progress: [4, 9] })), { done: 4, flight: 0, total: 9 });
  const all = f.addDelivery([d, { done: 0, flight: 1, total: 2 }]);
  assert.equal(f.deliveryWords(all), "1 of 6 done");
  assert.deepEqual(f.deliveryShares({ done: 0, flight: 0, total: 0 }), { done: 0, flight: 0 });
});

test("the rest under an epic, in words, wide and on a phone", () => {
  const d = { done: 4, flight: 3, total: 9 };
  assert.equal(f.restWords(d, 3), "2 more not started · 4 done");
  assert.equal(f.restWords(d, 2), "1 more in flight · 2 more not started · 4 done");
  assert.equal(f.restWords({ done: 0, flight: 0, total: 3 }, 0), "3 not started");
  assert.equal(f.restWords({ done: 0, flight: 1, total: 1 }, 1), undefined);
});

test("a feature's line 2 says its epics and what is in flight", () => {
  assert.equal(f.featureFlightWords({ name: "checkout", epics: 3, open: 2 }, 4), "2 epics · 4 in flight");
  assert.equal(f.featureFlightWords({ name: "accounts", epics: 1, open: 1 }, 0), "1 epic · nothing in flight");
  const feature = { name: "checkout", epics: 1, open: 1, refs: [node(10).ref, node(12).ref, node(13).ref], waiting: [node(13).ref] };
  assert.equal(f.featureFlight(feature, [agent("a", ["#12"], "running"), agent("l", ["#10", "lead"], "running")]), 2);
});
