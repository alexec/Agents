// The machine lock in the page (#3490, specs/3399-machine-lock): the chain Go made
// (Fixtures/lock/vectors.json, from TestTheLockVectors) checks here, the forged one does not,
// the commitment and the six digits are Go's, a chain this page signs checks, and Follow
// refuses a fork or a lock kept back. Then the whole join, two browsers on a fake control plane.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const m = await load("src/wire/machineLock.ts");
const model = await load("src/model/machineLock.ts");
const vectors = JSON.parse(readFileSync(new URL("../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/lock/vectors.json", import.meta.url)));
const b64 = (bytes) => Buffer.from(bytes).toString("base64");
const bytes = (text) => new Uint8Array(Buffer.from(text, "base64"));
const hex = (u) => Buffer.from(u).toString("hex");
const wait = (ms = 20) => new Promise((resolve) => setTimeout(resolve, ms));

test("Go's lock checks here, with its root, head and members", async () => {
  const state = await m.check(vectors.lock.entries);
  assert.equal(state.person, vectors.lock.person);
  assert.equal(hex(state.root), vectors.root);
  assert.equal(hex(state.head), vectors.head);
  assert.equal(state.count, vectors.lock.entries.length);
  const members = state.membersOf("addClient").map((member) => ({ key: b64(member.key), kind: member.kind, name: member.name, clientKind: member.clientKind }));
  assert.deepEqual(members, vectors.members);
});

test("the forged lock fails as forged", async () => {
  await assert.rejects(m.check(vectors.forged.entries), (error) => error.failure === "forged" && error.index === 1);
});

test("the commitment and the digits are Go's", async () => {
  const j = vectors.join;
  assert.equal(b64(await m.commitment(bytes(j.key), bytes(j.clientNonce))), j.commitment);
  assert.equal(await m.digits(bytes(j.key), bytes(j.clientNonce), bytes(j.signerNonce)), j.digits);
  assert.equal(m.spaced("562733"), "562 733");
});

async function signer() {
  const { pair, publicRaw } = await m.makeSigningKey();
  assert.equal(pair.privateKey.extractable, false);
  assert.equal(publicRaw.length, 65);
  return { pair, publicRaw };
}

test("a chain this page signs checks, and Follow refuses a fork and a lock kept back", async () => {
  const a = await signer();
  const b = await signer();
  const root = await m.sign(a.pair.privateKey, a.publicRaw, { kind: "root", person: "alex", at: m.wireNow(), key: b64(a.publicRaw), clientKind: "web" });
  const one = await m.check([root]);
  const add = await m.sign(a.pair.privateKey, a.publicRaw, {
    kind: "addClient", person: "alex", previous: b64(one.head), at: m.wireNow(), key: b64(b.publicRaw), name: "Sam’s iPhone", clientKind: m.lockClientKind("iPhone"),
  });
  const lock = { person: "alex", entries: [root, add] };
  const two = await m.check(lock.entries);
  assert.equal(two.count, 2);
  assert.equal(two.member(b.publicRaw)?.clientKind, "remote");
  assert.ok(two.signer(b.publicRaw));

  // Followed from the pin of one entry, it grows; a zero pin takes it too.
  assert.equal((await m.follow(one.pin(), lock)).count, 2);
  assert.equal((await m.follow(m.zeroPin, lock)).count, 2);
  // Kept back: fewer entries than pinned.
  await assert.rejects(m.follow(two.pin(), { person: "alex", entries: [root] }), (error) => error.failure === "behind");
  // A fork: another second entry after the same root.
  const c = await signer();
  const other = await m.sign(a.pair.privateKey, a.publicRaw, {
    kind: "addClient", person: "alex", previous: b64(one.head), at: m.wireNow(), key: b64(c.publicRaw), clientKind: "web",
  });
  await assert.rejects(m.follow(two.pin(), { person: "alex", entries: [root, other] }), (error) => error.failure === "forked");
  // Another person's lock.
  await assert.rejects(m.follow({ ...two.pin(), person: "kim" }, lock), (error) => error.failure === "forked");
  // An entry signed by a key that is not a client.
  const stranger = await m.sign(c.pair.privateKey, c.publicRaw, {
    kind: "addClient", person: "alex", previous: b64(two.head), at: m.wireNow(), key: b64(c.publicRaw), clientKind: "web",
  });
  await assert.rejects(m.check([root, add, stranger]), (error) => error.failure === "forged");
  // Out of order.
  await assert.rejects(m.check([add, root]), (error) => error.failure === "outOfOrder");
  // A changed body.
  const changed = { ...add, body: b64(Buffer.from(Buffer.from(add.body, "base64").toString().replace("Sam", "Kim"))) };
  await assert.rejects(m.check([root, changed]), (error) => error.failure === "forged");
});

/** A control plane that keeps one person's lock and join requests, as lockjoins.go does. */
function controlPlane(person = "alex") {
  const lock = { person, entries: [] };
  const requests = new Map();
  const clients = [];
  let n = 0;
  const tell = (method, params) => { for (const c of clients) queueMicrotask(() => c.lock.notify(method, structuredClone(params))); };
  const row = (r) => { const { result, ...rest } = r; return rest; };
  const changed = (r) => (r.result ? tell("control/lockJoinDecided", { request: r.request, result: r.result }) : tell("control/lockJoinRequested", row(r)));
  const fail = (code, message) => Object.assign(new Error(message), { code });
  const plane = {
    lock, requests, calls: [],
    connect(client, name, kind = "browser", pins = new model.MemoryPins()) {
      const keys = { pair: null };
      const said = [];
      const link = {
        call: (method, params) => plane.answer(client, name, kind, method, structuredClone(params)),
        keyRecord: async () => ({ client }),
        lockKey: async () => keys.pair,
        saveLockKey: async (pair) => { keys.pair = pair; },
      };
      const entry = { client, keys, said, pins, lock: new model.MachineLock(link, pins, (error) => said.push(error.message)) };
      clients.push(entry);
      return entry;
    },
    async answer(client, name, kind, method, params) {
      plane.calls.push({ client, method, params });
      switch (method) {
        case "lock/get": return structuredClone(lock);
        case "lock/add": {
          const state = await m.check(lock.entries);
          const first = await m.open(params.entries[0]);
          if ((first.previous ?? "") !== (lock.entries.length ? b64(state.head) : "")) throw fail(-32093, "Another of your devices changed your lock at the same time.");
          for (const e of params.entries) await state.add(e);
          lock.entries.push(...params.entries);
          tell("control/lockChanged", { count: state.count, head: b64(state.head) });
          for (const r of requests.values()) {
            const member = r.result ? undefined : state.member(bytes(r.key));
            if (member) { r.result = "approved"; changed(r); }
          }
          return { count: state.count, head: b64(state.head) };
        }
        case "lock/join": {
          for (const r of requests.values()) if (r.client === client && !r.result) { r.result = "expired"; changed(r); }
          const r = { request: `r${++n}`, client, name, kind, key: params.key, commitment: params.commitment, expires: m.wireNow() + 600 };
          requests.set(r.request, r);
          changed(r);
          return { request: r.request, expires: r.expires };
        }
        case "lock/joinRequests": return [...requests.values()].filter((r) => !r.result).map(row);
        case "lock/joinRequests:machine": {
          // A machine asks on its channel 0 (#3491): machine/lockJoin, as lockjoins.go's askMachine.
          const r = { request: `r${++n}`, client: params.host, machine: params.host, name: params.name, kind: "unknown",
            key: params.key, commitment: params.commitment, expires: m.wireNow() + 600 };
          requests.set(r.request, r);
          changed(r);
          return r;
        }
        case "lock/joinAnswer": {
          const r = requests.get(params.request);
          if (r.client === client) throw fail(-32003, "A device cannot approve itself.");
          if (r.nonce) throw fail(-32003, "Another of your devices is comparing the digits already.");
          r.nonce = params.nonce;
          r.answeredBy = client;
          changed(r);
          return {};
        }
        case "lock/joinReveal": {
          const r = requests.get(params.request);
          if (b64(await m.commitment(bytes(r.key), bytes(params.nonce))) !== r.commitment) throw fail(-32602, "That nonce is not the one the request named.");
          r.reveal = params.nonce;
          changed(r);
          return {};
        }
        case "lock/joinDeny": {
          const r = requests.get(params.request);
          r.result = "denied";
          changed(r);
          return {};
        }
        case "lock/reset":
          lock.entries.length = 0;
          tell("control/lockChanged", { count: 0, head: "" });
          return {};
      }
      throw fail(-32601, `No method ${method}.`);
    },
  };
  return plane;
}

test("the first browser makes the root; a second asks, compares digits and is approved", async () => {
  const plane = controlPlane();
  const mac = plane.connect("AAAA-1111", "Mac");
  await mac.lock.run();
  assert.equal(mac.lock.device.value.kind, "member");
  // The root, and the recovery key with it (#3493), shown once.
  assert.equal(plane.lock.entries.length, 2);
  assert.equal(mac.pins.pin.count, 2);
  assert.equal(mac.keys.pair.privateKey.extractable, false);
  assert.equal(mac.lock.recovery.value.kind, "show");

  const web = plane.connect("BBBB-2222", "A browser");
  await web.lock.run();
  await wait();
  assert.equal(web.lock.device.value.kind, "asking");
  assert.equal(web.lock.device.value.digits, undefined);
  // The signer sees the request, and never its own.
  assert.equal(mac.lock.cards.value.length, 1);
  assert.equal(mac.lock.cards.value[0].view.kind, "compare");
  assert.equal(mac.lock.cards.value[0].request.name, "A browser");
  assert.equal(web.lock.cards.value.length, 0);

  await mac.lock.compare(mac.lock.cards.value[0].request.request);
  await wait(50);
  // The browser showed its nonce on the signer's; both make the same digits.
  const shown = web.lock.device.value.digits;
  assert.match(shown, /^\d{6}$/);
  const card = mac.lock.cards.value[0];
  assert.deepEqual(card.view, { kind: "digits", digits: shown });

  await mac.lock.approve(card.request.request);
  await wait(50);
  assert.equal(plane.lock.entries.length, 3);
  assert.equal(web.lock.device.value.kind, "member");
  assert.equal(mac.lock.cards.value.length, 0);
  assert.equal(web.pins.pin.count, 3);
  // A second device: the lock is not offered a recovery key again there.
  assert.equal(web.lock.recovery.value.kind, "none");
  const state = await m.check(plane.lock.entries);
  assert.equal(state.membersOf("addClient")[1].clientKind, "web");
  assert.deepEqual(mac.said, []);
  assert.deepEqual(web.said, []);
});

test("another signer sees that one is comparing; a deny ends the ask, and Ask Again asks anew", async () => {
  const plane = controlPlane();
  const mac = plane.connect("AAAA-1111", "Mac");
  await mac.lock.run();
  const phone = plane.connect("CCCC-3333", "iPhone", "iPhone");
  // The phone is in the lock already, by an entry the Mac signed.
  phone.keys.pair = (await m.makeSigningKey()).pair;
  const phoneRaw = new Uint8Array(await crypto.subtle.exportKey("raw", phone.keys.pair.publicKey));
  const head = (await m.check(plane.lock.entries)).head;
  await plane.answer("AAAA-1111", "Mac", "mac", "lock/add", { entries: [await m.sign(mac.keys.pair.privateKey,
    new Uint8Array(await crypto.subtle.exportKey("raw", mac.keys.pair.publicKey)),
    { kind: "addClient", person: "alex", previous: b64(head), at: m.wireNow(), key: b64(phoneRaw), clientKind: "remote" })] });
  await phone.lock.run();
  await wait();
  assert.equal(phone.lock.device.value.kind, "member");

  const web = plane.connect("BBBB-2222", "A browser");
  await web.lock.run();
  await wait();
  const request = mac.lock.cards.value[0].request.request;
  await phone.lock.compare(request);
  await wait(50);
  assert.equal(mac.lock.cards.value[0].view.kind, "another");
  assert.equal(phone.lock.cards.value[0].view.kind, "digits");

  await mac.lock.deny(request);
  await wait(50);
  assert.deepEqual(web.lock.device.value, { kind: "ended", result: "denied" });
  assert.equal(phone.lock.cards.value.length, 0);

  // A change to the lock does not ask again by itself.
  await web.lock.run();
  assert.equal(web.lock.device.value.kind, "ended");
  await web.lock.askAgain();
  await wait();
  assert.equal(web.lock.device.value.kind, "asking");
  assert.equal(mac.lock.cards.value.length, 1);
  assert.equal(mac.lock.cards.value[0].view.kind, "compare");
});

test("digits come from this signer's nonce, and a reveal that breaks its promise is refused", async () => {
  const plane = controlPlane();
  const mac = plane.connect("AAAA-1111", "Mac");
  await mac.lock.run();
  const web = plane.connect("BBBB-2222", "A browser");
  await web.lock.run();
  await wait();
  const request = mac.lock.cards.value[0].request.request;
  await mac.lock.compare(request);
  await wait(50);
  const honest = mac.lock.cards.value[0].view.digits;
  // A control plane that puts its own nonce in the row does not change the signer's digits.
  const r = plane.requests.get(request);
  mac.lock.notify("control/lockJoinRequested", { ...r, nonce: b64(new Uint8Array(16).fill(9)) });
  await wait();
  assert.equal(mac.lock.cards.value[0].view.digits, honest);
  // One that shows another reveal than the commitment named is caught.
  mac.lock.notify("control/lockJoinRequested", { ...r, reveal: b64(new Uint8Array(16).fill(7)) });
  await wait();
  assert.equal(mac.lock.cards.value[0].view.kind, "notPromised");
  await mac.lock.approve(request);
  assert.equal(plane.lock.entries.length, 2);
});

test("a lock that forks from the pin is broken, and says so", async () => {
  const plane = controlPlane();
  const mac = plane.connect("AAAA-1111", "Mac");
  await mac.lock.run();
  // The control plane swaps the lock for one of its own.
  const other = await signer();
  plane.lock.entries = [await m.sign(other.pair.privateKey, other.publicRaw, { kind: "root", person: "alex", at: m.wireNow(), key: b64(other.publicRaw) })];
  await mac.lock.run();
  assert.equal(mac.lock.device.value.kind, "broken");
  assert.equal(model.brokenWords(mac.lock.device.value), "The lock changed in a way your devices did not sign.");
  assert.equal(model.brokenWords({ forked: false, why: "entry 1: x" }), "Your lock does not check: entry 1: x.");
});

/** A machine's key and a request it makes on the fake plane, as agentsd's machine/lockJoin does. */
async function machineAsks(plane, host, name) {
  const { publicRaw } = await m.makeSigningKey();
  const nonce = m.newNonce();
  const r = await plane.answer(host, name, "unknown", "lock/joinRequests:machine",
    { host, name, key: b64(publicRaw), commitment: b64(await m.commitment(publicRaw, nonce)) });
  return { key: publicRaw, nonce, request: r.request };
}

test("a machine that asks is approved with an addMachine, its key its sealing key (#3491)", async () => {
  const plane = controlPlane();
  const mac = plane.connect("AAAA-1111", "Mac");
  await mac.lock.run();
  const box = await machineAsks(plane, "h-box", "dev-3");
  await wait();
  const card = mac.lock.cards.value[0];
  assert.equal(card.request.machine, "h-box");
  assert.equal(card.view.kind, "compare");
  await mac.lock.compare(box.request);
  await wait();
  // The machine reveals its nonce, as agentsd does once it hears the signer's.
  const r = plane.requests.get(box.request);
  await plane.answer("h-box", "dev-3", "unknown", "lock/joinReveal", { request: box.request, nonce: b64(box.nonce) });
  await wait(50);
  const shown = await m.digits(box.key, box.nonce, bytes(r.nonce));
  assert.deepEqual(mac.lock.cards.value[0].view, { kind: "digits", digits: shown });
  await mac.lock.approve(box.request);
  await wait(50);
  const state = await m.check(plane.lock.entries);
  const added = state.member(box.key);
  assert.equal(added.kind, "addMachine");
  assert.equal(added.id, "h-box");
  assert.equal(added.name, "dev-3");
  assert.equal(b64(added.sealingKey), b64(box.key));
  assert.equal(plane.requests.get(box.request).result, "approved");
  assert.deepEqual(mac.said, []);
});

test("a host code gets an invite on the lock, and only machines the lock names are sealed to (#3491)", async () => {
  const plane = controlPlane();
  const mac = plane.connect("AAAA-1111", "Mac");
  await mac.lock.run();
  const code = "agents-control:2:h:-:KEY:SECRET:https%3A%2F%2Fcontrol.example:-:Sam%27s";
  const shown = await mac.lock.invite({ text: code, expires: m.wireNow() + 300, command: `curl … | sh -s -- '${code}'` });
  const fields = shown.text.split(":");
  assert.equal(fields.length, 14);
  assert.deepEqual(fields.slice(0, 2), ["agents-control", "4"]);
  assert.equal(fields[9], "-");
  assert.equal(shown.command, `curl … | sh -s -- '${shown.text}'`);
  const state = await m.check(plane.lock.entries);
  assert.equal(fields[11], "alex");
  assert.equal(fields[12], String(state.count));
  assert.equal(Buffer.from(fields[13], "base64url").toString("hex"), hex(state.head));
  // The invite's key in the code is the private half of the invite on the lock.
  const invite = state.membersOf("invite")[0];
  const d = Buffer.from(fields[10], "base64url");
  assert.equal(d.length, 32);
  const jwk = { kty: "EC", crv: "P-256", d: fields[10], x: Buffer.from(invite.key.slice(1, 33)).toString("base64url"),
    y: Buffer.from(invite.key.slice(33)).toString("base64url") };
  await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  assert.ok(invite.expires > m.wireNow());

  // A browser that is not a signer gives the code back as it was.
  const web = plane.connect("BBBB-2222", "A browser");
  await web.lock.run();
  assert.equal((await web.lock.invite({ text: code, expires: 0 })).text, code);

  // Sealing: a client, a machine the lock names, and one it does not.
  const box = await machineAsks(plane, "h-box", "dev-3");
  await wait();
  await mac.lock.compare(box.request);
  await wait();
  await plane.answer("h-box", "dev-3", "unknown", "lock/joinReveal", { request: box.request, nonce: b64(box.nonce) });
  await wait(50);
  await mac.lock.approve(box.request);
  await wait(50);
  const { publicRaw: stranger } = await m.makeSigningKey();
  const recipients = [
    { id: "c:BBBB-2222", name: "A browser", publicKey: b64(stranger) },
    { id: "m:h-box", name: "dev-3", owner: "alex", publicKey: b64(box.key) },
    { id: "m:h-evil", name: "not mine", owner: "alex", publicKey: b64(stranger) },
  ];
  assert.deepEqual((await mac.lock.signed(recipients)).map((r) => r.id), ["c:BBBB-2222", "m:h-box"]);
  assert.deepEqual(mac.said, []);
});

test("a host code with an invite is the version 4 text Go reads, as AgentsKit makes it (#3491)", () => {
  const code = "agents-control:2:h:-:KEY:SECRET:https%3A%2F%2Fx:-:Sam%27s";
  const pin = { person: "sam.p", count: 3, head: b64(new Uint8Array(32).fill(9)) };
  assert.equal(m.inviteCode(code, new Uint8Array(32).fill(7), pin),
    "agents-control:4:h:-:KEY:SECRET:https%3A%2F%2Fx:-:Sam%27s:-:BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc:sam.p:3:CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk");
  const client = code.replace(":h:", ":c:");
  assert.equal(m.inviteCode(client, new Uint8Array(32).fill(7), pin), client);
});

const recovery = JSON.parse(readFileSync(new URL("../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/lock/recovery.json", import.meta.url)));

test("the recovery key's text and its sealed key are Go's (#3493)", async () => {
  assert.equal(await m.recoveryText(bytes(recovery.secret)), recovery.text);
  for (const typed of [recovery.text, ...recovery.typed]) assert.equal(b64(await m.parseRecovery(typed)), recovery.secret);
  for (const typo of recovery.typos) await assert.rejects(m.parseRecovery(typo), (error) => error.typo === true);
  const state = await m.check(recovery.lock.entries);
  assert.equal(b64(state.recovery), recovery.public);
  const key = await m.openRecovery(bytes(recovery.secret), state.recovery, state.recoverySealed);
  // It signs as the lock's recovery key: Go's check takes what it signs.
  const laptop = await signer();
  const entry = await m.sign(key, state.recovery, { kind: "addClient", person: state.person, previous: b64(state.head), at: m.wireNow(), key: b64(laptop.publicRaw) });
  await state.add(entry);
  assert.ok(state.signer(laptop.publicRaw));
  await assert.rejects(m.openRecovery(await m.parseRecovery(recovery.other), state.recovery, state.recoverySealed), (error) => error.typo === false);
  // One made here opens with its own text.
  const made = await m.makeRecovery();
  await m.openRecovery(await m.parseRecovery(made.text.toLowerCase()), made.publicRaw, made.sealed);
});

test("a browser that lost every device adds itself with the recovery key, or starts a new lock (#3493)", async () => {
  const plane = controlPlane();
  const mac = plane.connect("AAAA-1111", "Mac");
  await mac.lock.run();
  const shown = mac.lock.recovery.value;
  assert.equal(shown.kind, "show");
  mac.lock.recoveryDismissed();
  assert.equal(mac.lock.recovery.value.kind, "none");

  // The Mac is lost. A new browser asks; nobody can approve it, so it types the key.
  const web = plane.connect("BBBB-2222", "A browser");
  await web.lock.run();
  await wait();
  assert.equal(web.lock.device.value.kind, "asking");
  assert.match(await web.lock.useRecoveryKey("not a key"), /typo/);
  assert.match(await web.lock.useRecoveryKey(recovery.other), /not your lock/);
  assert.equal(await web.lock.useRecoveryKey(shown.text.replace(/-/g, " ")), null);
  await wait(50);
  assert.equal(web.lock.device.value.kind, "member");
  const state = await m.check(plane.lock.entries);
  assert.ok(state.signer(web.keys.publicRaw ?? new Uint8Array(await crypto.subtle.exportKey("raw", web.keys.pair.publicKey))));
  // Its own request was approved by its addClient.
  assert.ok([...plane.requests.values()].every((r) => r.result));

  // Every device and the key lost: a third browser starts a new lock, with a new key.
  const fresh = plane.connect("CCCC-3333", "Another browser");
  await fresh.lock.run();
  await wait();
  await fresh.lock.startNewLock();
  await wait(50);
  assert.equal(fresh.lock.device.value.kind, "member");
  assert.equal(fresh.lock.recovery.value.kind, "show");
  assert.notEqual(fresh.lock.recovery.value.text, shown.text);
  const fresher = await m.check(plane.lock.entries);
  assert.equal(fresher.count, 2);
  assert.ok(fresher.signer(new Uint8Array(await crypto.subtle.exportKey("raw", fresh.keys.pair.publicKey))));
  // The browser that pinned the old lock refuses the new one.
  await web.lock.run();
  assert.equal(web.lock.device.value.kind, "broken");
  assert.deepEqual(fresh.said, []);
});

test("a lock with one client offers a recovery key until it is saved or skipped (#3493)", async () => {
  const plane = controlPlane();
  const mac = plane.connect("AAAA-1111", "Mac");
  await mac.lock.run();
  // The page closed before the key was saved: the next page offers a new one.
  const again = new model.MachineLock({
    call: (method, params) => plane.answer("AAAA-1111", "Mac", "browser", method, structuredClone(params)),
    keyRecord: async () => ({ client: "AAAA-1111" }), lockKey: async () => mac.keys.pair, saveLockKey: async () => {},
  }, mac.pins, () => {}, undefined, undefined, new model.MemoryRecoveryDone());
  await again.run();
  assert.equal(again.recovery.value.kind, "offer");
  await again.makeRecoveryKey();
  assert.equal(again.recovery.value.kind, "show");
  const state = await m.check(plane.lock.entries);
  assert.equal(state.count, 3);
  again.recoveryDismissed();
  await again.run();
  assert.equal(again.recovery.value.kind, "none");
});

test("a forget clears every lock pin and recovery mark, and nothing else (#3670)", () => {
  const items = new Map([
    ["agents-lock-pin", "{}"], ["agents-lock-pin:ana@example.com", "{}"], ["agents-lock-pin.0401020304050607", "{}"],
    ["agents-lock-pin.0401020304050607:ana@example.com", "{}"], ["agents-lock-pin.0401020304050607.recoveryDone:ana@example.com", "1"],
    ["agents-lock-recovery-done:ana@example.com", "1"], ["agents.drafts", "[]"], ["agents-lock-pinned-elsewhere", "x"],
  ]);
  const storage = {
    get length() { return items.size; },
    key: (i) => [...items.keys()][i] ?? null,
    removeItem: (key) => items.delete(key),
  };
  model.forgetPins(storage);
  assert.deepEqual([...items.keys()], ["agents.drafts", "agents-lock-pinned-elsewhere"]);
});

test("the page keeps its pins by control plane, so a re-pair to another starts from none (#3651)", async () => {
  const items = new Map();
  const before = globalThis.localStorage;
  globalThis.localStorage = {
    getItem: (key) => items.get(key) ?? null, setItem: (key, value) => items.set(key, String(value)),
    removeItem: (key) => items.delete(key), get length() { return items.size; }, key: (i) => [...items.keys()][i] ?? null,
  };
  try {
    // Two control planes' keys, base64url; the name is the first eight bytes, in hex, as on the Mac.
    const first = Buffer.from([4, 1, 2, 3, 4, 5, 6, 7, 8, 9]).toString("base64url");
    const second = Buffer.from([4, 9, 9, 9, 9, 9, 9, 9, 8, 9]).toString("base64url");
    assert.equal(model.pinName(first), "agents-lock-pin.0401020304050607");
    assert.equal(model.pinName(undefined), "agents-lock-pin");
    const page = (plane, control) => {
      const keys = { pair: null };
      const said = [];
      const lock = new model.MachineLock({
        call: (method, params) => plane.answer("AAAA-1111", "Web", "browser", method, structuredClone(params)),
        keyRecord: async () => ({ client: "AAAA-1111", control }),
        lockKey: async () => keys.pair, saveLockKey: async (pair) => { keys.pair = pair; },
      }, undefined, (error) => said.push(error.message));
      return { lock, said };
    };
    const one = page(controlPlane("alex"), first);
    await one.lock.run();
    assert.equal(one.lock.device.value.kind, "member");
    assert.equal(JSON.parse(items.get("agents-lock-pin.0401020304050607")).count, 2);
    assert.equal(items.has("agents-lock-pin"), false);
    // Another control plane, with a lock of its own: not the first one's pin, so not a fork.
    const two = page(controlPlane("alex"), second);
    await two.lock.run();
    assert.equal(two.lock.device.value.kind, "member", two.said.join("; "));
    assert.equal(JSON.parse(items.get("agents-lock-pin.0409090909090909")).count, 2);
    model.forgetPins();
    assert.deepEqual([...items.keys()], []);
  } finally {
    globalThis.localStorage = before;
  }
});

test("once paired, another control plane's pins go, and the page's own stay (#3750)", () => {
  const items = new Map([
    ["agents-lock-pin", "{}"], ["agents-lock-pin:ana@example.com", "{}"], ["agents-lock-pin.0401020304050607", "{}"],
    ["agents-lock-pin.0401020304050607:ana@example.com", "{}"], ["agents-lock-pin.0401020304050607.recoveryDone:ana@example.com", "1"],
    ["agents-lock-pin.0409090909090909", "{}"], ["agents-lock-pin.0409090909090909.recoveryDone:ana@example.com", "1"],
    ["agents-lock-recovery-done:ana@example.com", "1"], ["agents.drafts", "[]"], ["agents-lock-pinned-elsewhere", "x"],
  ]);
  const storage = {
    get length() { return items.size; },
    key: (i) => [...items.keys()][i] ?? null,
    removeItem: (key) => items.delete(key),
  };
  model.prunePins("agents-lock-pin", storage);
  assert.equal(items.size, 10, "with no control plane known, nothing goes");
  model.prunePins("agents-lock-pin.0401020304050607", storage);
  assert.deepEqual([...items.keys()], [
    "agents-lock-pin.0401020304050607", "agents-lock-pin.0401020304050607:ana@example.com",
    "agents-lock-pin.0401020304050607.recoveryDone:ana@example.com", "agents.drafts", "agents-lock-pinned-elsewhere",
  ]);
});
