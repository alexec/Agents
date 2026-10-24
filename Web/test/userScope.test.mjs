// Secrets follow the person across machines; fixed-scope settings have no switch here.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const u = await load("src/model/userScope.ts");

test("user scope: a secret's row says where it is, and a removed machine it was on", () => {
  assert.equal(u.machines({ machines: [] }), "On no machine yet");
  assert.equal(u.machines({ machines: ["a"] }), "On 1 machine");
  assert.equal(u.machines({ machines: ["a", "b"] }), "On 2 machines");
  assert.equal(u.leftOn({}), null);
  assert.match(u.leftOn({ leftOn: [{ host: "b", name: "Sam's box", at: "2026-10-21T15:00:00Z" }] }), /^It was on Sam's box, which was removed/);
  assert.equal(u.secretsLeft({ host: "b", name: "Sam's box", secrets: ["A", "B"] }),
    "Sam's box was removed with these secrets on it: A, B. Change them where they were issued.");
});

test("user scope: a secret's name is an environment variable's", () => {
  assert.equal(u.isSecretName("GITHUB_TOKEN"), true);
  assert.equal(u.isSecretName("github_token"), false);
  assert.equal(u.isSecretName("../X"), false);
  assert.equal(u.isSecretName(""), false);
});
