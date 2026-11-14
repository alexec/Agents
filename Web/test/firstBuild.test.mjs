// The question page (#5051): the ideas, held to the fixture the Mac window reads too, and who
// sees the page, as GetStarted.card in Swift; the plan page's starters, tasks and states (#5054),
// held to the fixtures FirstBuild in AgentsKitCore writes (#5053).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const m = await load("src/model/firstBuild.ts");

const newcomer = { loaded: true, hasMachine: true, hasFolder: false, hasAgent: false, ranAgent: false };

function storage() {
  const items = new Map();
  return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v), removeItem: (k) => items.delete(k) };
}

test("the ideas are the fixture's, in its order", () => {
  assert.deepEqual(m.firstBuildIdeas.map((i) => ({ ...i })), cases("first-build/ideas.json")[0].expected);
});

test("the ideas go round", () => {
  assert.equal(m.nextIdea(0), 1);
  assert.equal(m.nextIdea(m.firstBuildIdeas.length - 1), 0);
});

test("a newcomer sees the page once every machine has answered", () => {
  assert.equal(m.weigh(null, { ...newcomer, loaded: false }, false), null);
  assert.equal(m.weigh(null, newcomer, false), "showing");
});

test("no machine yet: not until one is there", () => {
  assert.equal(m.weigh(null, { ...newcomer, hasMachine: false }, false), null);
});

test("a person set up already never sees it", () => {
  for (const set of [{ hasFolder: true }, { hasAgent: true }, { ranAgent: true }]) {
    assert.equal(m.weigh(null, { ...newcomer, ...set }, false), "gone");
  }
  assert.equal(m.weigh("gone", newcomer, false), "gone");
});

test("showing stays until set up some other way, and for the plan page once sent", () => {
  assert.equal(m.weigh("showing", newcomer, false), "showing");
  assert.equal(m.weigh("showing", { ...newcomer, hasFolder: true }, false), "gone");
  assert.equal(m.weigh("showing", { ...newcomer, hasAgent: true }, true), "showing");
});

test("the browser keeps whether it shows and the idea it sent", () => {
  const kept = storage();
  const first = new m.FirstBuildStore(kept);
  first.take(newcomer);
  first.send("  A page for my band  ");
  first.send("   ");
  const again = new m.FirstBuildStore(kept);
  assert.equal(again.kept.value, "showing");
  assert.equal(again.sent.value, "A page for my band");
});

test("the starter the words pick is the fixture's", () => {
  for (const c of cases("first-build/starters.json")) assert.equal(m.firstBuildStarter(c.input), c.expected, c.name);
});

test("each starter's tasks are the fixture's, in its order", () => {
  for (const c of cases("first-build/tasks.json")) assert.deepEqual(m.firstBuildTasks(c.input), c.expected, c.name);
});

const plan = (rows) => rows.map(([content, status]) => ({ content, priority: "medium", status }));

test("the agent's tasks are to do until its plan comes", () => {
  const states = m.taskStates("web-service", { runtimeReady: true, githubConnected: false, waitsForPerson: false });
  assert.deepEqual(states, ["done", "to-do", "to-do", "to-do", "to-do", "to-do", "to-do"]);
});

test("the plan ticks the agent's tasks by their words", () => {
  const facts = { runtimeReady: true, githubConnected: true, waitsForPerson: false, plan: plan([
    ["Set up the agent runtime", "completed"], ["Connect GitHub", "completed"],
    ["Make the repository from agentloops-dev/web-service-starter", "completed"],
    ["Set up Google Cloud (Cloud Run).", "in_progress"], ["Set up Sentry", "pending"],
  ]) };
  assert.deepEqual(m.taskStates("web-service", facts), ["done", "done", "done", "doing", "to-do", "to-do", "to-do"]);
  assert.deepEqual(m.taskStates("web-service", { ...facts, waitsForPerson: true }),
    ["done", "done", "done", "waits-for-you", "to-do", "to-do", "to-do"]);
  const curly = { ...facts, plan: plan([["Put the App Store Connect key in the repository\u2019s CI", "completed"]]) };
  assert.equal(m.taskStates("iphone-app", curly)[4], "done");
});

test("the agent starts once the page's two tasks are done", () => {
  assert.equal(m.canStart({ runtimeReady: true, githubConnected: false, waitsForPerson: false }), false);
  assert.equal(m.canStart({ runtimeReady: false, githubConnected: true, waitsForPerson: false }), false);
  assert.equal(m.canStart({ runtimeReady: true, githubConnected: true, waitsForPerson: false }), true);
});

test("the first-build session is labelled first-build and not archived", () => {
  const label = { value: "first-build", owner: "agent", addedAt: 0 };
  assert.equal(m.isFirstBuild({ state: "running", labels: [label] }), true);
  assert.equal(m.isFirstBuild({ state: "archived", labels: [label] }), false);
  assert.equal(m.isFirstBuild({ state: "idle", archivedAt: 1, labels: [label] }), false);
  assert.equal(m.isFirstBuild({ state: "running", labels: [] }), false);
  assert.equal(m.isFirstBuild({ state: "running", archivedAt: null, labels: [label] }), true);
  assert.equal(m.isArchived({ state: "running" }), false);
  assert.equal(m.isArchived({ state: "finished", archivedAt: 1 }), true);
});

test("Submit keeps the starter the words pick; Back gives the words back; Open Agents leaves", () => {
  const kept = storage();
  const page = new m.FirstBuildStore(kept);
  page.take(newcomer);
  page.send("A web page for my band");
  assert.equal(page.starter.value, "web-service");
  page.started({ host: "mac", id: "a1" });
  const again = new m.FirstBuildStore(kept);
  assert.equal(again.starter.value, "web-service");
  assert.deepEqual(again.session.value, { host: "mac", id: "a1" });
  again.leave();
  const after = new m.FirstBuildStore(kept);
  assert.equal(after.kept.value, "gone");
  assert.equal(after.sent.value, null);
  assert.equal(after.session.value, null);

  const unfit = new m.FirstBuildStore(storage());
  unfit.take(newcomer);
  unfit.send("a game about frogs");
  assert.equal(unfit.starter.value, null);
  unfit.back();
  assert.equal(unfit.sent.value, null);
  assert.equal(unfit.draft.value, "a game about frogs");
  assert.equal(unfit.kept.value, "showing");
});

test("New App… opens the question page for a person who is set up, and Cancel closes it (#5132)", () => {
  const setUp = { ...newcomer, hasFolder: true, ranAgent: true };
  const kept = storage();
  const page = new m.FirstBuildStore(kept);
  page.take(setUp);
  assert.equal(page.kept.value, "gone");
  page.newApp();
  page.take(setUp);
  assert.equal(page.kept.value, "showing");
  assert.equal(page.another.value, true);
  assert.equal(page.sent.value, null);
  page.send("A website for my book club's reading list");
  page.started({ host: "mac", id: "a2" });
  const again = new m.FirstBuildStore(kept);
  again.take(setUp);
  assert.equal(again.kept.value, "showing");
  assert.equal(again.another.value, true);
  again.leave();
  assert.equal(again.another.value, false);
  const after = new m.FirstBuildStore(kept);
  after.take(setUp);
  assert.equal(after.kept.value, "gone");
  assert.equal(after.another.value, false);
});
