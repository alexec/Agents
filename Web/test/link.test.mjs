// The browser's socket (071 contracts/browser-auth.md "Closing", research R4): calls routed to a
// host or the control plane, replies and notifications, and every way the socket ends.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const w = await load("test/wire.ts");
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Sockets the link opens, each driven by the test. */
function sockets() {
  const made = [];
  return {
    made,
    open() {
      const socket = { sent: [], closed: null, onopen: null, onmessage: null, onclose: null, onerror: null,
        send(line) { this.sent.push(JSON.parse(line)); },
        close(code = 1000, reason = "") { if (this.closed) return; this.closed = code; queueMicrotask(() => this.onclose?.({ code, reason })); },
        say(object) { this.onmessage?.({ data: JSON.stringify(object) }); },
        drop(code = 1006) { this.close(code); } };
      made.push(socket);
      queueMicrotask(() => socket.onopen?.({}));
      return socket;
    },
  };
}

function paired() {
  const keys = new w.MemoryKeyStore();
  keys.record = { privateKey: {}, publicKey: {}, client: "C", control: "K", grant: "device", paired: "" };
  return keys;
}

function link(keys, net, extra = {}) {
  return new w.Link({ url: "ws://localhost:1/v1/connect", origin: "http://localhost:1", keys, open: () => net.open(),
    backoff: [0.01], heartbeat: { every: 60_000, within: 1_000 }, random: () => 0,
    authenticate: async () => ({ grant: "device", name: "test" }), ...extra });
}

async function opened(l) {
  const states = [];
  l.onState((state) => states.push(state.kind));
  l.start();
  await wait(5);
  return states;
}

test("with no key it is unpaired and dials nothing", async () => {
  const net = sockets();
  const l = link(new w.MemoryKeyStore(), net);
  const states = await opened(l);
  assert.deepEqual(states, ["unpaired"]);
  assert.equal(net.made.length, 0);
});

test("a host's method carries h, the control plane's doesn't, and replies come back by id", async () => {
  const net = sockets();
  const l = link(paired(), net);
  assert.deepEqual(await opened(l), ["connecting", "open"]);
  const socket = net.made[0];
  const agents = l.call("agents/list", {}, "k3v9");
  const status = l.call("control/status", {});
  assert.deepEqual(socket.sent[0], { h: "k3v9", m: { jsonrpc: "2.0", id: 1, method: "agents/list", params: {} } });
  assert.deepEqual(socket.sent[1], { m: { jsonrpc: "2.0", id: 2, method: "control/status", params: {} } });
  socket.say({ m: { jsonrpc: "2.0", id: 2, result: { name: "cp" } } });
  socket.say({ h: "k3v9", m: { jsonrpc: "2.0", id: 1, error: { code: -32090, message: "offline" } } });
  assert.deepEqual(await status, { name: "cp" });
  await assert.rejects(agents, (error) => error instanceof w.CallFailed && error.code === -32090);
  l.stop();
});

test("notifications reach listeners with their host", async () => {
  const net = sockets();
  const l = link(paired(), net);
  const heard = [];
  l.onNotification((method, params, host) => heard.push([method, params, host]));
  await opened(l);
  net.made[0].say({ h: "mac", m: { jsonrpc: "2.0", method: "agent/changed", params: { id: "A" } } });
  net.made[0].say({ m: { jsonrpc: "2.0", method: "control/hostChanged", params: { host: "mac" } } });
  assert.deepEqual(heard, [["agent/changed", { id: "A" }, "mac"], ["control/hostChanged", { host: "mac" }, null]]);
  l.stop();
});

test("a dropped socket is down, fails what was waiting, and comes back by itself", async () => {
  const net = sockets();
  const l = link(paired(), net);
  const states = await opened(l);
  const waiting = l.call("control/status", {});
  net.made[0].drop();
  await assert.rejects(waiting, w.LinkDown);
  await assert.rejects(l.call("control/status", {}), w.LinkDown);
  await wait(40);
  assert.deepEqual(states, ["connecting", "open", "down", "open"]);
  assert.equal(net.made.length, 2);
  l.stop();
});

test("close code 4403 is forgotten: the key goes and nothing redials", async () => {
  const net = sockets();
  const keys = paired();
  const l = link(keys, net);
  const states = await opened(l);
  net.made[0].drop(4403);
  await wait(40);
  assert.equal(states.at(-1), "forgotten");
  assert.equal(keys.record, null);
  assert.equal(net.made.length, 1);
});

test("refused as forgotten or unknown is forgotten too", async () => {
  for (const reason of ["forgotten", "unknown"]) {
    const net = sockets();
    const keys = paired();
    const l = link(keys, net, { authenticate: async () => { throw new w.Refused(reason); } });
    const states = await opened(l);
    assert.equal(states.at(-1), "forgotten", reason);
    assert.equal(keys.record, null);
  }
});

test("another control plane on this port keeps the key and says so", async () => {
  const net = sockets();
  const keys = paired();
  const l = link(keys, net, { authenticate: async () => { throw new w.WrongControlPlane(); } });
  const states = await opened(l);
  assert.equal(states.at(-1), "wrongControlPlane");
  assert.notEqual(keys.record, null);
});

test("a socket that stops answering is closed and redialled", async () => {
  const net = sockets();
  const l = link(paired(), net, { heartbeat: { every: 10, within: 10 } });
  const states = await opened(l);
  await wait(60);
  assert.ok(net.made[0].closed === 4000, "the first socket was closed for not answering");
  assert.ok(states.includes("down"));
  assert.ok(net.made.length >= 2);
  l.stop();
});

test("retryNow dials at once when down", async () => {
  const net = sockets();
  const l = link(paired(), net, { backoff: [60] });
  await opened(l);
  net.made[0].drop();
  await wait(5);
  assert.equal(l.state.kind, "down");
  l.retryNow();
  await wait(5);
  assert.equal(l.state.kind, "open");
  l.stop();
});

test("the page's own link notices a hang within 4 s and retries at most 4 s apart (US7)", async () => {
  const { loopbackTiming } = await load("src/session.ts");
  assert.ok(loopbackTiming.heartbeat.every + loopbackTiming.heartbeat.within <= 4_000);
  // The retry delay is the step times up to 1.2.
  assert.ok(Math.max(...loopbackTiming.backoff) * 1.2 <= 5);
});
