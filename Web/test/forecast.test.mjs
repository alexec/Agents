// An epic's forecast on Work's epic page (#4527), as ForecastWordsTests has it on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const f = await load("src/model/forecast.ts");

const range = (median, p10, p90) => ({ median, p10, p90 });
// Tue 10 Nov 2026, 12:00 UTC, in the wire's seconds since 2001.
const now = 1794312000 - 978307200;
const days = (n) => now + n * 86400;
const forecast = (more = {}) => ({ node: { kind: "issue", ref: "github:alexec/Agents#1" }, at: now, windowDays: 14,
  landings: 400, burn: [], serviceLevels: [], ...more });
const gb = ["en-GB", "UTC"];

test("an open epic says when it likely lands", () => {
  const g = forecast({ lands: { p50: days(8), p85: days(11), open: 6, closed: 2, stepsLeft: 3, share: 0.062, groups: 12 } });
  assert.equal(f.landsLine(g, ...gb), "Likely lands by Wed 18 Nov (85%: by Sat 21 Nov), at the last 14 days' pace");
  assert.equal(f.forecastHelp(g), "For the 6 open children filed now, not ones still to come: 1,000 draws of the last "
    + "14 days' landings, hour by hour, of which an epic gets 6.2%, the median of 12 closed epics. "
    + "The 3 blocked-by steps left do not move the date.");
});

test("a forecast for the next two days says the hour", () => {
  const g = forecast({ lands: { p50: now + 3 * 3600, p85: now + 9 * 3600, open: 1, closed: 4, stepsLeft: 1, share: 0.05, groups: 5 } });
  assert.equal(f.landsLine(g, ...gb), "Likely lands by Tue 10 Nov, 15:00 (85%: by Tue 10 Nov, 21:00), at the last 14 days' pace");
  assert.ok(f.forecastHelp(g).endsWith("the median of 5 closed epics."));
});

test("no date says why, unless there is nothing to say", () => {
  assert.equal(f.landsLine(forecast({ noForecast: "fewer than 5 closed epics" })), "No landing forecast: fewer than 5 closed epics");
  assert.equal(f.landsLine(forecast({ noForecast: "no open children" })), undefined);
  assert.equal(f.landsLine(forecast({ noForecast: "not an epic" })), undefined);
  assert.equal(f.forecastHelp(forecast()), undefined);
  assert.equal(f.toCompleteLine(forecast()), undefined);
});

test("the estimate to complete is a rounded range", () => {
  const t = { cost: { USD: range(95, 58, 141) }, ratio: 1.31, closed: 4, leadRatio: 0.1 };
  assert.equal(f.toCompleteLine(forecast({ toComplete: t })), "To complete: about $60 to $100");
  assert.equal(f.forecastHelp(forecast({ toComplete: t })),
    "To complete: the open children's estimates × 1.31, as the 4 closed children cost against theirs, plus 10% for the lead.");
  const all = { ...t, loaded: { USD: range(130, 80, 190) }, leadRatio: 0 };
  assert.equal(f.toCompleteLine(forecast({ toComplete: all })), "To complete: about $60 to $100 ($80 to $200 all in)");
  assert.equal(f.forecastHelp(forecast({ toComplete: all })),
    "To complete: the open children's estimates × 1.31, as the 4 closed children cost against theirs. All in adds the cost no issue links to.");
  const same = { ...t, loaded: { USD: range(96, 62, 144) } };
  assert.equal(f.toCompleteLine(forecast({ toComplete: same })), "To complete: about $60 to $100");
});

test("a closed epic says its first forecast against when it landed", () => {
  const kept = { at: days(-6), p50: days(-4), p85: days(-3), windowDays: 14, share: 0.06, open: 6 };
  const g = forecast({ noForecast: "no open children", kept });
  assert.equal(f.keptLine(g, days(-3.5), ...gb), "Forecast at its start: by Fri 6 Nov (85%: by Sat 7 Nov); landed Sat 7 Nov, within the 85%");
  assert.equal(f.keptLine(g, days(-1), ...gb), "Forecast at its start: by Fri 6 Nov (85%: by Sat 7 Nov); landed Mon 9 Nov, after the 85%");
  assert.equal(f.keptLine(g, undefined), undefined);
  assert.equal(f.keptLine(forecast(), now), undefined);
  assert.equal(f.keptHelp(g, ...gb), "Made Wed 4 Nov for its 6 open children then, at the last 14 days' pace.");
});
