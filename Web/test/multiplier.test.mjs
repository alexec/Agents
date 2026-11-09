// The Multiplier page (#3990): the same answers as the window's CrowdCount and CrowdLayout, the rising
// line's words and the earned badges.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/multiplier.ts");
const nav = await load("src/model/nav.ts");

test("a Multiplier is its whole engineers and one faint one for the fraction", () => {
  assert.deepEqual(m.crowdCount(3.2), { each: 1, blobs: 4, fraction: 0.20000000000000018 });
  assert.deepEqual(m.crowdCount(3.02), { each: 1, blobs: 3, fraction: 0 }, "a sliver is no Blob");
  assert.deepEqual(m.crowdCount(0), { each: 1, blobs: 0, fraction: 0 });
  assert.equal(m.crowdCount(2500).each, 10, "past 1,000 one Blob is 10 engineers");
  assert.equal(m.crowdCount(2500).blobs, 250);
});

test("the crowd has a place for each Blob, back rows drawn first, and you smaller in a big one", () => {
  const few = m.crowdLayout(3, 820, 170);
  assert.equal(few.places.length, 3);
  const many = m.crowdLayout(300, 820, 170);
  assert.equal(many.places.length, 300);
  const ys = many.drawingOrder.map((i) => many.places[i].y);
  assert.deepEqual(ys, [...ys].sort((a, b) => a - b));
  assert.ok(many.youScale < few.youScale);
  assert.deepEqual(m.crowdLayout(0, 820, 170), m.emptyLayout);
});

test("each Blob blinks about one tick in four, so a crowd of one does not blink every tick (#4194)", () => {
  let one = 0;
  for (let i = 0; i < 4000; i++) one += m.blinkers(1).size;
  assert.ok(one > 800 && one < 1200, `one Blob blinked in ${one} of 4000 ticks`);
  assert.equal(m.blinkers(0).size, 0);
  for (let i = 0; i < 200; i++) {
    assert.ok(m.blinkers(12).size <= m.MOST_BLINKING);
    const big = m.blinkers(1000);
    assert.ok(big.size >= 1 && big.size <= m.MOST_BLINKING);
  }
});

const baseline = { prsPerWeek: 1.4, hoursPerWeek: 40, source: "DX 2025" };
const at = (prsMerged, multiplier, more = {}) => ({ prsMerged, reverts: 0, multiplier, agentsWorking: 0, since: 0, baseline, ...more });
const pr = { kind: "pr", ref: "github:alexec/agents#1234" };

test("the rising line says the PR and the change, or a new best week", () => {
  assert.deepEqual(m.newsOf(at(4, 2.9), at(5, 3.6, { changedBy: pr })), { words: "+0.7×  #1234 merged", up: true });
  assert.deepEqual(m.newsOf(at(5, 3.6), at(4, 2.9, { changedBy: pr })), { words: "−0.7×  #1234 reverted", up: false });
  assert.deepEqual(m.newsOf(at(4, 2.9, { bestWeek: 3 }), at(6, 4.3, { changedBy: pr, bestWeek: 4.3 })),
    { words: "New best week: 4.3×", up: true });
  assert.equal(m.newsOf(at(4, 2.9), at(4, 2.9)), undefined, "a baseline change has no PR and no line");
});

test("the line under the figures is the person's own, else the baseline's", () => {
  assert.equal(m.baselineLine(at(1, 0.7)), "An average engineer merged 1.4 PRs a week (DX 2025)");
  assert.equal(m.baselineLine(at(1, 0.7, { baseline: { ...baseline, line: "Me in 2024" } })), "Me in 2024");
});

test("the earned badges come earliest first, with the first still to earn next", () => {
  const { badges, next } = m.earnedBadges({ earned: [{ id: "firstWorkflow", at: 10 }, { id: "firstAgent", at: 20 }] });
  assert.deepEqual(badges.map((b) => b.id), ["firstWorkflow", "firstAgent"]);
  assert.equal(next.id, "firstPairing");
  assert.equal(m.earnedBadges(undefined).next.id, "firstAgent", "nothing earned: the Next line alone");
  const all = ["firstAgent", "firstPairing", "firstRemoteAnswer", "firstWorkflow", "firstCloudHost", "firstLandedPR", "fiveAtOnce"];
  assert.equal(m.earnedBadges({ earned: all.map((id, i) => ({ id, at: i })) }).next, undefined);
  for (const id of all) assert.ok(m.badgeGlyph[id], id);
});

test("Reports ▸ Yours has the Multiplier first and no Achievements page", () => {
  const yours = nav.navPages.reports.filter((p) => p.group === "Yours").map((p) => p.id);
  assert.deepEqual(yours, ["multiplier", "usage"]);
  assert.deepEqual(nav.movedPage("a", "achievements"), { nav: "reports", section: "multiplier" });
});
