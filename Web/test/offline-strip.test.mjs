// The strip over a chat whose host is down (#83), and a workspace host's (#691, layouts.md L1):
// the words OfflineWords.swift says, Start or a timer at its end, and Start as hosts/start.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { offlineStrip, elapsed, footLine } = await load("src/views/OfflineStrip.tsx");
const { Store } = await load("src/model/store.ts");

const workspace = (more) => ({ provider: "p", providerName: "Coder", workspace: "w", workspaceName: "dev",
  workspaceState: "stopped", canStart: true, canStop: false, startWhenUsed: true, current: true, ...more });
const row = (state, ws) => ({ id: "box", name: "devbox", platform: "linux", version: "1", state, reach: "direct",
  ...(ws ? { workspace: ws } : {}) });

test("a stopped workspace says so and offers Start", () => {
  assert.deepEqual(offlineStrip("box", row("stopped", workspace()), "9:41"),
    { line: "devbox is stopped. Agents there are paused until it starts.", starting: false, since: null, start: true });
  assert.equal(offlineStrip("box", row("stopped", workspace({ stoppedBy: "Stopped by Agents after 30 minutes idle" })), null).line,
    "devbox was stopped by Agents after 30 minutes idle.");
  assert.equal(offlineStrip("box", row("stopped", workspace({ canStart: false })), null).start, false);
});

test("a starting one waits with a spinner and a timer, and no Start", () => {
  const since = Date.parse("2026-10-12T10:00:00Z") / 1000 - 978_307_200; // seconds since 2001, as Swift writes a Date
  const strip = offlineStrip("box", row("starting", workspace({ phase: "connecting", since })), null);
  assert.deepEqual(strip, { line: "Waiting for devbox to connect…", starting: true, since: Date.parse("2026-10-12T10:00:00Z"), start: false });
  assert.equal(offlineStrip("box", row("starting", workspace({ phase: "provider" })), null).line, "Starting devbox…");
  assert.equal(offlineStrip("box", row("starting", workspace({ phase: "sshStart" })), null).line,
    "devbox started but agentsd didn’t connect; starting it over ssh…");
  assert.equal(elapsed(0, 24_900), "0:24");
  assert.equal(elapsed(0, 125_000), "2:05");
  assert.equal(elapsed(10_000, 0), "0:00");
});

test("a failed start says the provider's words, with Start again", () => {
  assert.deepEqual(offlineStrip("box", row("failed", workspace({ problem: "Coder refused: quota exceeded." })), null),
    { line: "Coder refused: quota exceeded.", starting: false, since: null, start: true });
});

test("a host on no workspace keeps today's words and no button", () => {
  assert.deepEqual(offlineStrip("box", row("offline"), "9:41"),
    { line: "devbox is offline since 9:41. Agents there keep working; nothing can be sent until it’s back.",
      starting: false, since: null, start: false });
  assert.equal(offlineStrip("mac", undefined, null).line,
    "This Mac’s host hasn’t answered. Nothing here can change until it’s back. Trying again…");
  assert.equal(offlineStrip("box", row("offline", workspace({ workspaceState: "running" })), null).line,
    "devbox is offline. Agents there keep working; nothing can be sent until it’s back.",
    "a running workspace whose agentsd went is the ordinary line");
});

function fakeLink(answer) {
  const asked = [];
  let notify = () => {};
  return { asked, notify: (method, params) => notify(method, params),
    onNotification: (f) => { notify = f; }, onState: () => {},
    call: async (method, params, host) => { asked.push({ method, params, host }); return answer(method, params); } };
}

test("Start asks the control plane, waits while it is out, and takes the row it answers", async () => {
  let answer;
  const link = fakeLink((method) => method === "hosts/start" ? new Promise((r) => { answer = r; }) : []);
  const store = new Store(link);
  store.takeHosts([row("stopped", workspace())]);
  const started = store.startHost("box");
  assert.deepEqual(store.hostsBeingStarted.value, ["box"]);
  assert.deepEqual(link.asked.at(-1), { method: "hosts/start", params: { host: "box" }, host: undefined });
  answer(row("starting", workspace({ phase: "provider" })));
  await started;
  assert.deepEqual(store.hostsBeingStarted.value, []);
  assert.equal(store.hosts.value[0].state, "starting");
  assert.equal(store.hosts.value[0].workspace.phase, "provider");
});

test("a refused start is said in the problem line", async () => {
  const store = new Store(fakeLink(() => { throw new Error("Coder is not reachable."); }));
  store.takeHosts([row("stopped", workspace())]);
  const said = [];
  store.say = (sentence) => said.push(sentence);
  await store.startHost("box");
  assert.equal(said.length, 1);
  assert.deepEqual(store.hostsBeingStarted.value, []);
});

test("control/hostChanged's state and workspace are kept at once, so each step of a start shows", () => {
  const link = fakeLink(() => []);
  const store = new Store(link);
  store.takeHosts([row("stopped", workspace())]);
  link.notify("control/hostChanged", { host: "box", state: "starting", workspace: workspace({ phase: "connecting" }) });
  assert.equal(store.hosts.value[0].state, "starting");
  assert.equal(store.hosts.value[0].workspace.phase, "connecting");
  link.notify("control/hostChanged", { host: "box", state: "offline" });
  assert.equal(store.hosts.value[0].workspace, undefined);
});

test("the sidebar's foot says a workspace's words, not that it is offline (#961)", () => {
  assert.equal(footLine(row("stopped", workspace())), "devbox is stopped. Agents there are paused until it starts.");
  assert.equal(footLine(row("starting", workspace({ phase: "provider" }))), "Starting devbox…");
  // Running, so agentsd is what went: the plain words.
  assert.equal(footLine(row("offline", workspace({ workspaceState: "running", canStart: false }))), "devbox is offline");
  assert.equal(footLine(row("connecting")), "devbox is connecting…");
  assert.equal(footLine(row("offline")), "devbox is offline");
});
