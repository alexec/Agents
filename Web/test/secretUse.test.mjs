import assert from "node:assert/strict";
import { test } from "node:test";
import { load } from "./load.mjs";

const words = await load("src/model/secretUse.ts");

const request = (secretUse) => ({ source: "secretUse", kind: "approve", detail: { secretUse } });

test("a secret's use says which secret and where it goes, never its value (#4017)", () => {
  const fill = words.secretUseOf(request({ name: "GITLAB_PASSWORD", use: "fill", place: "gitlab.com" }));
  assert.equal(words.secretUseTitle(fill), "Wants to use GITLAB_PASSWORD");
  assert.equal(words.secretUseWhere(fill), "Fill on gitlab.com");
  assert.equal(words.secretUseWhere({ name: "X", use: "ci", place: "alexec/agents" }), "CI secret in alexec/agents");
});

test("a secret's use has four answers, and a session's own secret no Allow always", () => {
  const use = { name: "X", use: "fill", place: "a.com" };
  assert.deepEqual(words.secretUseActions(use).map((a) => words.secretUseWords[a]),
    ["Allow Once", "Allow for This Session", "Allow Always", "Deny"]);
  assert.deepEqual(words.secretUseActions({ ...use, sessionOnly: true }), ["once", "session", "deny"]);
});

test("another request is not a secret's use", () => {
  assert.equal(words.secretUseOf({ source: "question", kind: "decide", detail: {} }), undefined);
});
