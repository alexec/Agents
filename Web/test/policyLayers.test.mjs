// Agents ▸ Policy's words and rows (#2957, T039), as PolicyLayersWordsTests checks them in Swift: the banner, which
// values a cap dims, and setting a rule on your layer.
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
