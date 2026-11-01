// The organisation's policy (#998): its words, as OrgPolicyWordsTests checks them in Swift, the
// policyRefused error, and Console ▸ Policy's form, preview and warnings.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const o = await load("src/model/orgPolicy.ts");
const { CallFailed } = await load("src/wire/link.ts");

const priya = { user: "u-priya", userName: "Priya" };
const policy = (rules = {}) => ({ version: 4, issued: 700000000, changedBy: priya, requires: ["host.policy/1"], ...rules });
const machine = (name, capabilities, running) => ({ host: { id: name, name, platform: "", version: "", state: "online", reach: "", capabilities },
  ownerName: "", bot: false, running });

test("a policy with no rules says none", () => {
  assert.deepEqual(o.rules(policy()), []);
});

test("each rule set is said in its order, as on the Mac and the Remote", () => {
  const rules = o.rules(policy({
    permissionMode: "approveForMe", sandbox: "required",
    runtimes: { codex: {}, claude: { models: ["claude-sonnet-*"] } },
    marketplaces: { allowed: ["acme", "github"], customServers: "refuse" },
    budgets: { daily: 40, dailyTokens: 50000, perAgent: 2.5, allowUnmetered: ["cursor"], raises: [] },
    helpers: { mostRunning: 3, mostNotArchived: 10 },
    environment: { passThrough: ["OPENAI_*", "ANTHROPIC_*"] },
    notices: { antigravityTerms: "refuse" },
    requireFollowing: true,
  }));
  assert.deepEqual(rules.map((r) => r.title), ["Modes", "Command sandbox", "Runtimes", "Marketplaces", "MCP servers added by hand",
    "Budget", "Unmetered runtimes", "Helper sessions", "Variables passed to runtimes", "Antigravity’s terms", "Machines"]);
  assert.deepEqual(rules.map((r) => r.words), [
    "Up to Approve for me", "Required", "Only Claude (claude-sonnet-*), Codex", "Only acme, github", "Not allowed",
    "$40 a day, 50,000 tokens a day, $2.50 an agent", "Allowed: Cursor", "At most 3 running and 10 not archived in a folder",
    "Only ANTHROPIC_*, OPENAI_*", "Antigravity is not allowed", "A machine that does not follow this policy starts no agent",
  ]);
});

test("empty lists allow nothing, and a budget with no number is no rule", () => {
  const words = Object.fromEntries(o.rules(policy({ runtimes: {}, environment: { passThrough: [] },
    budgets: { allowUnmetered: [], raises: [] } })).map((r) => [r.name, r.words]));
  assert.equal(words.runtimes, "None");
  assert.equal(words["environment.passThrough"], "None");
  assert.equal(words.budgets, undefined);
});

test("the kill switch names how many agents run", () => {
  assert.match(o.stopMessage(3), /^This stops the 3 agents running now,/);
  assert.match(o.stopMessage(1), /^This stops the 1 agent running now,/);
  assert.match(o.stopMessage(0), /^No agent is running now\./);
  assert.match(o.stopMessage(undefined), /^This stops every agent running now on every machine,/);
  assert.equal(o.runningAgents([machine("a", [], 2), machine("b", [], undefined), machine("c", [], 1)]), 3);
  assert.equal(o.runningAgents([machine("a", [], undefined)]), undefined);
});

test("the last change names who and when", () => {
  const issued = new Date(2026, 9, 21, 14, 5);
  assert.equal(o.changed(policy(), issued, new Date(2026, 9, 21, 18, 0)), "Version 4, changed by Priya at 14:05.");
  assert.equal(o.changed(policy(), issued, new Date(2026, 9, 23)), "Version 4, changed by Priya on 21 Oct at 14:05.");
  assert.equal(o.actorName({ user: "u-sam" }), "u-sam");
});

test("a mark and a policyRefused error say the line", () => {
  assert.equal(o.line({ by: "organisation", rule: "permissionMode", words: "Your organisation allows modes up to Approve for me." }),
    "Set by your organisation. Your organisation allows modes up to Approve for me.");
  const refusal = o.refusalOf(new CallFailed(-32076, "x", { reason: "policy", rule: "runtimes", words: "Your organisation does not allow Gemini." }));
  assert.equal(refusal.rule, "runtimes");
  assert.equal(o.refusalLine(refusal), "Set by your organisation. Your organisation does not allow Gemini.");
  assert.equal(o.refusalLine({ reason: "noPolicy", words: "Agents Host has no policy from your organisation. Connect to the network." }),
    "Agents Host has no policy from your organisation. Connect to the network.");
  assert.equal(o.refusalOf(new CallFailed(-32602, "no")), null);
  assert.equal(o.refusalOf(new Error("no")), null);
});

test("a limit from your own or a folder's layer says that layer, not the organisation (#3150)", () => {
  const you = { kind: "you", name: "You" };
  const folder = { kind: "folder", name: "web", folder: "/src/web" };
  assert.equal(o.line({ by: "you", rule: "modeCeiling", words: "At most Approve.", layer: you }), "Set by you. At most Approve.");
  assert.equal(o.line({ by: "folder", rule: "modeCeiling", words: "At most Approve.", layer: folder }), "Set by this folder. At most Approve.");
  assert.equal(o.refusalLine({ reason: "policy", words: "At most Approve.", layer: you }), "Set by you. At most Approve.");
  assert.equal(o.refusalLine({ reason: "policy", words: "At most Approve.", layer: folder }), "Set by this folder. At most Approve.");
  assert.equal(o.refusalLine({ reason: "policy", words: "At most Approve.", layer: { kind: "organisation", name: "Acme" } }),
    "Set by your organisation. At most Approve.");
});

test("no policy is a form that sets nothing, and back to a policy with no rules", () => {
  const form = o.formOf(undefined);
  assert.equal(form.limitRuntimes, false);
  assert.ok(Object.values(form.runtimes).every((r) => r.on));
  const made = o.policyOf(form, undefined, priya);
  assert.deepEqual(o.rules(made.policy), []);
});

test("a policy goes to the form and back unchanged, keeping what the form does not show", () => {
  const p = policy({
    permissionMode: "bypassPermissions", sandbox: "required",
    runtimes: { claude: { models: ["claude-sonnet-*"], reach: ["orgKey", "gateway"] }, codex: {} },
    marketplaces: { allowed: ["acme"], customServers: "allow" },
    budgets: { daily: 40, dailyTokens: 50000, allowUnmetered: ["grok"], raises: [{ user: "u-sam", day: "2026-10-22", daily: 60, by: priya }] },
    helpers: { mostRunning: 3 },
    environment: { passThrough: ["OPENAI_*"] },
    stopAll: { on: true, by: priya, at: 700000100 },
    notices: { antigravityTerms: "accepted" },
    futureRule: { kept: true },
  });
  const back = o.policyOf(o.formOf(p), p, priya).policy;
  assert.deepEqual(back, p);
});

test("edits in the form change the policy, and a field that is not a number is said", () => {
  const p = policy({ runtimes: { claude: {}, codex: {} } });
  const form = o.formOf(p);
  form.mode = "approveForMe";
  form.runtimes.codex.on = false;
  form.runtimes.claude.models = "claude-sonnet-*, claude-haiku-*";
  form.daily = "$1,200.50";
  form.limitPassThrough = true;
  form.passThrough = "ANTHROPIC_*  OPENAI_API_KEY";
  const made = o.policyOf(form, p, priya).policy;
  assert.equal(made.permissionMode, "approveForMe");
  assert.deepEqual(made.runtimes, { claude: { models: ["claude-sonnet-*", "claude-haiku-*"] } });
  assert.equal(made.budgets.daily, 1200.5);
  assert.deepEqual(made.environment.passThrough, ["ANTHROPIC_*", "OPENAI_API_KEY"]);
  assert.deepEqual(o.changes(p, made), [
    "Modes: Up to Approve for me",
    "Runtimes: Only Claude, Codex → Only Claude (claude-sonnet-*, claude-haiku-*)",
    "Budget: $1200.50 a day",
    "Variables passed to runtimes: Only ANTHROPIC_*, OPENAI_API_KEY",
  ]);
  form.dailyTokens = "lots";
  assert.equal(o.policyOf(form, p, priya).problem, "“lots” is not a number of tokens.");
  form.dailyTokens = "";
  form.passThrough = "NOT-A-NAME";
  assert.match(o.policyOf(form, p, priya).problem, /^“NOT-A-NAME” is not a variable name/);
});

test("a rule taken out says so in the preview", () => {
  assert.deepEqual(o.changes(policy({ sandbox: "required" }), policy()), ["Command sandbox: no longer set"]);
  assert.deepEqual(o.changes(undefined, policy({ requireFollowing: true })), ["Machines: A machine that does not follow this policy starts no agent"]);
});

test("the warnings say what the policy refuses before it is saved", () => {
  assert.deepEqual(o.warnings(policy({ runtimes: {} }), []), ["No runtime is left: nobody can start an agent."]);
  assert.deepEqual(o.warnings(policy({ sandbox: "required", runtimes: { claude: {}, copilot: {} } }), []),
    ["A required sandbox refuses Copilot: it has no command sandbox the app can turn on."]);
  assert.deepEqual(o.warnings(policy({ sandbox: "required", runtimes: { cursor: {} } }), []), [
    "A required sandbox refuses Cursor: it has no command sandbox the app can turn on.",
    "No runtime is left with a command sandbox: nobody can start an agent.",
  ]);
  assert.deepEqual(o.warnings(policy({ budgets: { daily: 5, allowUnmetered: ["grok"], raises: [] } }), []),
    ["The budget refuses Antigravity and Cursor: their turns report neither a cost nor tokens. Allow them by name to keep them."]);
  assert.deepEqual(o.warnings(policy(), [machine("Sam’s Mac", ["host.policy/1"]), machine("old-box", [])]),
    ["1 machine does not follow policy: old-box. Update Agents Host on it."]);
  assert.deepEqual(o.warnings(policy({ requireFollowing: true }), [machine("a", []), machine("b", undefined)]),
    ["2 machines do not follow policy and will start no agent: a, b. Update Agents Host on them."]);
});

test("Console ▸ Machines says whether each machine follows the policy", () => {
  const p = policy();
  assert.equal(o.followsWords(machine("a", ["host.policy/1"]), undefined, {}), null);
  assert.equal(o.followsWords(machine("a", []), p, {}), "Does not follow policy");
  assert.equal(o.followsWords(machine("a", ["host.policy/1"]), p, {}), "Has no policy yet");
  assert.equal(o.followsWords(machine("a", ["host.policy/1"]), p, { a: 4 }), "Follows policy v4");
  assert.equal(o.followsWords(machine("a", ["host.policy/1"]), p, { a: 3 }), "Has v3 of v4");
});

// Slice 2b (T030–T034): what each client draws from the machine's marks and state.
test("a host's policy state says why the composer cannot send, as on the Mac and the Remote", () => {
  assert.equal(o.startsNothing(undefined), false);
  assert.equal(o.composerReason({ stopAll: false, noPolicy: false }), null);
  const stopped = { version: 3, stopAll: true, noPolicy: false,
    refusal: { reason: "stopAll", rule: "stopAll", words: "Your organisation has stopped all agent work." } };
  assert.equal(o.startsNothing(stopped), true);
  assert.equal(o.composerReason(stopped), "Set by your organisation. Your organisation has stopped all agent work.");
  const lost = { stopAll: false, noPolicy: true,
    refusal: { reason: "noPolicy", words: "Agents Host has no policy from your organisation. Connect to the network." } };
  assert.equal(o.composerReason(lost), "Agents Host has no policy from your organisation. Connect to the network.");
});

test("the organisation's budgets are rows on Cost, as on the Mac and the Remote", () => {
  const money = (amount, currency) => `${currency} ${amount}`;
  assert.deepEqual(o.budgetRows(undefined, money), []);
  const rows = o.budgetRows({ daily: { amount: 40, currency: "USD" }, dailyTokens: 50000 }, money);
  assert.deepEqual(rows.map((r) => [r.title, r.words]), [["Per day", "USD 40"], ["Tokens per day", "50,000 tokens"]]);
});

test("each runtime's ways to the model and Antigravity's terms go to the form and back (#999)", () => {
  const p = policy({ runtimes: { claude: { reach: ["orgKey", "gateway"] }, codex: { reach: ["orgKey"] } }, notices: { antigravityTerms: "accepted" } });
  const form = o.formOf(p);
  assert.equal(form.reach.claude, "org");
  assert.equal(form.antigravityTerms, "accepted");
  // A rule the form does not name (org key alone) is kept while its choice is not changed.
  assert.deepEqual(o.policyOf(form, p, priya).policy, p);
  form.reach.claude = "signIn";
  form.antigravityTerms = "show";
  const made = o.policyOf(form, p, priya).policy;
  assert.deepEqual(made.runtimes.claude.reach, ["signIn"]);
  assert.equal(made.notices, undefined);
  const words = Object.fromEntries(o.rules(p).map((r) => [r.title, r.words]));
  assert.equal(words["Claude reaches the model by"], "Org key or gateway only");
  assert.equal(words["Codex reaches the model by"], "Org key only");
});

test("a reach rule with no runtime list names every runtime, so none is refused", () => {
  const form = o.formOf(undefined);
  form.reach.claude = "org";
  const made = o.policyOf(form, undefined, priya).policy;
  assert.deepEqual(Object.keys(made.runtimes).sort(), [...o.runtimeIDs].sort());
  assert.deepEqual(made.runtimes.claude.reach, ["orgKey", "gateway"]);
  assert.equal(made.runtimes.codex.reach, undefined);
});

test("the org path with no route that serves it is warned of", () => {
  const p = policy({ runtimes: { claude: { reach: ["orgKey", "gateway"] }, codex: {} } });
  assert.deepEqual(o.warnings(p, [], []),
    ["Claude can reach the model only by an org key or gateway, and no route in Model Access serves it: nobody can start Claude."]);
  assert.deepEqual(o.warnings(p, [], [{ runtimes: ["claude"] }]), []);
});

test("every runtime named only for its ways to the model says Every runtime", () => {
  const runtimes = Object.fromEntries(o.runtimeIDs.map((id) => [id, id === "claude" ? { reach: ["signIn"] } : {}]));
  assert.equal(o.rules(policy({ runtimes }))[0].words, "Every runtime");
});
