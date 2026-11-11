// Reports ▸ Planning's words (#4528): what comes next, from lineage/forecast, and how the forecasts scored.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/planning.ts");

const ref = Date.UTC(2001, 0, 1);
const wire = (ms) => (ms - ref) / 1000;
const now = Date.UTC(2026, 10, 10, 12);
const day = 86400 * 1000;
const range = (median, p10, p90) => ({ USD: { median, p10, p90 } });

test("the spend says the direct range and the loaded figure beside it", () => {
  const f = { at: wire(now), windowDays: 14, landings: 40, burn: [], serviceLevels: [],
    spend: { week: range(60, 40, 90), month: range(250, 200, 300), loadedWeek: range(100, 70, 150) } };
  assert.deepEqual(p.spendLines(f), ["A week: $40 to $90, typically $60 (about $100 all in)", "A month: $200 to $300, typically $250"]);
  assert.deepEqual(p.spendLines({ ...f, spend: undefined }), []);
});

test("an allowance runs out before its reset, lasts to it, or ran out", () => {
  const b = { credentialKey: "claude:me", window: "seven_day", used: 0.62, at: wire(now), resetsAt: wire(now + 5 * day), lasts: false,
    runsOutAt: wire(now + 3 * day) };
  assert.match(p.burnLine(b, "Claude", now), /^Claude, this week: 62% used; at this pace it runs out .+, before it resets .+$/);
  assert.match(p.burnLine({ ...b, lasts: true, runsOutAt: undefined }, "Claude", now), /it lasts to the reset/);
  assert.match(p.burnLine({ ...b, used: 1 }, "Claude", now), /it ran out, and resets/);
  assert.equal(p.burnRuntime(b), "claude");
});

test("each allowance once, the newest reading from any machine", () => {
  const b = (key, at, used) => ({ credentialKey: key, window: "7 days", used, at, resetsAt: at + 1000, lasts: true });
  const merged = p.mergeBurns([{ burn: [b("claude:me", 10, 0.2), b("codex:me", 5, 0.1)] }, { burn: [b("claude:me", 20, 0.4)] }]);
  assert.deepEqual(merged.map((m) => [m.credentialKey, m.used]), [["claude:me", 0.4], ["codex:me", 0.1]]);
});

test("a service level and an epic's landing", () => {
  assert.equal(p.serviceLevelLine({ level: "story", closed: 31, p50Seconds: 2 * 3600, p85Seconds: 6 * 3600 }),
    "Stories: half within 2 hours, 85% within 6 hours (31 landed)");
  const f = { at: wire(now), windowDays: 14, landings: 40, burn: [], serviceLevels: [],
    lands: { p50: wire(now + 3 * day), p85: wire(now + 4 * day), open: 6, closed: 2, stepsLeft: 2, share: 0.06, groups: 9 },
    toComplete: { cost: range(60, 40, 90), ratio: 1.2, closed: 3, leadRatio: 0.3, loaded: range(80, 50, 120) } };
  assert.match(p.landsLine(f, now), /^6 open children: P50 .+, P85 .+ · \$40 to \$90, typically \$60 \(about \$80 all in\) to complete$/);
  assert.equal(p.landsLine({ ...f, lands: undefined, toComplete: undefined, noForecast: "Too few closed epics" }, now), "Too few closed epics");
});

test("how the kept forecasts scored", () => {
  assert.equal(p.forecastScoreLine({ epics: 11, p50Held: 6, p85Held: 9, errorDays: 1 }),
    "The P85 landing date held 9 of 11 epics (it should hold about 85%); the P50 held 6 of 11 (about half); the P50 was off by a median of 1 day");
  assert.equal(p.forecastScoreLine(undefined), undefined);
});

test("the cost all in, with the overhead ratio", () => {
  const cost = (usd) => ({ cost: { USD: usd }, inputTokens: 0, outputTokens: 0, turns: 1, workingSeconds: 0, waitingSeconds: 0 });
  const v = { loaded: cost(16.2), overhead: { windowDays: 14, linked: cost(10), unlinked: cost(3), unlinkedRatio: 0.3, uncounted: [] } };
  assert.equal(p.loadedLine(v), "$16.20 all in, with the turns on no issue or pull request (the overhead was ×1.30 over the last 14 days)");
  assert.equal(p.loadedLine({}), undefined);
});

// #4531: the what-if's picks, what the window ran with, and what the picks moved.
const assumes = { lanes: 3.24, peakLanes: 7, runtimes: [
  { runtime: "claude", share: 0.75, hours: 30, rate: { USD: 10 } }, { runtime: "codex", share: 0.25, hours: 10, rate: { USD: 2 } }] };

test("the lane limits and the shares to pick", () => {
  const lanes = p.laneOptions(assumes);
  assert.deepEqual(lanes[0], ["", "As they ran (up to 7)"]);
  assert.deepEqual(lanes.slice(1, 3), [["1", "1 lane"], ["2", "2 lanes"]]);
  assert.equal(lanes.length, 11);
  assert.deepEqual(p.mixOptions(0.75)[0], ["", "As it ran (75%)"]);
  assert.deepEqual(p.mixOptions(0.75).at(-1), ["100", "100%"]);
  assert.deepEqual(p.mixOptions(0.25, 0.5)[0], ["", "The rest (50%)"]);
});

test("the request's what-if: none as it ran, and the runtimes not picked share the rest", () => {
  assert.equal(p.whatIfOf("", {}, assumes), undefined);
  assert.equal(p.whatIfOf("", { claude: "" }, assumes), undefined);
  assert.deepEqual(p.whatIfOf("2", {}, assumes), { lanes: 2 });
  assert.deepEqual(p.whatIfOf("", { claude: "50" }, assumes), { mix: { claude: 0.5, codex: 0.5 } });
  assert.deepEqual(p.whatIfOf("3", { claude: "100", codex: "100" }, assumes), { lanes: 3, mix: { claude: 1, codex: 1 } });
});

test("what the window ran with, and what a what-if moved", () => {
  const name = (r) => ({ claude: "Claude", codex: "Codex" })[r] ?? r;
  assert.equal(p.assumesLine(assumes, 14, name),
    "The last 14 days had 3.2 issues in flight in an average hour, 7 at most; the mix was Claude 75% at $10 an hour, Codex 25% at $2 an hour.");
  assert.equal(p.assumesLine({ lanes: 0, peakLanes: 0, runtimes: [] }, 14, name), "The last 14 days had no issue in flight; no runtime’s hours are on this machine.");
  const [lanes] = p.whatIfLines({ lanes: 2, pace: 0.64, cost: 1 }, assumes);
  assert.match(lanes, /^At 2 lanes: 64% of the window’s landings, so the dates move out/);
  assert.match(p.whatIfLines({ lanes: 9, pace: 1, cost: 1 }, assumes)[0], /no hour of the window had more than 7 issues in flight, so this limit moves nothing/);
  const mixed = p.whatIfLines({ mix: { claude: 0.5, codex: 0.5 }, pace: 1, cost: 0.75 }, assumes);
  assert.equal(mixed.length, 1);
  assert.match(mixed[0], /^With this mix, the dollars are ×0\.75.+A mix does not move the dates/);
});
