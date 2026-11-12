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
  // #4163: an agent's read of an account with Ask before use, with a secret's answers.
  const account = { name: "gitlab.com (a@example.com)", use: "account", place: "1a2b3c4d", call: "get" };
  assert.equal(words.secretUseTitle(account), "Wants to read gitlab.com (a@example.com)");
  assert.equal(words.secretUseWhere(account), "Account: manage_accounts get");
  assert.deepEqual(words.secretUseActions(account), ["once", "session", "always", "deny"]);
  // #4264: an agent's lease of the browser or the screen on a machine that asks.
  const browser = { name: "the browser", use: "browser", place: "Studio" };
  assert.equal(words.secretUseTitle(browser), "Wants to use the browser");
  assert.equal(words.secretUseWhere(browser), "Browser on Studio");
  assert.deepEqual(words.secretUseActions(browser), ["once", "session", "always", "deny"]);
  assert.equal(words.secretUseWhere({ name: "the screen", use: "screen", place: "Studio", app: "TextEdit" }), "Screen: TextEdit on Studio");
});

test("a secret's use has four answers, and a session's own secret no Always Approve", () => {
  const use = { name: "X", use: "fill", place: "a.com" };
  assert.deepEqual(words.secretUseActions(use).map((a) => words.secretUseWords[a]),
    ["Approve", "Approve for This Session", "Always Approve", "Deny"]);
  assert.deepEqual(words.secretUseActions({ ...use, sessionOnly: true }), ["once", "session", "deny"]);
});

test("an agent asks to turn on a workflow or approve a connector, with Approve and Deny only (#4538)", () => {
  const workflow = { name: "answer-a-sign-up-code", use: "workflow", place: "Agents" };
  assert.equal(words.secretUseTitle(workflow), "Wants to turn on answer-a-sign-up-code");
  assert.equal(words.secretUseWhere(workflow), "Workflow in Agents");
  assert.deepEqual(words.secretUseActions(workflow), ["once", "deny"]);
  const connector = { name: "email", use: "connector", place: "Agents", digest: "d1" };
  assert.equal(words.secretUseTitle(connector), "Wants to approve email");
  assert.equal(words.secretUseWhere(connector), "Connector in Agents");
  assert.deepEqual(words.secretUseActions(connector), ["once", "deny"]);
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
  assert.deepEqual(words.secretUseActions(use).map((a) => words.secretUseWords[a]), ["Approve", "Approve for 1 Hour", "Deny"]);
  assert.equal(words.secretUseWhere(use), "Terminal: zsh · Agents cannot tell a terminal from an agent outside its session.");
});

test("a session's secret uses are its chat's cards, Later's too; another's, a question's and a terminal's are not (#4918)", () => {
  const use = { name: "T", use: "fill", place: "a.com" };
  const first = { ...request(use), id: "1", askedBy: "S" };
  const later = { ...request(use), id: "2", askedBy: "S", deferred: { atMac: true } };
  const list = [first, { source: "question", kind: "decide", detail: {}, id: "3", askedBy: "S" },
    { ...request(use), id: "4", askedBy: "T" }, { ...request({ ...use, use: "terminal" }), id: "5" }, later];
  assert.deepEqual(words.secretUsesAskedBy(list, "S").map((r) => r.id), ["1", "2"]);
});
