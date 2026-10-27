// A browser pairs by approval (#2097): signIn/ask on s:<a new client> with the account typed, the
// code it makes from its key and the control key shown while control/signInWaiting says it waits, and the key kept once it is approved.
// Cancel closes it and says nothing; running out says so.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

delete globalThis.BroadcastChannel;
const { Session } = await load("src/session.ts");
const { approvalCode } = await load("src/wire/signIn.ts");
const w = await load("test/wire.ts");
const v = JSON.parse(readFileSync(new URL("./vectors.json", import.meta.url)));
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const origin = "https://agents.example.com";
const control = w.unhex(v.control.public);
const b64 = (bytes) => w.base64url(bytes);
// The control plane's private key, for the ECDH the other way round.
const controlPrivate = await crypto.subtle.importKey("jwk", {
  kty: "EC", crv: "P-256", d: b64(w.unhex(v.control.private)), x: b64(control.slice(1, 33)), y: b64(control.slice(33)),
}, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);

/** A control plane that proves itself to any new key, and answers signIn/ask with `answer(message, socket)`. */
function controlPlane(answer) {
  const made = [];
  return {
    made,
    open() {
      const serverNonce = crypto.getRandomValues(new Uint8Array(32));
      const socket = { sent: [], closed: false, onopen: null, onmessage: null, onclose: null, onerror: null,
        async send(line) {
          const message = JSON.parse(line);
          socket.sent.push(message);
          // The link's own c: dial, once paired, is only looked at.
          if (message.auth && !message.auth.publicKey) return;
          if (message.auth) {
            const client = message.auth.id.slice(2);
            const key = await w.clientKey(controlPrivate, new Uint8Array(Buffer.from(message.auth.publicKey, "base64")), client);
            const said = w.concat(w.utf8("agents-auth-v1"), serverNonce, w.fromBase64url(message.auth.nonce), w.utf8(message.auth.id), w.utf8(origin));
            const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, w.concat(w.utf8("s"), said)));
            return socket.say({ ok: { mac: b64(mac) } });
          }
          if (message.method) answer(message, socket, message.auth);
        },
        close(code = 1000, reason = "") { socket.closed = true; queueMicrotask(() => socket.onclose?.({ code, reason })); },
        say(object) { queueMicrotask(() => socket.onmessage?.({ data: JSON.stringify(object) })); } };
      made.push(socket);
      queueMicrotask(() => {
        socket.onopen?.({});
        socket.say({ hello: { v: 1, name: "Acme", control: b64(control), nonce: b64(serverNonce) } });
      });
      return socket;
    },
  };
}

function session(net) {
  const keys = new w.MemoryKeyStore();
  return { keys, session: new Session(keys, origin, () => net.open(), new w.MemoryPendingStore()) };
}

test("the code shows while it waits, and approved, the new key is this browser's", async () => {
  let approve;
  const net = controlPlane((m, socket) => {
    socket.say({ jsonrpc: "2.0", method: "control/signInWaiting", params: { code: "K7Q2MX", expires: "2026-10-22T00:00:00Z" } });
    approve = () => socket.say({ jsonrpc: "2.0", id: m.id, result: { client: socket.sent[0].auth.id.slice(2) } });
  });
  const { keys, session: s } = session(net);
  const going = s.askToPair("  sam@example.com ");
  await wait(100);
  const ask = net.made[0].sent[1];
  assert.equal(ask.method, "signIn/ask");
  assert.deepEqual(ask.params, { account: "sam@example.com", name: "A browser" });
  // Its own code, never the control plane's.
  const publicRaw = new Uint8Array(Buffer.from(net.made[0].sent[0].auth.publicKey, "base64"));
  assert.equal(s.askCode.value, await approvalCode(publicRaw, control));
  assert.notEqual(s.askCode.value, "K7Q2MX");
  assert.equal(keys.record, null);
  approve();
  await going;
  assert.equal(s.askCode.value, null);
  assert.equal(keys.record.client, net.made[0].sent[0].auth.id.slice(2));
  assert.equal(keys.record.control, b64(control));
  await wait(50);
  assert.equal(net.made[1].sent[0].auth.id, "c:" + keys.record.client);
  s.link.stop();
});

test("Cancel closes the wait and says nothing; running out says so", async () => {
  const net = controlPlane((m, socket) => {
    socket.say({ jsonrpc: "2.0", method: "control/signInWaiting", params: { code: "K7Q2MX", expires: "2026-10-22T00:00:00Z" } });
  });
  const { keys, session: s } = session(net);
  const going = s.askToPair("nobody@example.com");
  await wait(100);
  s.cancelAsk();
  await going;
  assert.equal(net.made[0].closed, true);
  assert.equal(s.pairingError.value, null);
  assert.equal(keys.record, null);

  const late = controlPlane((m, socket) => socket.say({ jsonrpc: "2.0", id: m.id,
    error: { code: -32010, message: "Nobody approved the sign-in within 10 minutes. Sign in again." } }));
  const other = session(late);
  await other.session.askToPair("sam");
  assert.match(other.session.pairingError.value, /within 10 minutes/);
  assert.equal(other.keys.record, null);
});

// One vector with the control plane's Go (controllink.TestApprovalCodeIsBoundToBothKeys).
test("the approval code is the control plane's", async () => {
  assert.equal(await approvalCode(new Uint8Array(65).fill(1), new Uint8Array(65).fill(2)), "8UMUNH");
});
