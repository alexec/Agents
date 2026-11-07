// Remove… on a machine in Settings ▸ Machines (#3381): it asks as the window's Machines pane asks,
// calls machines/remove, and the machine leaves the list; a refusal is said, and the machine stays.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { Store, CallFailed } = await load("test/kept-entry.ts");
const { addMachineWords } = await load("src/model/addMachine.ts");

const row = (id, name) => ({ id, name, platform: "linux", version: "1", state: "online", reach: "direct" });

function fakeLink(answer) {
  const asked = [];
  return { asked, onNotification: () => {}, onState: () => {},
    call: async (method, params, host) => { asked.push({ method, params, host }); return answer(method, params); } };
}

test("Remove… asks with the window's words", () => {
  assert.equal(addMachineWords.removeTitle("devbox"), "Remove devbox?");
  assert.equal(addMachineWords.removeNote,
    "It stops connecting, and every window and device stops seeing it. Its agents are left running where they are.");
});

test("a removed machine leaves the list", async () => {
  const link = fakeLink(() => ({}));
  const store = new Store(link);
  store.takeHosts([row("box", "devbox"), row("mac", "Mac")]);
  await store.removeHost("box");
  assert.deepEqual(link.asked.filter((a) => a.method === "machines/remove").map((a) => a.params), [{ host: "box" }]);
  assert.deepEqual(store.hosts.value.map((h) => h.id), ["mac"]);
});

test("a refused remove is said, and the machine stays", async () => {
  const store = new Store(fakeLink((method) => {
    if (method === "machines/remove") throw new CallFailed(-32003, "Only an admin can remove a machine.");
    return {};
  }));
  store.takeHosts([row("box", "devbox")]);
  const said = [];
  store.say = (sentence) => said.push(sentence);
  await store.removeHost("box");
  assert.equal(said.length, 1);
  assert.deepEqual(store.hosts.value.map((h) => h.id), ["box"]);
});
