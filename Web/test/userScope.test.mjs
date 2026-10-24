// The user scope (#1760, #2157): the same words as UserScopeWords in Packages/AgentsKit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const u = await load("src/model/userScope.ts");

test("user scope: a part follows the person only when the control plane keeps it", () => {
  assert.equal(u.follows(null, "costLimits"), false);
  assert.equal(u.follows({ costLimits: null }, "costLimits"), false);
  assert.equal(u.follows({ costLimits: { dailyTokens: 5 } }, "costLimits"), true);
  assert.equal(u.partState({ resources: [] }, "resources"), "All your machines");
  assert.equal(u.partState({}, "mcpServers"), "Each machine its own");
  assert.deepEqual(u.parts, ["runtimes", "costLimits", "resources"]);
});

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

test("user scope: the parts say a part is turned on in its own pane on the Mac (#2069, #2157)", () => {
  assert.match(u.partsFoot, /^Turn on runtime choices, cost limits or resources in their own pane on the Mac\./);
  assert.equal(u.stopTitle("resources"), "Resources: each machine its own?");
});
