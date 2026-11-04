// Agents ▸ Policy's words and rows (#2957, T039), as PolicyLayersWordsTests checks them in Swift: the banner, which
// values a cap dims, and setting a rule on your layer; a folder's layer, the Stopped by a policy card and a waiting
// folder change's buttons (slice 5).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/policyLayers.ts");
const row = (rule) => p.rows.find((r) => r.rule === rule);

test("every rule of the spec has a row in one of the five sections", () => {
  assert.deepEqual(new Set(p.rows.map((r) => r.rule)), new Set(["permissionMode", "permissionRequests", "sandbox",
    "budgets.perAgent", "budgets.daily", "budgets.perAgentTokens", "budgets.dailyTokens", "helpers.mostRunning",
    "helpers.mostNotArchived", "workflows.mostOn", "noticeLimits.burst", "noticeLimits.waitMinutes", "archiveMyChats",
    "runtimes", "marketplaces.allowed", "marketplaces.customServers", "environment"]));
  assert.deepEqual(p.sections.map((s) => p.sectionTitles[s]), ["Permissions", "Money", "Work at once", "Your attention", "Tools"]);
});

test("the banner names the organisation or says you set every limit", () => {
  assert.equal(p.banner({ organisation: "Acme", rules: [], foldersWithRules: [], behind: [] }), "Acme sets limits above yours");
  assert.equal(p.banner({ rules: [], foldersWithRules: [], behind: [] }), "You set every limit");
  assert.equal(p.foldersLine(0), "No folder has its own rules.");
  assert.equal(p.foldersLine(1), "1 folder has its own rules.");
  assert.equal(p.foldersLine(3), "3 folders have their own rules.");
});

test("a cap dims only the looser values", () => {
  const mode = row("permissionMode");
  assert.ok(p.isLooser(mode, "bypassPermissions", "approveForMe"));
  assert.ok(!p.isLooser(mode, "approveForMe", "approveForMe"));
  assert.ok(!p.isLooser(mode, "plan", "approveForMe"));
  assert.ok(!p.isLooser(mode, "bypassPermissions", undefined));
  assert.ok(p.isLooser(row("helpers.mostRunning"), 5, 3));
  assert.ok(p.isLooser(row("noticeLimits.waitMinutes"), 5, 10));
  assert.ok(!p.isLooser(row("noticeLimits.waitMinutes"), 30, 10));
  assert.ok(p.isLooser(row("budgets.daily"), { amount: 50, currency: "USD" }, { amount: 40, currency: "USD" }));
  assert.ok(p.isLooser(row("archiveMyChats"), true, false));
});

test("setting a rule keeps only the rules the layer sets", () => {
  let rules = p.setting({}, "budgets.daily", { amount: 40, currency: "USD" });
  assert.deepEqual(rules, { budgets: { daily: { amount: 40, currency: "USD" } } });
  assert.deepEqual(p.ruleValue(rules, "budgets.daily"), { amount: 40, currency: "USD" });
  rules = p.setting(rules, "budgets.daily", undefined);
  assert.deepEqual(rules, {});
  rules = p.setting(rules, "archiveMyChats", true);
  assert.deepEqual(rules, {});
  rules = p.setting(rules, "archiveMyChats", false);
  assert.deepEqual(rules, { archiveMyChats: false });
  rules = p.setting(rules, "permissionMode", "ask");
  assert.equal(rules.permissionMode, "ask");
});

test("choices say the machine's words", () => {
  assert.equal(p.choice("permissionMode", "approveForMe"), "Approve for me");
  assert.equal(p.choice("permissionRequests", "default"), "Ask me");
  assert.equal(p.choice("sandbox", "off"), "Off allowed");
  assert.equal(p.count("noticeLimits.waitMinutes", 120), "2 hours");
});

test("your value under a cap is kept, and a folder is named by its file", () => {
  assert.ok(p.yoursIsKept({ rule: "permissionMode", value: "approveForMe", words: "Approve for me", layers: [
    { layer: { kind: "organisation", name: "Acme" }, value: "approveForMe", words: "Approve for me", kept: false },
    { layer: { kind: "you", name: "You" }, value: "bypassPermissions", words: "Bypass Permissions", kept: true },
  ] }));
  assert.equal(p.layerLine({ kind: "folder", name: "payments-api", folder: "/p" }), "payments-api (.agents/policy.json)");
});

test("an empty field is no limit and text that is no amount saves nothing", () => {
  assert.equal(p.moneyValue(""), undefined);
  assert.deepEqual(p.moneyValue("$40"), { amount: 40, currency: "USD" });
  assert.equal(p.moneyValue("forty"), null);
  assert.equal(p.tokensValue("2,000,000"), 2000000);
  assert.equal(p.tokensValue("0"), null);
});

test("a folder row that sets nothing is the same as yours, with your value", () => {
  const mode = row("permissionMode");
  const rule = { rule: "permissionMode", value: "ask", words: "Ask", cap: "ask", capLine: "Your policy: at most Ask", layers: [
    { layer: { kind: "organisation", name: "Acme" }, value: "approveForMe", words: "Approve for me", kept: false },
    { layer: { kind: "you", name: "You" }, value: "ask", words: "Ask", kept: false },
    { layer: { kind: "folder", name: "payments-api", folder: "/p" }, words: "Not set", kept: false },
  ] };
  assert.equal(p.sameAsYoursLine(mode, rule), "Same as yours (Ask)");
  assert.equal(p.sameAsYoursLine(mode, { ...rule, cap: undefined }), "Same as yours (Ask, and any mode may be chosen)");
  assert.equal(p.sameAsYoursLine(mode, undefined), "Same as yours (Ask, and any mode may be chosen)");
  assert.ok(!p.folderIsKept(rule));
  const above = { ...rule, layers: [rule.layers[1], { ...rule.layers[2], value: "bypassPermissions", words: "Bypass Permissions", kept: true }] };
  assert.ok(p.folderIsKept(above));
});

test("a folder opens in Agents ▸ Policy by the route's item", () => {
  assert.equal(p.policyItem(), "policy");
  assert.equal(p.policyItem("/src/payments-api"), "policy:/src/payments-api");
  assert.equal(p.policyFolderOf("policy:/src/payments-api"), "/src/payments-api");
  assert.equal(p.policyFolderOf("policy"), undefined);
  assert.equal(p.policyFolderOf(p.organisationItem), undefined);
  assert.equal(p.policyFolderOf(undefined), undefined);
  assert.equal(p.folderName("/src/payments-api/"), "payments-api");
  assert.equal(p.folderName("file:///src/my%20app"), "my app");
  assert.equal(p.rulesCount(1), "1 rule");
  assert.equal(p.rulesCount(2), "2 rules");
});

test("the stop card names the rule and the layer, and offers Change only for a layer the person can edit", () => {
  const you = { kind: "you", name: "You" };
  const budget = { reason: "budget", rule: "budgets.daily", words: "What you sent is waiting: the day's spending limit has been reached.",
    layer: you, value: "at most $40.00 a day" };
  assert.equal(p.stoppedTitle, "Stopped by a policy");
  assert.equal(p.stopRuleTitle("budgets.daily"), "Per day");
  assert.equal(p.stopRuleTitle("budgets"), "Budget");
  assert.equal(p.stopRuleTitle("models"), "models");
  assert.equal(p.stopRuleTitle(undefined), undefined);
  assert.equal(p.stopLayerLine(budget), "Your policy: at most $40.00 a day");
  assert.equal(p.stopLayerLine({ ...budget, value: budget.words }), undefined);
  assert.equal(p.stopLayerLine({ ...budget, value: undefined }), undefined);
  assert.deepEqual(p.stopAction(budget), { kind: "yours", label: "Change in Agents ▸ Policy" });
  const folder = { reason: "policy", rule: "permissionMode", words: "payments-api allows at most Ask.",
    layer: { kind: "folder", name: "payments-api", folder: "/src/payments-api" }, value: "Ask" };
  assert.equal(p.stopLayerLine(folder), "payments-api: Ask");
  assert.deepEqual(p.stopAction(folder), { kind: "folder", label: "Change in payments-api’s Policy", folder: "/src/payments-api" });
  const acme = { kind: "organisation", name: "Acme" };
  assert.deepEqual(p.stopAction({ reason: "budget", rule: "budgets", words: "w", layer: acme }), { kind: "spending", label: "Open Spending" });
  assert.deepEqual(p.stopAction({ reason: "policy", rule: "sandbox", words: "w", layer: acme }),
    { kind: "organisation", label: "See Organisation Policy" });
});

test("a waiting change to a folder's policy asks Allow, Keep the old value, or Show Change", () => {
  assert.deepEqual(p.policyChangeButtons({ looser: ["permissionMode"], words: "Permission mode: Ask → Bypass Permissions", was: "Ask" }),
    { allow: "Allow", undo: "Keep Ask", review: "Show Change" });
  assert.equal(p.policyChangeButtons({ looser: ["permissionMode", "sandbox"], words: "w" }).undo, "Keep Old Rules");
});

// #3262: Ask for More on the card, only at the organisation's budget, and where it stands once asked.
test("the stop card offers Ask for More at the organisation's budget", () => {
  const acme = { kind: "organisation", name: "Acme" };
  assert.equal(p.canAskForMore({ reason: "budget", rule: "budgets", words: "w", layer: acme }), true);
  assert.equal(p.canAskForMore({ reason: "budget", rule: "budgets.daily", words: "w", layer: { kind: "you", name: "You" } }), false);
  assert.equal(p.canAskForMore({ reason: "policy", rule: "sandbox", words: "w", layer: acme }), false);
  const r = { id: "r", user: "u", userName: "Sam", day: "2026-11-03", at: 1, state: "waiting" };
  assert.equal(p.askedWords(r), "Asked. An admin can raise today's budget.");
  assert.equal(p.askedWords({ ...r, state: "raised", daily: 80, decidedBy: "Alex" }), "Raised to $80 for today by Alex. Send again to go on.");
  assert.equal(p.askedWords({ ...r, state: "refused", decidedBy: "Alex" }), "Refused for today by Alex.");
  assert.match(p.askRefusal({ code: -32601 }), /cannot take the request yet/);
  assert.equal(p.askRefusal({ code: -32602 }), undefined);
});
