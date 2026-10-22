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

test("groups: a group's bots are those that name it (#2132)", () => {
  const platform = { id: "g1", name: "Platform", everyone: false, members: ["sam"] };
  const review = { id: "b1", name: "review-bot", kind: "bot", group: "g1" };
  const nightly = { id: "b2", name: "nightly-bot", kind: "bot", group: "g2" };
  assert.equal(g.groupBots(platform, [sam, review, nightly]), "review-bot");
  assert.equal(g.groupBots(platform, [sam]), "None");
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

test("team groups: a cap notice holds only while true: its day, its cap, its bot (#2073)", () => {
  const now = Date.UTC(2026, 9, 21, 12) / 1000;
  const until = Date.UTC(2026, 9, 22) / 1000;
  const own = { user: "b", name: "review-bot", spentUSD: 51, capUSD: 50, until };
  const grouped = { user: "c", name: "lint-bot", group: "Platform", spentUSD: 90, capUSD: 80, until };
  const people = [
    { id: "b", name: "review-bot", kind: "bot", caps: { dailyUSD: 50 }, group: "g1" },
    { id: "c", name: "lint-bot", kind: "bot", group: "g1" },
  ];
  const groups = [{ id: "g1", name: "Platform", everyone: false, members: [], caps: { dailyUSD: 80 } }];
  // A wire date counts seconds from 2001, as Foundation does.
  const at = (seconds) => Date.UTC(2001, 0, 1) + seconds * 1000;
  assert.equal(g.openCaps([own, grouped], people, groups, at(now)).length, 2);
  // Its day ended.
  assert.equal(g.openCaps([own], people, groups, at(until)).length, 0);
  // Its cap changed, or its group's.
  assert.equal(g.openCaps([own], [{ ...people[0], caps: { dailyUSD: 100 } }], groups, at(now)).length, 0);
  assert.equal(g.openCaps([grouped], people, [{ ...groups[0], caps: { dailyUSD: 200 } }], at(now)).length, 0);
  // Its bot was removed, or moved to another group.
  assert.equal(g.openCaps([own], [], groups, at(now)).length, 0);
  assert.equal(g.openCaps([grouped], [people[0], { ...people[1], group: "g2" }], groups, at(now)).length, 0);
  // No list yet: only the time.
  assert.equal(g.openCaps([own], null, [], at(now)).length, 1);
  // One per bot, the last told.
  assert.deepEqual(g.addCap({ ...own, spentUSD: 60 }, [own, grouped]).map((n) => [n.user, n.spentUSD]), [["c", 90], ["b", 60]]);
  // OK puts one bot's notice away and keeps the others (#2198).
  assert.deepEqual(g.dropCap(own, [own, grouped]).map((n) => n.user), ["c"]);
});

test("team groups: a group's cap line adds its bots' spend today (#2074)", () => {
  const group = { id: "g1", name: "Platform", everyone: false, members: [], caps: { dailyUSD: 50 } };
  const people = [
    { id: "a", kind: "bot", group: "g1", spentTodayUSD: 3.2 },
    { id: "b", kind: "bot", group: "g1", spentTodayUSD: 8.8 },
    { id: "c", kind: "bot", group: "g2", spentTodayUSD: 40 },
    { id: "d", kind: "person", group: "g1", spentTodayUSD: 1 },
  ];
  assert.equal(g.groupCapLine(group, people), "$50 a day · $12 today");
  assert.equal(g.groupCapLine({ ...group, caps: undefined }, []), "No cap");
});
