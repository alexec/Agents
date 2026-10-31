// Console ▸ Sign-In (#1002, FR-030): presets, the provider form, and the page's words (model/orgSignIn.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const o = await load("src/model/orgSignIn.ts");

test("each preset fills its defaults (research R3)", () => {
  assert.equal(o.newProviderForm("entra").accountClaim, "oid");
  assert.equal(o.newProviderForm("okta").accountClaim, "sub");
  assert.equal(o.newProviderForm("googleWorkspace").issuer, "https://accounts.google.com");
  assert.equal(o.newProviderForm("okta").join, "invite");
  const typed = { ...o.newProviderForm("googleWorkspace"), name: "Acme" };
  const okta = o.withPreset(typed, "okta");
  assert.equal(okta.issuer, "", "Google's issuer goes with its preset");
  assert.equal(okta.name, "Acme");
  assert.equal(o.withPreset({ ...typed, issuer: "https://sso.acme.com" }, "oidc").issuer, "https://sso.acme.com");
});

test("a provider is saved only when the form is whole, and a secret is written only", () => {
  const form = { ...o.newProviderForm("okta"), name: "Acme Okta", issuer: "https://acme.okta.com", clientID: "0oa1" };
  assert.match(o.providerOf(form).problem, /client secret/);
  const made = o.providerOf({ ...form, secret: " s3cret " });
  assert.equal(made.secret, "s3cret");
  assert.equal(made.provider.id, "");
  assert.deepEqual(made.provider.scopes, ["openid", "email", "profile", "offline_access"]);
  const old = { ...made.provider, id: "acme-okta", redirectURI: "https://cp.acme.com/v1/oidc/callback", order: 2 };
  const edited = o.providerOf({ ...form, name: "Acme" }, old);
  assert.equal(edited.secret, undefined, "an empty secret keeps the one there is");
  assert.equal(edited.provider.id, "acme-okta");
  assert.equal(edited.provider.order, 2);
  assert.equal(edited.provider.redirectURI, undefined);
  assert.match(o.providerOf({ ...form, issuer: "http://acme" }).problem, /https/);
  assert.match(o.providerOf({ ...form, name: "" }).problem, /name/);
});

test("Entra needs its tenant, from the field or the issuer", () => {
  const tenant = "11111111-2222-3333-4444-555555555555";
  const form = { ...o.newProviderForm("entra"), name: "Acme", clientID: "c", secret: "s", issuer: `https://login.microsoftonline.com/${tenant}/v2.0` };
  assert.equal(o.providerOf(form).provider.tenant, tenant);
  assert.match(o.providerOf({ ...form, issuer: "https://login.microsoftonline.com/common/v2.0" }).problem, /tenant/);
  assert.equal(o.providerOf(form).provider.accountClaim, "oid");
});

test("order, Check, domains, SCIM and tokens in words", () => {
  assert.deepEqual(o.moved(["a", "b", "c"], "b", -1), ["b", "a", "c"]);
  assert.deepEqual(o.moved(["a", "b"], "a", -1), ["a", "b"]);
  assert.match(o.checkWords("Acme", { ok: true, missing: [], jwksKeys: 2, redirectURI: "" }), /2 signing keys/);
  assert.match(o.checkWords("Acme", { ok: false, missing: ["PKCE S256"], jwksKeys: 1, redirectURI: "" }), /lacks PKCE S256/);
  assert.equal(o.scimBaseURL("https://cp.acme.com:8443/v1/oidc/callback"), "https://cp.acme.com:8443/scim/v2/");
  assert.equal(o.scimBaseURL(undefined), undefined);
  assert.match(o.domainWords({ domain: "acme.com", provider: "p", state: "notProved", txtName: "", txtValue: "", sendHere: false, require: false }), /TXT/);
  assert.match(o.previewWords("acme.com", "Acme Okta", []), /Nobody/);
  assert.match(o.previewWords("acme.com", "Acme Okta", [{ user: "u", name: "Bea", signIns: [{ provider: "google", account: "1", email: "bea@acme.com" }] }]),
    /• Bea: bea@acme\.com/);
  const at = 800000000;
  const t = { id: "t", provider: "p", name: "Okta", made: { by: { user: "u", userName: "Alex" }, at } };
  assert.match(o.tokenWords(t), /^Made by Alex .* · not used yet$/);
  assert.match(o.tokenWords({ ...t, lastUse: { at, address: "10.0.0.4" } }), /from 10\.0\.0\.4/);
  assert.match(o.tokenWords({ ...t, revoked: { by: t.made.by, at } }), /revoked/);
});
