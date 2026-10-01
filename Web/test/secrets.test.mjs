// Nothing secret reaches the console (071 FR-033, SC-008): not the code, not a key, not a MAC,
// not anything a message said. A pairing, a connection, calls and notifications run with the
// console watched.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const w = await load("test/wire.ts");
const v = JSON.parse(readFileSync(new URL("./vectors.json", import.meta.url)));

test("the console hears event names and codes, never a secret or a message", async () => {
  const said = [];
  const methods = ["log", "info", "warn", "error", "debug"];
  const saved = Object.fromEntries(methods.map((m) => [m, console[m]]));
  for (const m of methods) console[m] = (...args) => said.push(args.map(String).join(" "));
  try {
    const codeText = `agents-control:2:c:device:${w.base64url(w.unhex(v.control.public))}:${v.code.secretBase64url}:x:-:n`;
    const queue = [JSON.stringify({ hello: { control: w.base64url(w.unhex(v.control.public)), nonce: w.base64url(w.unhex(v.serverNonce)) } }),
      JSON.stringify({ ok: { mac: w.base64url(w.unhex(v.code.mac.server)) } }),
      JSON.stringify({ jsonrpc: "2.0", id: 1, error: { code: -32602, message: "a secret message" } })];
    const socket = { send() {}, async next() { return queue.shift(); }, close() {} };
    await assert.rejects(w.pair(socket, w.parseCode(codeText), v.origin, "Chrome",
      async () => ({ client: "C", publicRaw: w.unhex(v.client.public) }), w.unhex(v.peerNonce)));

    const keys = new w.MemoryKeyStore();
    keys.record = { privateKey: {}, publicKey: {}, client: "C", control: "K", grant: "device", paired: "" };
    let open;
    const l = new w.Link({ url: "ws://x", origin: "http://x", keys, backoff: [60], heartbeat: { every: 60_000, within: 1 },
      authenticate: async () => ({ grant: "device", name: "n" }),
      open: () => (open = { send() {}, close() {}, onopen: null, onmessage: null, onclose: null, onerror: null }) });
    l.start();
    await new Promise((r) => setTimeout(r, 5));
    open.onopen({});
    await new Promise((r) => setTimeout(r, 5));
    const call = l.call("agents/prompt", { text: "the person's secret prompt" }, "mac");
    open.onmessage({ data: JSON.stringify({ h: "mac", m: { jsonrpc: "2.0", id: 1, error: { code: -32000, message: "a secret reply" } } }) });
    await assert.rejects(call);
    open.onmessage({ data: JSON.stringify({ h: "mac", m: { jsonrpc: "2.0", method: "agent/entry", params: { text: "an agent's secret" } } }) });
    l.stop();
  } finally {
    Object.assign(console, saved);
  }
  const all = said.join("\n");
  assert.ok(said.length > 0, "something was logged");
  for (const secret of [v.code.secretBase64url, v.code.secret, w.base64url(w.unhex(v.code.mac.peer)),
    w.base64url(w.unhex(v.control.public)), "secret prompt", "secret reply", "secret message", "agent's secret"]) {
    assert.ok(!all.includes(secret), `the console said ${secret.slice(0, 12)}…`);
  }
  for (const line of said) assert.match(line, /^agents: [a-zA-Z.]+( [\w-]+)?$/);
});
