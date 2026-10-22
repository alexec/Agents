// Cost ▸ Reports' totals and words (#1811), as ReportTotalsTests has them on the window and the Remote.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const r = await load("src/model/reports.ts");

const row = (over = {}) => ({
  at: "2026-10-21", person: "bea", personName: "Bea", host: "H1", hostName: "Bea's Mac", project: "shop", runtime: "claude",
  cost: {}, inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0, cachedWriteTokens: 0, turns: 0,
  unpricedTurns: 0, workingSeconds: 0, waitingSeconds: 0, ...over,
});

test("rows add up by each dimension, largest first", () => {
  const rows = [
    row({ cost: { USD: 1 }, inputTokens: 100, turns: 1, workingSeconds: 60 }),
    row({ person: "", personName: "", host: "H9", hostName: "Old box", project: "", cost: { USD: 3 }, turns: 2 }),
    row({ person: "al", personName: "Al", host: "H2", hostName: "Al's Mac", runtime: "codex", cost: { USD: 2 }, cachedReadTokens: 999 }),
    row({ at: "2026-10-20", cost: { USD: 0.5 }, outputTokens: 50, thoughtTokens: 5, cachedWriteTokens: 5 }),
  ];
  const people = r.reportTotals(rows, "person");
  assert.deepEqual(people.groups.map((g) => g.name), [r.removedOwner, "Al", "Bea"]);
  assert.equal(people.total.cost.USD, 6.5);
  assert.equal(people.groups[2].tokens, 160);
  assert.equal(people.groups[2].turns, 1);
  assert.deepEqual(r.reportTotals(rows, "project").groups.map((g) => g.name), ["shop", r.noProject]);
  assert.deepEqual(r.reportTotals(rows, "machine").groups.map((g) => g.name), ["Old box", "Al's Mac", "Bea's Mac"]);
  const runtimes = r.reportTotals(rows, "runtime", (id) => id === "claude" ? "Claude" : "Codex");
  assert.deepEqual(runtimes.groups.map((g) => g.name), ["Claude", "Codex"]);
  assert.equal(r.share(people, people.groups[0]), 1);
  assert.equal(r.share(people, people.groups[2]), 0.5);
});

test("nothing priced is shared out by tokens", () => {
  const t = r.reportTotals([row({ inputTokens: 10 }), row({ project: "b", inputTokens: 40 })], "project");
  assert.deepEqual(t.currencies, []);
  assert.equal(r.share(t, t.groups[1]), 0.25);
  assert.equal(r.line(t.groups[0]), "40 tokens · 0 turns · 0s working");
});

test("an export is named by its range and day", () => {
  assert.equal(r.exportName("week", "csv", new Date(2026, 9, 21, 9)), "report-week-2026-10-21.csv");
  assert.equal(r.exportName("threeMonths", "jsonl", new Date(2026, 0, 2)), "report-threeMonths-2026-01-02.jsonl");
});

test("scopes (#1804): a group dimension past Me, none naming a person when hidden, a budget's words", () => {
  assert.deepEqual(r.scopedDimensions({ scope: { kind: "me" } }), ["person", "project", "machine", "runtime"]);
  assert.deepEqual(r.scopedDimensions({ scope: { kind: "org" } }), ["person", "project", "machine", "runtime", "group"]);
  assert.deepEqual(r.scopedDimensions({ scope: { kind: "group", group: "g" }, personsHidden: true }), ["project", "runtime", "group"]);
  assert.equal(r.scopeKey({ kind: "group", group: "g1" }), "group:g1");
  const rows = [row({ groups: ["g1", "g2"], cost: { USD: 2 } }), row({ person: "al", personName: "Al", groups: [], cost: { USD: 1 } })];
  const t = r.reportTotals(rows, "group", (id) => id, { g1: "Platform", g2: "Web" });
  assert.deepEqual(t.groups.map((g) => [g.name, g.cost.USD]), [["Platform", 2], ["Web", 2], ["No group", 1]]);
  assert.equal(t.total.cost.USD, 3, "the total counts each row once");
  const now = new Date(Date.UTC(2026, 9, 11, 0, 0, 0));
  assert.equal(r.forecastUSD(100, now), 310);
  assert.match(r.budgetWords(100, 250, now), /of .*250.* this month · forecast .*310.*, over budget$/);
});

test("each scope is named on the pane (#2071)", () => {
  assert.equal(r.scopeNote({ kind: "me" }), "Your machines.");
  assert.equal(r.scopeNote({ kind: "org" }), "Everyone’s machines.");
  assert.equal(r.scopeNote({ kind: "group", group: "g1" }, "Platform"), "The machines of Platform’s people.");
  assert.match(r.meNote(true), /^Your machines\. .*Reports ▸ Spend/);
  // Only an admin or a group's lead is sent to Reports ▸ Spend (#2200).
  assert.equal(r.meNote(false), "Your machines. An admin or a group’s lead sees more.");
  assert.doesNotMatch(r.meNote(false), /Reports ▸ Spend/);
});

test("a late answer to another scope is not taken for this one (#2201)", () => {
  assert.equal(r.sameScope(undefined, { kind: "me" }), true);
  assert.equal(r.sameScope({ kind: "me" }, { kind: "org" }), false);
  assert.equal(r.sameScope({ kind: "group", group: "g1" }, { kind: "group", group: "g2" }), false);
  assert.equal(r.sameScope({ kind: "group", group: "g1" }, { kind: "group", group: "g1" }), true);
});

// Outcomes and Time (#2019): the counts each machine adds to its rows.
test("outcomes add up by person, merged first, with the cost of each merged pull request", () => {
  const counts = (over) => ({ sessions: 0, prsOpened: 0, prsMerged: 0, prsReverted: 0, mergeSeconds: 0, waits: 0, waitBuckets: [0, 0, 0, 0, 0, 0], ...over });
  const rows = [
    row({ cost: { USD: 8 }, counts: counts({ sessions: 3, prsOpened: 2, prsMerged: 2, prsReverted: 1, mergeSeconds: 7200 }) }),
    row({ person: "al", personName: "Al", cost: { USD: 1 }, workingSeconds: 60, waitingSeconds: 180,
      counts: counts({ sessions: 1, waits: 3, waitBuckets: [1, 0, 2, 0, 0, 0] }) }),
    // A machine before #2019 sends no counts.
    row({ person: "cy", personName: "Cy", cost: { USD: 2 }, workingSeconds: 100 }),
  ];
  const out = r.outcomeTotals(rows, "person", "merged");
  assert.deepEqual(out.groups.map((g) => g.name), ["Bea", "Al", "Cy"]);
  assert.equal(out.total.merged, 2);
  assert.equal(out.total.sessions, 4);
  assert.equal(r.outcomeLine(out.groups[0]), `2 merged of 2 opened · 1 revert · ${new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(4)} a merged pull request · 1h from start to merge · 3 sessions`);
  assert.equal(r.outcomeLine(out.groups[2]), "0 merged of 0 opened · 0 sessions");

  const time = r.outcomeTotals(rows, "person", "waiting");
  assert.equal(time.groups[0].name, "Al");
  assert.equal(r.waitingShare(time.groups[0]), 0.75);
  assert.equal(r.medianWait(time.groups[0].buckets), "5 to 15 minutes");
  assert.equal(r.medianWait([0, 0, 0, 0, 0, 0]), null);
  assert.equal(r.timeLine(time.groups[0]), "Waiting for a person 75% of the time · 3 waits, the middle one 5 to 15 minutes · 1m working");
  assert.equal(r.timeLine(time.groups[2]), "Waiting for a person 0% of the time · no waits · 2m working");
});
