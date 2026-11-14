// Reports ▸ Planning ▸ Builds (#5178, spec 5166): the address, the words, the tiles, the bars and the change.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const b = await load("src/model/builds.ts");
const nav = await load("src/model/nav.ts");
const r = await load("src/route.ts");

// A wire date: seconds from 2001-01-01.
const wd = (iso) => Date.parse(iso) / 1000 - 978307200;
const stat = (median, p90 = median, n = 1) => ({ median, p90, n });
const figures = (o = {}) => ({ runs: 10, green: 9, reruns: 1, toGreen: stat(852, 1524), run: stat(720), runner: stat(26), turn: stat(53), ...o });

test("the address keeps each filter and a picked change, and a default is left out", () => {
  const ask = { repo: "github:alexec/agents", range: "week", workflow: "ci.yml", job: "go-darwin", branch: "pulls", p90: true,
    change: { job: "go-darwin", ref: "github:run:alexec/agents#36315623551" } };
  const q = b.buildsQuery(ask);
  assert.match(q, /^repo=github:alexec\/agents&range=week&workflow=ci.yml&job=go-darwin&branch=pulls&stat=p90&change=/);
  assert.deepEqual(b.parseBuildsQuery(q), ask);
  assert.deepEqual(b.parseBuildsQuery(""), { repo: undefined, range: "month", workflow: undefined, job: undefined, branch: "", p90: false, change: undefined });
});

test("the Delivery card's link names the repo in builds/history's form and the range", () => {
  assert.equal(b.buildsRepo("github:repo:#alexec/Agents"), "github:alexec/agents");
  assert.equal(b.buildsRepo("alexec/Agents", "github"), "github:alexec/agents");
  assert.equal(b.buildsLinkQuery("github:repo:#alexec/agents", "month"), "repo=github:alexec/agents&range=month");
});

test("the route keeps a page item's query, and Builds is a page under Planning", () => {
  const route = r.parseRoute("#/reports/value/builds?repo=github:alexec/agents&range=month");
  assert.deepEqual(route, { nav: "reports", section: "value", item: "builds", query: "repo=github:alexec/agents&range=month" });
  assert.equal(r.routeHash(route), "#/reports/value/builds?repo=github:alexec/agents&range=month");
  assert.equal(nav.routePageID("reports", route), "builds");
  assert.equal(nav.routePageID("reports", { section: "value" }), "value");
  const list = nav.navPages.reports.map((p) => p.id);
  assert.equal(list[list.indexOf("value") + 1], "builds");
  assert.deepEqual(nav.pageRoute("reports", nav.navPages.reports.find((p) => p.id === "builds")), { nav: "reports", section: "value", item: "builds" });
});

test("times are said as the boards say them", () => {
  assert.equal(b.secondsWords(79), "79 s");
  assert.equal(b.secondsWords(120), "2.0 min");
  assert.equal(b.secondsWords(852), "14.2 min");
  assert.equal(b.secondsWords(6180), "1 h 43 min");
});

test("the tiles: the last 7 days against the 7 before; queue in seconds, never a share", () => {
  const tiles = b.buildsTiles(figures(), figures({ toGreen: stat(780, 1400), run: stat(667), runner: stat(4), turn: stat(3) }), "main", 5, "threeMonths");
  const [green, run, queue, count] = tiles;
  assert.deepEqual([green.value, green.detail, green.delta.words, green.delta.slower], ["14.2 min", "P90 25.4 min · 9 runs, last 7 days", "+9 %", true]);
  assert.deepEqual([run.value, run.delta.words], ["12.0 min", "+8 %"]);
  assert.deepEqual([queue.value, queue.detail, queue.delta.words], ["79 s", "53 s its turn, 26 s a runner. Load.", "+72 s"]);
  assert.deepEqual([count.title, count.value, count.detail], ["Green runs on main", "9", "Last 7 days · 5 re-runs in the last 90 days"]);
  const none = b.buildsTiles(figures({ green: 0 }), undefined, "main", 0, "week");
  assert.deepEqual(none.map((t) => t.value), ["–", "–", "–", "–"]);
});

test("a bar a day, a day with no runs empty; the top is a round step", () => {
  const keys = b.dayKeys(new Date("2026-11-10T00:00:00Z"), new Date("2026-11-13T00:00:00Z"), "UTC");
  assert.deepEqual(keys, ["2026-11-10", "2026-11-11", "2026-11-12"]);
  const bars = b.buildsBars([{ day: "2026-11-11", figures: figures() }], keys, false);
  assert.deepEqual(bars.map((x) => x.total), [0, 799, 0]);
  assert.equal(bars[1].p90, 1524);
  assert.equal(b.chartTop(bars, true), 1800);
  assert.equal(b.dayWords("2026-11-11"), "11 Nov");
});

test("release tags: a minor is labelled, a patch is not, outside the range left out", () => {
  const marks = b.releaseMarks([{ tag: "v0.17.0", publishedAt: "2026-11-11T12:00:00Z" }, { tag: "v0.17.1", publishedAt: "2026-11-12T00:00:00Z" },
    { tag: "v0.1.0", publishedAt: "2026-01-01T00:00:00Z" }], new Date("2026-11-10T00:00:00Z"), new Date("2026-11-14T00:00:00Z"));
  assert.deepEqual(marks.map((m) => [m.tag, m.minor, m.at]), [["v0.17.0", true, 0.375], ["v0.17.1", false, 0.5]]);
});

const ref = (id, o = {}) => ({ ref: `github:run:alexec/agents#${id}`, id, attempt: 1, made: wd("2026-11-09T00:51:00Z"), ...o });
const change = {
  workflow: "ci.yml", job: "go-darwin", slower: true, at: wd("2026-11-09T00:51:00Z"), runner: "macos-latest",
  lastFast: ref(1, { headSha: "efd532a00", made: wd("2026-11-09T00:08:00Z") }), firstSlow: ref(4, { headSha: "37353390", pr: 4145 }),
  medianBefore: 288, medianAfter: 384, queueBefore: 3, queueAfter: 3, score: 12,
  between: [
    { run: ref(2, { headSha: "f00f48c0" }), ran: false },
    { run: ref(3, { headSha: "cf455a10", conclusion: "cancelled" }), ran: false },
    { run: ref(4, { headSha: "37353390", conclusion: "failure" }), ran: true, jobRun: 432 },
  ],
  points: [{ ref: ref(1).ref, made: wd("2026-11-09T00:08:00Z"), ran: 300, queue: 3 }, { ref: ref(4).ref, made: wd("2026-11-09T00:51:00Z"), ran: 432, queue: 3 }],
};

test("a change in words: the list, the lane, the heading and its context", () => {
  assert.equal(b.changeTitle(change, "UTC"), "go-darwin slower, 9 Nov");
  assert.equal(b.changeLine(change), "4.8 min → 6.4 min · 3 commits");
  assert.equal(b.changeMark(change), "go-darwin +33 %");
  assert.equal(b.changeHeading(change, "UTC"), "go-darwin slower from 9 November: 4.8 min → 6.4 min (+33 %)");
  assert.equal(b.changeContext(change, "main"),
    "Run time on main, the median of the runs before and after. Runner: macos-latest. Queue time: 3 s before, 3 s after, so not load: look at the commits.");
  assert.match(b.changeContext({ ...change, queueAfter: 90 }, "main"), /load moved too/);
});

test("the commits between: not run, cancelled, and the first slow run", () => {
  assert.deepEqual(change.between.map((x) => b.betweenLine(x, change)), [
    { kind: "notRun", words: "Did not run go-darwin: its paths did not select it" },
    { kind: "cancelled", words: "Its run was cancelled for a newer push; the next run tested it too" },
    { kind: "firstSlow", words: "go-darwin 7.2 min · the run failed" },
  ]);
  assert.equal(b.lastFastLine(change), "Last fast run: go-darwin 5.0 min");
  assert.equal(b.runName(change.lastFast), "efd532a");
  assert.equal(b.pullRef("github:alexec/agents", 4145), "github:pr:alexec/agents#4145");
});

test("the lane puts a mark in the first row free at its place", () => {
  const rows = b.laneRows([{ x: 0 }, { x: 5 }, { x: 50 }], (t) => t.x, () => 20);
  assert.deepEqual(rows.map((x) => x.row), [0, 1, 0]);
});

test("the empty states say why", () => {
  assert.equal(b.noRunsWords("ci.yml", "main", "week"), "No ci runs on main finished in the last 7 days. Try a longer range, or Branch ▸ Pull requests.");
  assert.equal(b.noCIWords("github:alexec/agents-walk"), "alexec/agents-walk has no GitHub Actions runs. Builds come from the forge’s CI runs.");
  assert.equal(b.noReaderWords("forgejo:codeberg.org/scratch/app"),
    "Forgejo: Agent Loops does not read its CI runs yet, so there is nothing to draw for codeberg.org/scratch/app.");
  assert.equal(b.workflowShown(undefined, ["deploy.yml", "ci.yml"]), "ci.yml");
});
