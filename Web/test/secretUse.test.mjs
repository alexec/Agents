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

test("a Linux machine's allow goes signed over what Go's Approval reads, and a deny does not (#4149)", () => {
  const use = { name: "TOKEN", use: "ci", place: "alexec/agents", needsSignature: true };
  assert.equal(words.secretUseSigns(use, "once"), true);
  assert.equal(words.secretUseSigns(use, "deny"), false);
  assert.equal(words.secretUseSigns({ ...use, needsSignature: undefined }, "always"), false);
  assert.deepEqual(JSON.parse(words.secretUseApprovalParams("R-1", use, "session")),
    { request: "R-1", name: "TOKEN", use: "ci", place: "alexec/agents", action: "session" });
  assert.equal(words.answerElsewhere, "Answer on the Mac or the Remote");
});

test("a terminal's agents-secret has no session: once, for 1 hour or deny, and its line says the gap (#4179)", () => {
  const terminal = { ...request({ name: "PLAIN_KEY", use: "terminal", place: "zsh" }), askedBy: undefined };
  assert.equal(words.isTerminalRequest(terminal), true);
  assert.equal(words.isTerminalRequest({ ...terminal, askedBy: "A-1" }), false);
  assert.equal(words.isTerminalRequest(request({ name: "X", use: "fill", place: "a.com" })), false);
  const use = words.secretUseOf(terminal);
  assert.deepEqual(words.secretUseActions(use).map((a) => words.secretUseWords[a]), ["Allow Once", "Allow for 1 Hour", "Deny"]);
  assert.equal(words.secretUseWhere(use), "Terminal: zsh · Agents cannot tell a terminal from an agent outside its session.");
});
