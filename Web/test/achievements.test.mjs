// The achievements (#984): the same answers as AchievementsTests in Swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/achievements.ts");

function storage() {
  const items = new Map();
  return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v) };
}

test("earned first, earliest first, then the rest in order", () => {
  const rows = m.orderedAchievements({ earned: [{ id: "firstWorkflow", at: 10 }, { id: "firstAgent", at: 20 }] });
  assert.deepEqual(rows.slice(0, 2).map((r) => r.id), ["firstWorkflow", "firstAgent"]);
  assert.equal(rows.length, 7);
  assert.equal(rows[2].id, "firstPairing");
  assert.equal(rows[2].at, null);
});

test("an id a newer host knows is kept out of the list but not lost", () => {
  const achievements = { earned: [{ id: "somethingNew", at: 0 }] };
  assert.equal(m.orderedAchievements(achievements).filter((r) => r.at).length, 0);
  assert.equal(m.isComplete(achievements), false);
});

test("the card is only for what was earned after the first look", () => {
  const seen = new m.AchievementsSeen(storage());
  const before = { earned: [{ id: "firstAgent", at: 0 }] };
  assert.equal(seen.card(before), undefined);
  seen.take(before);
  assert.equal(seen.card(before), undefined);
  const after = { earned: [...before.earned, { id: "firstPairing", at: 5 }] };
  seen.take(after);
  assert.equal(seen.card(after), "firstPairing");
  seen.dismiss("firstPairing");
  assert.equal(seen.card(after), undefined);
});

test("what was seen is kept across visits", () => {
  const kept = storage();
  const first = new m.AchievementsSeen(kept);
  first.take({ earned: [{ id: "firstAgent", at: 0 }] });
  const again = new m.AchievementsSeen(kept);
  assert.equal(again.card({ earned: [{ id: "firstAgent", at: 0 }, { id: "fiveAtOnce", at: 9 }] }), "fiveAtOnce");
});
