// Resume by revision (#4794; spec 4777-fast, "clients resume from their host"): on reconnect and at
// launch the page asks only for the sessions changed since its point and the entries written since
// its chat's end, and asks for all when its host cannot say.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { Store, LocalCopy, MemoryCopyStore, startLocalCopy, machineRef, sessionRef, writeAfter } = await load("test/localCopy-entry.ts");

const host = (id) => ({ id, name: id, state: "online", capabilities: ["client/1"] });
const agent = (id, at = 1, state = "idle") => ({ id, runtimeID: "claude", cwd: "file:///w/", state, lastActivityAt: at,
  advertisedOptions: [], availableCommands: [] });
const entry = (id) => ({ id, at: 0, kind: { agentMessage: { text: id } } });
const settle = () => new Promise((r) => setTimeout(r, writeAfter + 50));

/** A host whose catch-up answers `answer(asked)`, and whose transcript answers `page(asked)`. */
function hostLink({ answer, page = () => ({ firstIndex: 0, total: 0, entries: [] }) }) {
  const asked = [];
  const link = {
    asked,
    onNotification: () => {},
    onState: () => {},
    call: async (method, params) => {
      asked.push({ method, params });
      if (method === "machines/list") return [host("mac")];
      if (method === "client/catchUp") return answer(params);
      if (method === "agents/list") return [agent("listed")];
      if (method === "agents/turns") return { turns: [], firstTurn: 0, openStart: 0 };
      if (method === "agents/transcript") return page(params);
      if (method === "folders/list") return [];
      throw new Error("no");
    },
  };
  return link;
}

const all = (agents, revision = 5) => ({ agents, agentChanges: { epoch: "e", revision, removed: [], all: true } });

test("the first catch-up asks for all; the next asks what changed since, and lays it on", async () => {
  let next = all([agent("kept", 1), agent("renamed", 2), agent("removed", 3)]);
  const link = hostLink({ answer: () => next });
  const store = new Store(link);
  await store.load();
  const first = link.asked.find((a) => a.method === "client/catchUp");
  assert.equal(first.params.agents.changedSince, undefined);
  assert.deepEqual(store.listPoint("mac"), { epoch: "e", revision: 5 });

  next = { agents: [{ ...agent("renamed", 4), title: "new" }, agent("started", 5), agent("archived-elsewhere", 6, "archived")],
    agentChanges: { epoch: "e", revision: 9, removed: ["removed"], all: false } };
  link.asked.length = 0;
  await store.load();
  const second = link.asked.find((a) => a.method === "client/catchUp");
  assert.deepEqual(second.params.agents.changedSince, { epoch: "e", revision: 5 });
  assert.deepEqual(store.agents.value.mac.map((a) => a.id), ["started", "renamed", "kept"]);
  assert.equal(store.agents.value.mac.find((a) => a.id === "renamed").title, "new");
  assert.deepEqual(store.listPoint("mac"), { epoch: "e", revision: 9 });
  // No agents/list: the catch-up was the list.
  assert.equal(link.asked.some((a) => a.method === "agents/list"), false);
});

test("a host that cannot say what changed sends all, which replaces what is held", async () => {
  let next = all([agent("a"), agent("b")]);
  const store = new Store(hostLink({ answer: () => next }));
  await store.load();
  next = all([agent("c")], 1);
  await store.load();
  assert.deepEqual(store.agents.value.mac.map((a) => a.id), ["c"]);
  assert.deepEqual(store.listPoint("mac"), { epoch: "e", revision: 1 });
});

test("a host that does not answer the catch-up lists as before, and keeps no point", async () => {
  const store = new Store(hostLink({ answer: () => { throw new Error("no"); } }));
  await store.load();
  assert.deepEqual(store.agents.value.mac.map((a) => a.id), ["listed"]);
  assert.equal(store.listPoint("mac"), undefined);
});

test("the copy keeps the point, and a launch resumes from it", async () => {
  const held = new MemoryCopyStore();
  const first = new Store(hostLink({ answer: () => all([agent("a")], 7) }));
  const keep = new LocalCopy(held);
  keep.writing = true;
  const stop = startLocalCopy(first, keep);
  await first.load();
  await settle();
  stop();
  assert.deepEqual(held.held.get(machineRef("mac")).point, { epoch: "e", revision: 7 });

  const link = hostLink({ answer: () => ({ agents: [], agentChanges: { epoch: "e", revision: 7, removed: [], all: false } }) });
  const store = new Store(link);
  const stopAgain = startLocalCopy(store, new LocalCopy(held));
  await new Promise((r) => setTimeout(r, 10));
  await store.load();
  assert.deepEqual(link.asked.find((a) => a.method === "client/catchUp").params.agents.changedSince, { epoch: "e", revision: 7 });
  assert.deepEqual(store.agents.value.mac.map((a) => a.id), ["a"]);
  assert.equal(store.fromDevice.value.size, 0);
  stopAgain();
});

test("a chat resumes from its host's end; a gap opens it whole", async () => {
  let written = 2;
  const link = hostLink({
    answer: () => all([agent("s")]),
    page: (asked) => {
      const from = asked.from ?? 0;
      const start = Math.max(from, written - asked.limit);
      return { firstIndex: start, total: written, entries: Array.from({ length: written - start }, (_, i) => entry(`e${start + i}`)) };
    },
  });
  const store = new Store(link);
  await store.load();
  await store.openSession("mac", "s");
  assert.deepEqual(store.entries.value.map((e) => e.id), ["e0", "e1"]);
  assert.equal(store.chatEnd(), 2);

  written = 3;
  link.asked.length = 0;
  await store.reloadTranscript();
  const pages = link.asked.filter((a) => a.method === "agents/transcript");
  assert.equal(pages.length, 1);
  assert.equal(pages[0].params.from, 2);
  assert.equal(link.asked.some((a) => a.method === "agents/turns"), false);
  assert.deepEqual(store.entries.value.map((e) => e.id), ["e0", "e1", "e2"]);

  // More written than one page: a gap, so the opening is asked again whole.
  written = 900;
  link.asked.length = 0;
  await store.reloadTranscript();
  assert.equal(link.asked.some((a) => a.method === "agents/turns"), true);
  assert.equal(store.entries.value[0].id, "e700");
});

test("a chat opened at launch resumes from this device's copy", async () => {
  const held = new MemoryCopyStore();
  const seed = new LocalCopy(held);
  seed.writing = true;
  await seed.put([{ kind: "transcript", ref: sessionRef("s"), host: "mac", session: "s", at: 1,
    turns: { turns: [], firstTurn: 0, openStart: 0 }, page: { firstIndex: 0, total: 1, entries: [entry("e0")] } }]);
  const link = hostLink({ answer: () => all([agent("s")]), page: (asked) => ({ firstIndex: 1, total: 2, entries: [entry("e1")], asked }) });
  const store = new Store(link);
  const stop = startLocalCopy(store, new LocalCopy(held));
  await store.openSession("mac", "s");
  assert.equal(store.transcriptSource.value, "host");
  assert.deepEqual(store.entries.value.map((e) => e.id), ["e0", "e1"]);
  assert.equal(link.asked.find((a) => a.method === "agents/transcript").params.from, 1);
  stop();
});
