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
  assert.equal(r.monthSpentUSD([row({ at: "2026-10-01", cost: { USD: 5 } }), row({ at: "2026-09-30", cost: { USD: 9 } })], now), 5);
  assert.equal(r.forecastUSD(100, now), 310);
  assert.match(r.budgetWords(100, 250, now), /of .*250.* this month · forecast .*310.*, over budget$/);
});
