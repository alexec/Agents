// Client sealing (#3397): the page makes Go's associated data byte for byte, opens what Go sealed
// (Fixtures/sealing/vectors.json, which TestTheSealingVectorsOpen and SealingTests read too), and
// what it seals opens again; a route's save seals every value to every recipient; sealing/work
// seals a copy for each recipient missing.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const s = await load("src/wire/sealing.ts");
const o = await load("src/model/orgSealing.ts");
const vectors = JSON.parse(readFileSync(new URL("../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/sealing/vectors.json", import.meta.url)));

const fromHex = (h) => Uint8Array.from(h.match(/../g), (b) => parseInt(b, 16));
const b64url = (bytes) => Buffer.from(bytes).toString("base64url");
const text = (bytes) => new TextDecoder().decode(bytes);

/** The vectors' key as this page keeps one: a non-extractable ECDH pair. */
async function vectorKey() {
  const raw = Buffer.from(vectors.publicKey, "base64");
  const jwk = { kty: "EC", crv: "P-256", x: b64url(raw.subarray(1, 33)), y: b64url(raw.subarray(33, 65)), d: b64url(fromHex(vectors.privateKey)) };
  const privateKey = await crypto.subtle.importKey("jwk", jwk, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const publicKey = await crypto.subtle.importKey("raw", raw, { name: "ECDH", namedCurve: "P-256" }, true, []);
  return { privateKey, publicKey };
}

async function adOf(v) {
  return v.item === "userSecret"
    ? s.userSecretAD(v.user, v.recipient, v.field, v.version)
    : s.orgRouteAD({ id: v.id, kind: v.kind, vendor: v.vendor, settings: v.settings }, v.recipient, v.field, v.version);
}

test("the associated data is Go's, and what Go sealed opens here", async () => {
  const key = await vectorKey();
  for (const v of vectors.vectors) {
    const ad = await adOf(v);
    assert.equal(text(ad), v.ad);
    const info = v.item === "userSecret" ? s.userSecretPurpose : s.orgRoutePurpose;
    assert.equal(text(await s.open({ ...key, client: "X" }, info, ad, v.sealed)), v.value);
    await assert.rejects(s.open({ ...key, client: "X" }, info, s.userSecretAD("kim", v.recipient, v.field, v.version), v.sealed));
  }
});

async function pageKey(client) {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return { record: { privateKey: pair.privateKey, publicKey: pair.publicKey, client, control: "", paired: "" },
    recipient: { id: s.clientRecipient(client), name: client, publicKey: Buffer.from(publicRaw).toString("base64") } };
}

test("a route sealed here opens for each recipient, and sealing/work seals it for one missing", async () => {
  const admin = await pageKey("aaaa-1111");
  const later = await pageKey("bbbb-2222");
  const route = { id: "acme", kind: "baseURL", vendor: "openai", settings: { address: "https://llm.acme.example" } };
  const values = await s.sealRoute(route, { apiKey: "sk-here" }, 3, [admin.recipient]);
  const mine = values[admin.recipient.id];
  const item = { item: "orgRoute", id: "acme", version: 3, kind: "baseURL", vendor: "openai", settings: route.settings, mine, missing: [later.recipient] };
  assert.deepEqual(await s.openItem(admin.record, item), { apiKey: "sk-here" });
  // A control plane that changed the address does not get the key sealed again.
  const moved = { ...item, settings: { address: "https://elsewhere.example" } };
  assert.deepEqual(await s.sealWork(admin.record, { items: [moved] }), []);
  const [add] = await s.sealWork(admin.record, { items: [item] });
  assert.equal(add.version, 3);
  assert.deepEqual(await s.openItem(later.record, { ...item, mine: add.values[later.recipient.id] }), { apiKey: "sk-here" });
});

test("a person's secret sealed here opens with the person and the version in it", async () => {
  const phone = await pageKey("cccc-3333");
  const values = await s.sealSecret("sam", "GITHUB_TOKEN", 7, "ghp_here", [phone.recipient]);
  const item = { item: "userSecret", id: "GITHUB_TOKEN", user: "sam", version: 7, mine: { value: values[phone.recipient.id] }, missing: [] };
  assert.deepEqual(await s.openItem(phone.record, item), { value: "ghp_here" });
  await assert.rejects(s.openItem(phone.record, { ...item, user: "kim" }));
  assert.equal(await s.fingerprint("sk-ant-org-0123456789abcdef"), "01ce2783");
});

test("a new route's id is the control plane's, and a save seals again only when the key goes elsewhere", async () => {
  assert.equal(o.routeIDFrom("Acme Bedrock"), "acme-bedrock");
  assert.equal(o.routeIDFrom("  Ünïcode -- Gateway!! "), "n-code-gateway");
  assert.equal(o.routeIDFrom("x".repeat(39) + " y"), "x".repeat(39));
  const base = { id: "acme", name: "Acme", kind: "baseURL", vendor: "openai", runtimes: ["codex"], settings: { address: "https://a.example" } };
  assert.equal(o.bindingChanged(base, { ...base, name: "Renamed", runtimes: ["codex", "opencode"] }), false);
  assert.equal(o.bindingChanged(base, { ...base, settings: { address: "https://b.example" } }), true);
  assert.equal(o.bindingChanged(base, { ...base, vendor: "anthropic" }), true);

  const admin = await pageKey("dddd-4444");
  const asked = [];
  const link = {
    keyRecord: async () => admin.record,
    call: async (method, params) => {
      asked.push(method);
      if (method === "orgRoutes/recipients") return { recipients: [admin.recipient] };
      if (method === "orgRoutes/sealed") {
        const values = await s.sealRoute({ id: "acme", kind: "baseURL", vendor: "openai", settings: base.settings }, { apiKey: "sk-kept" }, 4, [admin.recipient]);
        return { item: "orgRoute", id: "acme", version: 4, kind: "baseURL", vendor: "openai", settings: base.settings, mine: values[admin.recipient.id], missing: [] };
      }
      throw new Error(method + JSON.stringify(params));
    },
  };
  const kept = { route: { ...base, secretFields: ["apiKey"], sealVersion: 4 }, rev: "r1" };
  // A rename keeps the key as it is: nothing is sealed.
  assert.equal(await o.sealedFor(link, { ...base, name: "Renamed" }, kept, {}, ["apiKey"]), undefined);
  // A new address: the kept key, opened here, sealed again for the new address.
  const movedRoute = { ...base, settings: { address: "https://b.example" } };
  const sealed = await o.sealedFor(link, movedRoute, kept, {}, ["apiKey"]);
  assert.equal(sealed.sealVersion, 5);
  assert.equal(sealed.fingerprint.apiKey, await s.fingerprint("sk-kept"));
  const opened = await s.openItem(admin.record, { item: "orgRoute", id: "acme", version: 5, kind: "baseURL", vendor: "openai",
    settings: movedRoute.settings, mine: sealed.values[admin.recipient.id], missing: [] });
  assert.deepEqual(opened, { apiKey: "sk-kept" });
  assert.deepEqual(asked, ["orgRoutes/sealed", "orgRoutes/recipients"]);
  // With no copy here, it says what to do.
  const bare = { ...link, keyRecord: async () => null };
  assert.deepEqual(await o.sealedFor(bare, movedRoute, kept, {}, ["apiKey"]), { problem: o.noCopyHere });
});
