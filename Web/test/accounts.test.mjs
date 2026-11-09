// Settings ▸ You ▸ Accounts (#3967, #3998): the project filter, the foot and the token mark, as the window's.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const a = await load("src/model/accounts.ts");
const all = [
  { service: "gitlab.com", monthlyCostUsd: 0 },
  { service: "aws.amazon.com", monthlyCostUsd: 12.5, projects: ["Agents"] },
  { service: "slack.com", monthlyCostUsd: 8, projects: ["Other"] },
];

test("accounts: one with no projects is for all", () => {
  assert.deepEqual(a.accountsOf(all, "agents").map((x) => x.service), ["gitlab.com", "aws.amazon.com"]);
  assert.equal(a.accountsOf(all, "").length, 3);
  assert.deepEqual(a.accountProjects(all), ["Agents", "Other"]);
});

test("accounts: the foot adds up the cost", () => {
  assert.equal(a.accountsFoot(all), "3 accounts, $20.50 a month.");
  assert.equal(a.accountsFoot([]), "0 accounts, $0 a month.");
});

test("accounts: a token that expires soon is marked", () => {
  const now = Date.parse("2026-11-07T12:00:00Z");
  assert.equal(a.expiresSoon({ service: "x", tokenExpires: "2026-11-20" }, now), "Its token expires on 2026-11-20.");
  assert.equal(a.expiresSoon({ service: "x", tokenExpires: "2027-10-18" }, now), null);
  assert.equal(a.expiresSoon({ service: "x", tokenExpires: "2026-11-01" }, now), "Its token expired on 2026-11-01.");
});

test("accounts: the sheet's fields go both ways", () => {
  const x = { service: "aws.amazon.com", description: "The agents' own AWS account.", monthlyCostUsd: 12.5, projects: ["Agents", "Web"] };
  assert.deepEqual(a.accountOf(a.accountFields(x)), x);
  assert.deepEqual(a.accountOf({ service: " x.com ", plan: " " }), { service: "x.com" });
});

test("accounts: one made before descriptions says so (#4164)", () => {
  assert.equal(a.accountAbout(all[0]), "No description");
  assert.equal(a.accountAbout({ service: "x", description: " For tests. " }), "For tests.");
});

test("accounts: Ask before use is on at first, and the sheet keeps it off (#4163)", () => {
  assert.equal(a.accountAsks({ service: "x" }), true);
  const off = { service: "x", askBeforeUse: false };
  assert.equal(a.accountAsks(off), false);
  assert.deepEqual(a.accountOf(a.accountFields(off)), off);
  assert.deepEqual(a.accountOf({ service: "x", askBeforeUse: "" }), { service: "x" });
});
