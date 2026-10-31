// The browser's key exchange against the bytes Swift makes (Web/test/vectors.json, written by
// ControlAgreementVectorTests), and against a fake control plane for each way it can go wrong
// (071 contracts/browser-auth.md).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const w = await load("test/wire.ts");
const v = JSON.parse(readFileSync(new URL("./vectors.json", import.meta.url)));
const curve = { name: "ECDH", namedCurve: "P-256" };

/** A control plane that says `hello`, records what it hears, and answers from `script`. */
function fakeServer(script) {
  const heard = [];
  const queue = [JSON.stringify({ hello: { v: 1, name: "test", control: w.base64url(w.unhex(v.control.public)),
    nonce: w.base64url(w.unhex(v.serverNonce)), copy: "c" } })];
  return {
    heard,
    socket: {
      send(line) {
        heard.push(JSON.parse(line));
        const answer = script(JSON.parse(line), heard.length);
        if (answer !== undefined) queue.push(JSON.stringify(answer));
      },
      async next() {
        if (!queue.length) throw new Error("nothing more to read");
        return queue.shift();
      },
      close() {},
    },
  };
}

const code = (slot = "operator") => w.parseCode(`agents-control:2:c:${slot}:${w.base64url(w.unhex(v.control.public))}:${v.code.secretBase64url}:http%3A%2F%2Flocalhost%3A8893:-:Alex%27s%20control%20plane`);

test("a code parses, and only a client code of version 2", () => {
  const parsed = code();
  assert.equal("grant" in parsed, false);
  // A code from an older Mac said a grant there; it reads the same (#111).
  assert.deepEqual(code("device"), parsed);
  assert.equal(parsed.name, "Alex's control plane");
  assert.equal(w.codeIdentity(parsed), v.code.identity);
  assert.equal(w.parseCode("agents-control:2:h:-:" + "x".repeat(10)), null);
  assert.equal(w.parseCode("nonsense"), null);
  assert.equal(w.parseCode(`agents-control:2:c:device:AAAA:${v.code.secretBase64url}:x:-:n`), null);
});

test("pairing proves the code as Swift does, and checks the control plane's proof", async () => {
  const server = fakeServer((line, n) => {
    if (n === 1) return { ok: { mac: w.base64url(w.unhex(v.code.mac.server)), grant: "device" } };
    if (n === 2) return { jsonrpc: "2.0", id: 1, result: { client: line.params.id, grant: "device" } };
  });
  const made = await w.pair(server.socket, code(), v.origin, "Chrome",
    async () => ({ client: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8", publicRaw: w.unhex(v.client.public) }),
    w.unhex(v.peerNonce));
  const [auth, announce] = server.heard;
  assert.deepEqual(auth.auth, { id: v.code.identity, nonce: w.base64url(w.unhex(v.peerNonce)),
    mac: w.base64url(w.unhex(v.code.mac.peer)), kind: "browser" });
  assert.equal(announce.method, "clients/announce");
  assert.deepEqual(announce.params, { id: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8", publicKey: w.base64(w.unhex(v.client.public)),
    name: "Chrome", kind: "browser" });
  assert.deepEqual(made, { name: "test", client: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8" });
});

test("a code the control plane won't pair a browser with is refused in its own words (R2)", async () => {
  const words = "That code is for a window or a phone. Get one from Add a Browser….";
  const server = fakeServer((line, n) => {
    if (n === 1) return { ok: { mac: w.base64url(w.unhex(v.code.mac.server)), grant: "device" } };
    if (n === 2) return { jsonrpc: "2.0", id: 1, error: { code: -32602, message: words } };
  });
  await assert.rejects(w.pair(server.socket, code(), v.origin, "Chrome",
    async () => ({ client: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8", publicRaw: w.unhex(v.client.public) }),
    w.unhex(v.peerNonce)), (error) => error instanceof w.AnnounceRefused && error.message === words);
});

test("connecting proves the browser's key as Swift does", async () => {
  const privateKey = await crypto.subtle.importKey("jwk", v.client.jwk, curve, false, ["deriveBits"]);
  const record = { privateKey, publicKey: null, client: v.client.id, control: w.base64url(w.unhex(v.control.public)),
    paired: "" };
  // An older control plane still says a grant in its `ok`; it isn't read (#111).
  const server = fakeServer(() => ({ ok: { mac: w.base64url(w.unhex(v.client.mac.server)), grant: "device" } }));
  const admitted = await w.connect(server.socket, record, v.origin, w.unhex(v.peerNonce));
  assert.equal(server.heard[0].auth.id, v.client.identity);
  assert.equal(server.heard[0].auth.mac, w.base64url(w.unhex(v.client.mac.peer)));
  // A paired client says what it has (#1748).
  assert.deepEqual(server.heard[0].auth.capabilities, ["client.wire/1", "client.team/1"]);
  assert.equal("grant" in admitted, false);
});

test("after a rotation the browser proves itself with the previous key and takes the new one, with its proof (#997)", async () => {
  // The proof is the same bytes as Go's and Swift's (TestTheNewKeyProofIsTheClientsOwn).
  const ones = await crypto.subtle.importKey("raw", new Uint8Array(32).fill(1), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const fresh = new Uint8Array(65).fill(2);
  fresh[0] = 4;
  const vector = new Uint8Array(await crypto.subtle.sign("HMAC", ones, w.newKeyMessage(fresh)));
  assert.equal(w.base64url(vector), "v9-kYG-84IN39u6AMjxueMV9PJ0RFPVWlUAghG140Wg");

  const privateKey = await crypto.subtle.importKey("jwk", v.client.jwk, curve, false, ["deriveBits"]);
  const previous = w.base64url(w.unhex(v.control.public));
  const record = { privateKey, publicKey: null, client: v.client.id, control: previous, paired: "" };
  const shared = await w.clientKey(privateKey, w.unhex(v.control.public), v.client.id);
  const proof = new Uint8Array(await crypto.subtle.sign("HMAC", shared, w.newKeyMessage(fresh)));
  const rotated = (newKey) => {
    const server = fakeServer(() => ({ ok: { mac: w.base64url(w.unhex(v.client.mac.server)), newKey } }));
    // The hello names the new key, and the one the browser trusts as the previous.
    server.socket.next = ((next) => async () => {
      const line = JSON.parse(await next());
      if (line.hello) line.hello = { ...line.hello, control: w.base64url(fresh), previous };
      return JSON.stringify(line);
    })(server.socket.next);
    return server;
  };
  const admitted = await w.connect(rotated({ key: w.base64url(fresh), proof: w.base64url(proof) }).socket, record, v.origin,
    w.unhex(v.peerNonce));
  assert.equal(admitted.newKey, w.base64url(fresh));
  await assert.rejects(w.connect(rotated({ key: w.base64url(fresh), proof: w.base64url(new Uint8Array(32)) }).socket, record,
    v.origin, w.unhex(v.peerNonce)), w.WrongControlPlane);
});

test("a code for another control plane sends nothing", async () => {
  const other = code();
  other.controlKey = w.unhex("04" + "11".repeat(64));
  const server = fakeServer(() => undefined);
  await assert.rejects(w.pair(server.socket, other, v.origin, "Chrome", async () => assert.fail("made a key")), w.WrongControlPlane);
  assert.equal(server.heard.length, 0);
});

test("each refusal is said as itself", async () => {
  for (const reason of ["expired", "spent", "unknown", "bad-proof", "forgotten"]) {
    const server = fakeServer(() => ({ refused: { reason } }));
    await assert.rejects(w.pair(server.socket, code(), v.origin, "Chrome", async () => assert.fail("made a key")),
      (error) => error instanceof w.Refused && error.reason === reason);
  }
});

test("a control plane that can't prove the code is refused before a key is made", async () => {
  const server = fakeServer(() => ({ ok: { mac: w.base64url(new Uint8Array(32)), grant: "device" } }));
  await assert.rejects(w.pair(server.socket, code(), v.origin, "Chrome", async () => assert.fail("made a key")), w.BadServerProof);
});

test("a proof made for another origin doesn't match", async () => {
  const server = fakeServer(() => ({ ok: { mac: w.base64url(w.unhex(v.code.mac.server)), grant: "device" } }));
  await assert.rejects(w.pair(server.socket, code(), "http://localhost:9999", "Chrome", async () => assert.fail("made a key"),
    w.unhex(v.peerNonce)), w.BadServerProof);
  assert.notEqual(server.heard[0].auth.mac, w.base64url(w.unhex(v.code.mac.peer)));
});

test("a made key is P-256, non-extractable, with an upper-case id", async () => {
  const { pair, publicRaw } = await w.makeKeyPair();
  assert.equal(pair.privateKey.extractable, false);
  assert.equal(publicRaw.length, 65);
  assert.equal(publicRaw[0], 4);
  await assert.rejects(crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const id = w.newClientID();
  assert.equal(id, id.toUpperCase());
});

test("a sign-in connection proves the new key as s:<id>, with the key Swift derives, and says its public half (#1002)", async () => {
  const privateKey = await crypto.subtle.importKey("jwk", v.client.jwk, curve, false, ["deriveBits"]);
  const publicRaw = w.unhex(v.client.public);
  const hmac = await crypto.subtle.importKey("raw", w.unhex(v.client.key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const said = (identity) => w.concat(w.utf8("agents-auth-v1"), w.unhex(v.serverNonce), w.unhex(v.peerNonce), w.utf8(identity), w.utf8(v.origin));
  const identity = "s:" + v.client.id;
  const serverMac = new Uint8Array(await crypto.subtle.sign("HMAC", hmac, w.concat(w.utf8("s"), said(identity))));
  const server = fakeServer(() => ({ ok: { mac: w.base64url(serverMac) } }));
  const signedIn = await w.signInConnect(server.socket, v.client.id, privateKey, publicRaw, v.origin, w.unhex(v.peerNonce));
  const auth = server.heard[0].auth;
  assert.equal(auth.id, identity);
  const peerMac = new Uint8Array(await crypto.subtle.sign("HMAC", hmac, w.concat(w.utf8("c"), said(identity))));
  assert.equal(auth.mac, w.base64url(peerMac));
  // Standard base64, as Go writes []byte; not a paired client's capabilities.
  assert.equal(auth.publicKey, w.base64(publicRaw));
  assert.equal(auth.capabilities, undefined);
  assert.equal(signedIn.control, w.base64url(w.unhex(v.control.public)));
  assert.equal(signedIn.name, "test");
});

test("a paired client's auth says no public key", async () => {
  const privateKey = await crypto.subtle.importKey("jwk", v.client.jwk, curve, false, ["deriveBits"]);
  const record = { privateKey, publicKey: null, client: v.client.id, control: w.base64url(w.unhex(v.control.public)), paired: "" };
  const server = fakeServer(() => ({ ok: { mac: w.base64url(w.unhex(v.client.mac.server)) } }));
  await w.connect(server.socket, record, v.origin, w.unhex(v.peerNonce));
  assert.equal("publicKey" in server.heard[0].auth, false);
});

test("a sign-in connection's calls are bare JSON-RPC, and a refusal keeps its code and data", async () => {
  const sent = [];
  const replies = [
    JSON.stringify({ jsonrpc: "2.0", method: "control/signInWaiting", params: { code: "X" } }),
    JSON.stringify({ jsonrpc: "2.0", id: 1, result: { orgProviders: [{ id: "okta", name: "Okta", order: 0 }] } }),
    JSON.stringify({ jsonrpc: "2.0", id: 2, error: { code: -32077, message: "use Okta", data: { provider: "okta", name: "Okta" } } }),
  ];
  const lines = { send: (line) => sent.push(JSON.parse(line)), next: async () => replies.shift(), close() {} };
  const connection = new w.SignInConnection(lines, { name: "cp", control: "K" });
  const providers = await connection.call("signIn/providers", {});
  assert.deepEqual(sent[0], { jsonrpc: "2.0", id: 1, method: "signIn/providers", params: {} });
  assert.equal(providers.orgProviders[0].name, "Okta");
  await assert.rejects(connection.call("signIn/ticket", { ticket: "t" }),
    (error) => error instanceof w.CallFailed && error.code === -32077 && error.data.provider === "okta");
});
