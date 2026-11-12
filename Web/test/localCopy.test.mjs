// The page's local copy (#4790; spec 4777-fast, "the copy is a cache"): drawn at once, marked as
// from this device, the host's answer always wins, the caps hold, and nothing is written signed out.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { Store, LocalCopy, MemoryCopyStore, overCaps, startLocalCopy, machineRef, sessionRef, transcriptsKept, entriesKept, writeAfter } =
  await load("test/localCopy-entry.ts");

const host = (id, state = "online") => ({ id, name: id, state });
const agent = (id, at = 1) => ({ id, runtimeID: "claude", cwd: "file:///w/", state: "idle", lastActivityAt: at });
const entry = (id) => ({ id, at: 0, kind: { agentMessage: { text: id } } });
const settle = () => new Promise((r) => setTimeout(r, writeAfter + 50));

/** A link that answers nothing until `open`, then lists `hosts` and `agents`. */
function slowLink(hosts, agents) {
  const link = {
    open: false,
    onNotification: () => {},
    onState: () => {},
    call: async (method) => {
      if (!link.open) throw new Error("down");
      if (method === "machines/list") return hosts;
      if (method === "agents/list") return agents;
      if (method === "agents/turns") return { turns: [], firstTurn: 0, openStart: 0 };
      if (method === "agents/transcript") return { firstIndex: 0, total: 1, entries: [entry("host")] };
      if (method === "folders/list") return [];
      throw new Error("no");
    },
  };
  return link;
}

test("refs: a machine and a session", () => {
  assert.equal(machineRef("mac"), "agents:machine:#mac");
  assert.equal(sessionRef("7F3C"), "agents:session:#7F3C");
});

test("caps: transcripts past the newest 20 go, then the oldest while over the cap; machines stay", () => {
  const rows = [{ ref: "m", kind: "machine", at: 0, bytes: 10 }];
  for (let i = 0; i < transcriptsKept + 2; i++) rows.push({ ref: `t${i}`, kind: "transcript", at: i, bytes: 10 });
  assert.deepEqual(overCaps(rows, 1_000).sort(), ["t0", "t1"]);
  assert.deepEqual(overCaps(rows, 10 + 10 * 18).sort(), ["t0", "t1", "t2", "t3"]);
  assert.deepEqual(overCaps([{ ref: "m", kind: "machine", at: 0, bytes: 99 }], 10), []);
});

test("the copy is drawn at once, marked from this device, and the host's answer wins", async () => {
  const held = new MemoryCopyStore();
  const seed = new LocalCopy(held);
  seed.writing = true;
  await seed.put([{ kind: "machine", ref: machineRef("mac"), host: host("mac"), folders: [], agents: [agent("old")], at: 1 },
    { kind: "machine", ref: machineRef("gone"), host: host("gone"), agents: [agent("g")], at: 1 }]);

  const link = slowLink([host("mac")], [agent("new", 2)]);
  const store = new Store(link);
  const copy = new LocalCopy(held);
  const stop = startLocalCopy(store, copy);
  await new Promise((r) => setTimeout(r, 10));
  assert.deepEqual(store.hosts.value.map((h) => h.id).sort(), ["gone", "mac"]);
  assert.deepEqual(store.agents.value.mac.map((a) => a.id), ["old"]);
  assert.deepEqual([...store.fromDevice.value].sort(), ["gone", "mac"]);

  link.open = true;
  copy.writing = true;
  await store.load();
  assert.deepEqual(store.hosts.value.map((h) => h.id), ["mac"]);
  assert.deepEqual(store.agents.value.mac.map((a) => a.id), ["new"]);
  assert.equal(store.agents.value.gone, undefined);
  assert.equal(store.fromDevice.value.size, 0);

  await settle();
  assert.deepEqual(held.held.get(machineRef("mac")).agents.map((a) => a.id), ["new"]);
  assert.equal(held.held.has(machineRef("gone")), false);
  stop();
});

test("a chat draws its copy until its host's page comes, which replaces it, and its end is kept", async () => {
  const held = new MemoryCopyStore();
  const seed = new LocalCopy(held);
  seed.writing = true;
  await seed.put([{ kind: "transcript", ref: sessionRef("s"), host: "mac", session: "s", at: 1,
    turns: { turns: [], firstTurn: 0, openStart: 0 }, page: { firstIndex: 0, total: 1, entries: [entry("copy")] } }]);

  const link = slowLink([host("mac")], []);
  const store = new Store(link);
  const copy = new LocalCopy(held);
  const stop = startLocalCopy(store, copy);
  store.watch("mac", "s");
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(store.transcriptSource.value, "device");
  assert.deepEqual(store.entries.value.map((e) => e.id), ["copy"]);

  // Its host does not answer yet: the copy stays, with no failure said.
  await store.openSession("mac", "s");
  assert.deepEqual(store.entries.value.map((e) => e.id), ["copy"]);
  assert.equal(store.transcriptLoadFailure.value, null);

  link.open = true;
  copy.writing = true;
  await store.reloadTranscript();
  assert.equal(store.transcriptSource.value, "host");
  assert.deepEqual(store.entries.value.map((e) => e.id), ["host"]);
  await settle();
  assert.deepEqual(held.held.get(sessionRef("s")).page.entries.map((e) => e.id), ["host"]);
  stop();
});

test("a transcript's end is its last 200 entries, with where they start", async () => {
  const held = new MemoryCopyStore();
  const store = new Store(slowLink([], []));
  const copy = new LocalCopy(held);
  copy.writing = true;
  const stop = startLocalCopy(store, copy);
  store.watch("mac", "s");
  store.replaceTurns({ turns: [], firstTurn: 0, openStart: 0 });
  store.replaceTranscript({ firstIndex: 10, total: 260, entries: Array.from({ length: 250 }, (_, i) => entry(`e${i}`)) });
  await settle();
  const kept = held.held.get(sessionRef("s")).page;
  assert.equal(kept.entries.length, entriesKept);
  assert.equal(kept.entries[0].id, "e50");
  assert.equal(kept.firstIndex, 60);
  stop();
});

test("signed out, nothing is written", async () => {
  const held = new MemoryCopyStore();
  const copy = new LocalCopy(held);
  copy.writing = true;
  copy.forget();
  await copy.put([{ kind: "machine", ref: machineRef("mac"), host: host("mac"), agents: [], at: 1 }]);
  assert.equal(held.held.size, 0);
});
