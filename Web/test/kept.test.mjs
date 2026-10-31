// Start a machine by using it (#691 US3, layouts.md L6): a prompt or a start for a stopped
// workspace is kept by the control plane, shown as a queued bubble with what it waits for, and
// dropped with ×. The words are OfflineWords.swift's keptLine.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { Store, CallFailed, keptLine } = await load("test/kept-entry.ts");

const workspace = (more) => ({ provider: "p", providerName: "Docker", workspace: "w", workspaceName: "dev",
  workspaceState: "stopped", canStart: true, canStop: false, startWhenUsed: true, current: true, ...more });
const row = (state, ws) => ({ id: "box", name: "devbox", platform: "linux", version: "1", state, reach: "direct",
  ...(ws ? { workspace: ws } : {}) });
const kept = (more) => ({ id: "k1", host: "box", kind: "prompt", agentID: "a1", text: "run it again", at: 0, ...more });

function fakeLink(answer) {
  const asked = [];
  let notify = () => {};
  return { asked, notify: (method, params) => notify(method, params),
    onNotification: (f) => { notify = f; }, onState: () => {},
    call: async (method, params, host) => { asked.push({ method, params, host }); return answer(method, params); } };
}

test("the line under a kept bubble says what it waits for, or why it wasn't sent", () => {
  assert.equal(keptLine("devbox", kept()), "Waiting for devbox to start");
  assert.equal(keptLine("devbox", kept({ failed: "Couldn’t start devbox: droplet is locked" })),
    "Not sent: Couldn’t start devbox: droplet is locked");
});

test("a stopped workspace that starts when used takes a prompt; one that doesn't, or a plain offline host, doesn't", () => {
  const store = new Store(fakeLink(() => []));
  store.takeHosts([row("stopped", workspace())]);
  assert.equal(store.startsWhenUsed("box"), true);
  store.takeHosts([row("starting", workspace())]);
  assert.equal(store.startsWhenUsed("box"), true);
  store.takeHosts([row("stopped", workspace({ startWhenUsed: false }))]);
  assert.equal(store.startsWhenUsed("box"), false);
  store.takeHosts([row("offline")]);
  assert.equal(store.startsWhenUsed("box"), false);
});

test("a kept prompt counts as sent, and shows at once in its agent's chat", async () => {
  const store = new Store(fakeLink((method) => {
    if (method === "agents/prompt") throw new CallFailed(-32067, "devbox is starting. This is sent when it connects.", kept());
    return [];
  }));
  store.takeHosts([row("stopped", workspace())]);
  const said = [];
  store.say = (sentence) => said.push(sentence);
  assert.equal(await store.prompt("box", "a1", "run it again", []), true);
  assert.deepEqual(said, []);
  assert.deepEqual(store.keptFor("box", "a1").map((k) => k.text), ["run it again"]);
  assert.deepEqual(store.keptFor("box", "a2"), []);
});

test("a kept start answers what was kept, and is found by its folder", async () => {
  const start = kept({ id: "k2", kind: "start", agentID: undefined, folder: "file:///home/alex/app/", runtimeID: "claude" });
  const store = new Store(fakeLink((method) => {
    if (method === "agents/start") throw new CallFailed(-32067, "devbox is starting.", start);
    return [];
  }));
  const answer = await store.start("box", { runtimeID: "claude", cwd: "file:///home/alex/app/", prompt: "fix it" });
  assert.deepEqual(answer, { kept: start });
  assert.equal(store.keptStarts("box", "file:///home/alex/app/").length, 1);
});

test("the control plane's list replaces what was kept; × drops one there", async () => {
  const link = fakeLink(() => ({}));
  const store = new Store(link);
  link.notify("control/keptChanged", { kept: [kept(), kept({ id: "k3", text: "and this" })] });
  assert.equal(store.kept.value.length, 2);
  await store.dropKept(store.kept.value[0]);
  assert.deepEqual(store.kept.value.map((k) => k.id), ["k3"]);
  assert.deepEqual(link.asked.at(-1), { method: "hosts/dropKept", params: { host: "box", id: "k1" }, host: undefined });
  await store.retryKept(store.kept.value[0]);
  assert.deepEqual(link.asked.at(-1), { method: "hosts/retryKept", params: { host: "box", id: "k3" }, host: undefined });
  link.notify("control/keptDelivered", { host: "box", id: "k3", agentID: "a9" });
  assert.equal(store.keptDelivered.value.agentID, "a9");
});
