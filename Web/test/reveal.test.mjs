// Reveal and Copy (#5112, #5116), as the window's SecretRevealTests: the page opens user/sealedSecret's copy with its
// own key, and nothing else does; a card shows its five parts; Accounts ▸ Details… gives Copy only for plain fields.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const r = await load("src/model/reveal.ts");
const s = await load("src/wire/sealing.ts");
const accounts = await load("src/model/accounts.ts");

async function pageKey(client) {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return { record: { privateKey: pair.privateKey, publicKey: pair.publicKey, client, control: "", paired: "" }, raw };
}

/** A link that answers as the control plane does, and keeps each request. */
function fakeLink(record, sealed, user = "ada") {
  const asked = [];
  return {
    asked,
    keyRecord: async () => record,
    call: async (method, params) => {
      asked.push([method, params]);
      if (method === "user/secretRecipients") return { recipients: [], user };
      if (method === "user/sealedSecret") return sealed;
      throw new Error(method);
    },
  };
}

test("reveal: the page opens its own copy, and another person's associated data does not open", async () => {
  const { record, raw } = await pageKey("aaaa-1111");
  const ad = s.userSecretAD("ada", s.clientRecipient(record.client), "GITLAB_TOKEN", 7, true);
  const envelope = await s.seal(raw, s.userSecretPurpose, ad, new TextEncoder().encode("glpat-x9Qe"));
  const sealed = { name: "GITLAB_TOKEN", version: 7, needsApproval: true, sealed: envelope };
  const request = { name: "GITLAB_TOKEN", purpose: "reveal", account: { service: "gitlab.com" } };
  const link = fakeLink(record, sealed);
  assert.equal(await r.revealSecret(link, request), "glpat-x9Qe");
  assert.deepEqual(link.asked.map(([m]) => m), ["user/secretRecipients", "user/sealedSecret"]);
  assert.deepEqual(link.asked[1][1], request);
  await assert.rejects(r.revealSecret(fakeLink(record, sealed, "kim"), request), r.RevealFailed);
  await assert.rejects(r.revealSecret(fakeLink(record, { ...sealed, needsApproval: false }), request), r.RevealFailed);
  assert.equal(r.revealFailure(new r.RevealFailed()), r.revealWords.didNotOpen);
});

test("reveal: a card shows its five parts and copies the digits", () => {
  const card = r.parseCard(JSON.stringify({ cvc: "123", expiry: "09/28", name: "Ada Example", number: "4242424242424242", zip: "94110" }));
  const parts = r.cardParts(card);
  assert.deepEqual(parts.map((p) => p.label), ["Card number", "Expiry", "CVC", "Name on card", "Billing ZIP"]);
  assert.equal(parts[0].text, "4242 4242 4242 4242");
  assert.equal(parts[0].value, "4242424242424242");
  assert.equal(r.parseCard("ghp_notacard"), null);
});

test("details: Copy only for the plain fields with a value", () => {
  const a = { service: "gitlab.com", address: "agentloops@example.com", username: "agentloops", plan: "Free", monthlyCostUsd: 0,
    twoFactor: "TOTP", issue: "#4303", tokenExpires: "2027-02-01", notes: "Password is in Secrets as GITLAB_PASSWORD.", secret: "GITLAB_TOKEN" };
  const identity = r.identityFields(a, "Agents' GitLab");
  assert.deepEqual(identity.map((f) => f.label), ["Service", "Address", "User name", "Description", "Plan", "Two-factor"]);
  assert.deepEqual(identity.filter((f) => f.copies).map((f) => f.label), ["Service", "Address", "User name"]);
  assert.equal(identity.find((f) => f.label === "Plan").text, "Free · $0 a month");
  assert.deepEqual(r.recordFields(a).map((f) => f.label), ["Notes", "Issue", "Projects"]);
  assert.equal(r.tokenExpiry(a, Date.parse("2025-11-13T00:00:00Z")), "2027-02-01 (in 445 d)");
  assert.deepEqual(r.auditAccount(a), { service: "gitlab.com", address: "agentloops@example.com" });
  assert.equal(accounts.accountOf(accounts.accountFields(a)).username, "agentloops");
  const row = { name: "GITLAB_TOKEN", updated: "", machines: [] };
  assert.deepEqual(r.named("GITLAB_TOKEN", [row]), { kind: "secret", row });
  assert.deepEqual(r.named("1Password", [row]), { kind: "elsewhere", text: "1Password" });
  assert.deepEqual(r.named(" ", [row]), { kind: "none" });
});
