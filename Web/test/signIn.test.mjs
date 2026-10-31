import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const s = await load("src/model/signIn.ts");
const request = (over = {}) => ({ request: "r1", name: "Sam's iPhone", kind: "iPhone", provider: "github", login: "sam", code: "K7M2QX",
  expires: 4102444800 - 978307200, ...over });

test("one card per GitHub sign-in, gone when decided or past its end", () => {
  let list = s.withSignIn([], request());
  list = s.withSignIn(list, request({ code: "AAAAAA" }));
  assert.equal(list.length, 1);
  assert.equal(list[0].code, "AAAAAA");
  list = s.withSignIn(list, request({ request: "r2", expires: 0 }));
  assert.equal(s.liveSignIns(list).length, 1);
  assert.equal(s.withoutSignIn(list, "r1").length, 1);
});

test("the words are the window's", () => {
  assert.equal(s.account(request()), "GitHub · sam");
  assert.equal(s.row({ provider: "google", account: "1", email: "sam@example.com" }), "Google · sam@example.com");
  assert.equal(s.row({ provider: "github", account: "42", login: "sam" }), "GitHub · sam");
  assert.equal(s.row({ provider: "local", account: "k" }), "This control plane");
  assert.equal(s.isOutside("local"), false);
  assert.deepEqual(s.list(" example.com, ,example.org "), ["example.com", "example.org"]);
});

test("the org words are the window's (#1002)", () => {
  assert.equal(s.orgButton("Okta"), "Sign in with Okta");
  assert.equal(s.useEmail, "Use an Email");
  assert.equal(s.emailPlaceholder, "you@example.com");
  assert.equal(s.noOrgForEmail, "No organisation sends people with that email here. Sign in another way, or use a code.");
  assert.equal(s.suspendedLine, "Your organisation's sign-in turned your access off.");
  assert.equal(s.suspendedFoot, "Ask your IT team to turn it on again. This browser stays paired, and connects again when they do.");
  assert.equal(s.required("Okta"), "Your organisation asks you to sign in with Okta.");
  assert.equal(s.managedBy("Okta"), "Managed by Okta");
  assert.equal(s.waitingFirstSignIn, "Waiting for first sign-in");
  assert.equal(s.suspendedBy("Okta"), "Suspended by Okta");
  assert.equal(s.setBy("Okta"), "Set by Okta");
});

test("orgSignInRequired names its provider; other failures name none", () => {
  assert.deepEqual(s.requiredProvider(-32077, { provider: "okta", name: "Okta" }), { id: "okta", name: "Okta", order: 0 });
  assert.deepEqual(s.requiredProvider(-32077, { provider: "okta" }), { id: "okta", name: "okta", order: 0 });
  assert.equal(s.requiredProvider(-32077, null), null);
  assert.equal(s.requiredProvider(-32078, { provider: "okta", name: "Okta" }), null);
});

test("org providers go in their order, and a name falls back to the id", () => {
  const list = [{ id: "b", name: "Entra", order: 2 }, { id: "a", name: "Okta", order: 1 }];
  assert.deepEqual(s.byOrder(list).map((p) => p.id), ["a", "b"]);
  assert.deepEqual(s.byOrder(undefined), []);
  const names = s.orgNames(list);
  assert.equal(s.orgName("a", names), "Okta");
  assert.equal(s.orgName("gone", names), "gone");
});

test("the provider's return is read from the fragment, and nothing else is", () => {
  assert.deepEqual(s.oidcReturn("#oidc-ticket=T1"), { ticket: "T1" });
  assert.deepEqual(s.oidcReturn("#oidc-error=access_denied&oidc-message=You+said+no."),
    { error: "access_denied", message: "You said no." });
  assert.equal(s.oidcErrorWords({ error: "access_denied", message: "You said no." }), "You said no.");
  assert.match(s.oidcErrorWords({ error: "access_denied" }), /access_denied/);
  for (const hash of ["", "#/", "#/h/mac/p/x", "#code=abc", "#oidc-", "#oidc-other=1"]) assert.equal(s.oidcReturn(hash), null, hash);
});

test("a pending sign-in lasts 10 minutes, and an email needs an @ and a dot", () => {
  const made = 1_000_000;
  assert.equal(s.pendingLive(made, made + 9 * 60_000), true);
  assert.equal(s.pendingLive(made, made + 10 * 60_000), false);
  assert.equal(s.pendingLive(made, made - 1), false);
  assert.equal(s.looksLikeEmail(" sam@example.com "), true);
  assert.equal(s.looksLikeEmail("sam@example"), false);
  assert.equal(s.looksLikeEmail("sam"), false);
});

test("the words name the place the page lists Sign-ins in (#2256)", async () => {
  const { scopeTitles } = await load("src/views/Settings.tsx");
  const { sectionsIn } = await load("src/views/settings/sections.ts");
  assert.equal(s.signInsPlace, `${scopeTitles.controlPlane} ▸ ${s.signInsTitle}`);
  assert.ok(sectionsIn("controlPlane", { person: { value: { role: "member" } } }).some((each) => each.name === "signIns"));
  for (const words of [s.signInsFoot, s.signInsNone, s.paneFoot]) {
    assert.ok(words.includes(s.signInsPlace), words);
    assert.ok(!words.includes("You ▸"), words);
  }
});
