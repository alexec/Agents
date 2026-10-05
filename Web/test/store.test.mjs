// Notification streams through the reducer, as AgentsModel has them (research R7).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";
import { digest } from "./digest.mjs";

const mod = await load("src/model/store.ts");
const { Work } = mod;
const host = "H";

for (const { name, input, expected } of cases("reducer/streams.json")) {
  test(`reducer: ${name}`, () => {
    const work = new Work();
    for (const step of input.steps) {
      if (step.notify) work.apply(step.notify.method, step.notify.params, host);
      else if (step.watch) work.watch(host, step.watch);
      else if (step.page) work.replaceTranscript(step.page);
    }
    const ids = (list) => list.map((x) => x.id);
    assert.deepEqual({
      agents: ids(work.agents.value[host] ?? []),
      permissions: ids(work.permissions.value[host] ?? []),
      elicitations: ids(work.elicitations.value[host] ?? []),
      entries: ids(work.entries.value),
      items: work.items.value.map(digest),
      firstEntryIndex: work.firstEntryIndex.value,
    }, expected);
  });
}

test("a host's notifications touch only that host's lists", () => {
  const work = new Work();
  const [{ input }] = cases("reducer/streams.json");
  const agent = input.steps[0].notify.params;
  work.apply("agent/changed", agent, "A");
  work.apply("agent/changed", { ...agent, title: "Other" }, "B");
  work.apply("agent/removed", { agentID: agent.id }, "A");
  assert.deepEqual(work.agents.value.A, []);
  assert.equal(work.agents.value.B[0].title, "Other");
});

test("a problem stays until its own OK, and the next waits its turn (#101)", () => {
  const work = new Work();
  work.say("first");
  work.say("second");
  work.say("first");
  assert.equal(work.problem.value, "first");
  work.dismissProblem();
  assert.equal(work.problem.value, "second");
  work.dismissProblem();
  assert.equal(work.problem.value, null);
});

test("a write the host could not keep is said in its words (#88)", () => {
  const work = new Work();
  const message = "Your Mac is out of disk space, so the transcript could not be saved. Free some space, then try again.";
  assert.equal(work.apply("storage/writeFailed", { cause: "diskFull", what: "the transcript", message }, host), true);
  assert.equal(work.problem.value, message);
});

test("a host down is noted from when the page first heard it, and forgotten once back (#83)", () => {
  const work = new Work();
  const mac = (state) => ({ id: "mac", name: "Mac", platform: "macOS", version: "1", state, reach: "local" });
  work.takeHosts([mac("offline")], 1000);
  work.takeHosts([mac("offline")], 5000);
  assert.deepEqual(work.downSince.value, { mac: 1000 });
  work.takeHosts([mac("online")], 9000);
  assert.deepEqual(work.downSince.value, {});
});

test("a lean list keeps the open session's menus; agent/changed replaces them (#107)", () => {
  const work = new Work();
  const [{ input }] = cases("reducer/streams.json");
  const whole = { ...input.steps[0].notify.params,
    advertisedOptions: [{ id: "model", name: "Model", type: "select" }],
    availableCommands: [{ name: "review", description: "Review" }] };
  work.addAgents([whole], host);
  work.replaceAgents([{ ...whole, title: "Renamed", advertisedOptions: [], availableCommands: [] }], host);
  const held = work.agents.value[host][0];
  assert.equal(held.title, "Renamed");
  assert.deepEqual(held.advertisedOptions.map((o) => o.id), ["model"]);
  assert.deepEqual(held.availableCommands.map((c) => c.name), ["review"]);
  work.apply("agent/changed", { ...whole, advertisedOptions: [{ id: "mode", name: "Mode", type: "select" }] }, host);
  assert.deepEqual(work.agents.value[host][0].advertisedOptions.map((o) => o.id), ["mode"]);
});

test("opening and typing warm a settled session once a while, however many keys (#183)", () => {
  const { Store } = mod;
  const calls = [];
  const link = {
    onNotification() {}, onState() {},
    call(method, params, host) { calls.push([method, params, host]); return Promise.resolve({}); },
  };
  const store = new Store(link);
  const [{ input }] = cases("reducer/streams.json");
  const agent = { ...input.steps[0].notify.params, state: "finished" };
  store.apply("agent/changed", agent, host);
  store.prewarm(host, agent.id, "opened");
  for (let i = 0; i < 20; i++) store.prewarm(host, agent.id, "typing");
  assert.deepEqual(calls.map(([m, p]) => [m, p.why]), [["agents/prewarm", "opened"], ["agents/prewarm", "typing"]]);
  // Working is not warmed: there is a runtime already.
  store.apply("agent/changed", { ...agent, id: "busy", state: "running" }, host);
  store.prewarm(host, "busy", "opened");
  assert.equal(calls.length, 2);
});

test("files/changed: a host's `many`, or a burst past 64 folders, settles as every pane reading again (#216)", async () => {
  const settle = () => new Promise((resolve) => setTimeout(resolve, 300));
  const work = new Work();
  work.apply("files/changed", { agentID: "A1", folders: ["/w/src"] }, host);
  await settle();
  assert.deepEqual({ ...work.filesChanged.value, at: 0 }, { host, agentID: "A1", folders: ["/w/src"], many: false, at: 0 });

  work.apply("files/changed", { agentID: "A1", folders: ["/w/a"], many: true }, host);
  work.apply("files/changed", { agentID: "A1", folders: ["/w/b"] }, host);
  await settle();
  assert.equal(work.filesChanged.value.many, true);
  assert.deepEqual(work.filesChanged.value.folders, []);

  for (let i = 0; i < 70; i++) work.apply("files/changed", { agentID: "A1", folders: [`/w/f${i}`] }, host);
  await settle();
  assert.equal(work.filesChanged.value.many, true);
  assert.deepEqual(work.filesChanged.value.folders, []);
});
