// Settings ▸ Groups (#1761): the same words as GroupWords in Packages/AgentsKit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const g = await load("src/model/teamGroups.ts");
const sam = { id: "sam", name: "Sam" };
const kim = { id: "kim", name: "Kim" };

test("groups: members are everyone or named", () => {
  assert.equal(g.members({ id: "g", name: "All", everyone: true, members: [] }, [sam]), "Everyone");
  assert.equal(g.members({ id: "g", name: "P", everyone: false, members: ["sam", "kim"] }, [sam, kim]), "Sam, Kim");
  assert.equal(g.members({ id: "g", name: "P", everyone: false, members: ["gone"] }, [sam]), "Someone removed");
  assert.equal(g.members({ id: "g", name: "P", everyone: false, members: [] }, []), "No one");
});

test("groups: a provider is for its group or the admins", () => {
  const platform = { id: "g1", name: "Platform", everyone: false, members: ["sam"] };
  const given = { id: "do", name: "DigitalOcean", group: "g1", mayUse: false };
  const none = { id: "dk", name: "Docker" };
  assert.equal(g.providerLine(given, [platform]), "For Platform");
  assert.equal(g.providerLine(none, [platform]), "For admins only");
  assert.equal(g.providerLine(none, []), null);
  assert.equal(g.providersOf(platform, [given, none]), "DigitalOcean");
  assert.equal(g.mayNotUse(given, [platform]), "Only Platform can start machines from DigitalOcean.");
  assert.equal(g.usable(given), false);
  assert.equal(g.usable(none), true);
});

test("bots: a bot's line says its group, cap and spend", () => {
  const platform = { id: "g1", name: "Platform", everyone: false, members: [] };
  assert.equal(g.botLine({ id: "b", name: "review-bot", kind: "bot", group: "g1", caps: { dailyUSD: 50 }, spentTodayUSD: 3.2 }, [platform]),
    "In Platform · $50 a day · $3.20 today");
  assert.equal(g.capWords(undefined), "No cap");
  assert.equal(g.capReachedWords({ user: "b", name: "review-bot", group: "Platform", spentUSD: 51, capUSD: 50, until: 0 }),
    "review-bot stopped at Platform’s cap: $51 of $50 today. It starts work again at midnight UTC.");
});

test("bots: a cap typed in is dollars or refused, never no cap for text typed (#2066)", () => {
  const dollars = (usd) => ({ kind: "dollars", usd });
  const refused = (problem) => ({ kind: "refused", problem });
  assert.deepEqual(g.readCap(" $12.5 "), dollars(12.5));
  assert.deepEqual(g.readCap("1,000"), dollars(1000));
  assert.deepEqual(g.readCap("$1,000.50"), dollars(1000.5));
  assert.deepEqual(g.readCap("50 USD"), dollars(50));
  assert.deepEqual(g.readCap("$50 a day"), dollars(50));
  assert.deepEqual(g.readCap("50 dollars"), dollars(50));
  assert.deepEqual(g.readCap(""), { kind: "none" });
  assert.deepEqual(g.readCap(" None "), { kind: "none" });
  assert.deepEqual(g.readCap("€50"), refused(g.capNotDollars));
  assert.deepEqual(g.readCap("1,00"), refused(g.capNotDollars));
  assert.deepEqual(g.readCap("fifty"), refused(g.capNotDollars));
  assert.deepEqual(g.readCap("-5"), refused(g.capNotDollars));
  assert.deepEqual(g.readCap("0"), refused(g.capNotAboveZero));
});
