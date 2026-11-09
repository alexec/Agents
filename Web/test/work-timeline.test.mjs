// Work ▸ Timeline (#4206), as WorkTimelineTests has it on the window (#4173).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const t = await load("src/model/workTimeline.ts");
const nav = await load("src/model/nav.ts");

const now = 1_800_000_000_000;
const h = (hours) => now + hours * 3_600_000;
// The wire's dates are seconds since 2001 (protocol/dates.ts).
const wire = (hours) => hours === undefined ? undefined : (h(hours) - Date.UTC(2001, 0, 1)) / 1000;
const drop = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));

const item = (n, { feature, state = "open" } = {}) => drop({
  node: { kind: "issue", ref: `github:alexec/Agents#${n}` }, title: `Issue ${n}`, state, labels: [], assignees: [], updatedAt: 0, comments: 0, feature,
});
const child = (n, { started, closed, forecast, waits, reason } = {}) => drop({
  item: item(n, { state: closed === undefined ? "open" : "closed" }), stateReason: reason, createdAt: wire(-100),
  startedAt: wire(started), closedAt: wire(closed), waitsForPerson: waits ? true : undefined, forecastAt: wire(forecast),
});
const fc = (low, mid, high, waits) => drop({ low: wire(low), mid: wire(mid), high: wire(high), waits });
const epic = (n, children, segments, { forecast, feature = "work", reason } = {}) => drop({
  item: item(n, { feature }), stateReason: reason, createdAt: wire(-100), children,
  segments: segments.map(([s, c]) => drop({ startedAt: wire(s ?? undefined), closedAt: wire(c ?? undefined) })), forecast,
});
const axis = new t.Axis({ start: h(-24), end: h(24) }, 960);

test("the ranges put Now in the centre, and at three quarters in Week", () => {
  assert.deepEqual(t.timelineRanges.map((r) => t.rangeTitle[r]), ["1 Day", "2 Days", "Week"]);
  assert.deepEqual(t.rangeWindow("twoDays", now), { start: h(-24), end: h(24) });
  assert.deepEqual(t.rangeWindow("day", now), { start: h(-12), end: h(12) });
  // Alex, 2026-11-09: in Week, Now sits at three quarters of the width.
  assert.deepEqual(t.rangeWindow("week", now), { start: h(-126), end: h(42) });
  assert.equal(t.zoomed("twoDays", true), "day");
  assert.equal(t.zoomed("day", true), "day");
  assert.equal(t.zoomed("twoDays", false), "week");
  assert.equal(t.zoomed("week", false), "week");
});

test("the axis is linear time, ticked on the hour", () => {
  assert.equal(axis.x(h(-24)), 0);
  assert.equal(axis.x(now), 480);
  assert.equal(axis.date(960), h(24));
  const ticks = axis.ticks(2 * 86_400_000);
  assert.ok(ticks.length >= 8 && ticks.every((x) => x >= h(-24) && x <= h(24) && new Date(x).getMinutes() === 0 && new Date(x).getHours() % 6 === 0));
  const week = new t.Axis({ start: h(-126), end: h(42) }, 800).ticks(7 * 86_400_000);
  assert.ok(week.length >= 6 && week.every((x) => new Date(x).getHours() === 0));
});

test("an epic with no children is not drawn, and a line is a segment", () => {
  const lines = t.timelineLines({ epics: [
    epic(1, [], []),
    epic(2, [child(10, { started: -20, closed: -18 }), child(11, { started: -6, closed: -5 })], [[-20, -18], [-6, -5]]),
  ], releases: [] }, now);
  assert.deepEqual(lines.map((l) => l.id), ["github:alexec/Agents#2/0", "github:alexec/Agents#2/1"]);
  assert.deepEqual(lines.map((l) => l.how.how), ["joined", "joined"]);
  assert.deepEqual(lines[0].dots.map((d) => d.number), ["#10"]);
  assert.deepEqual(lines[1].dots.map((d) => d.number), ["#11"]);
  assert.equal(t.figures(lines[1]), "#2 · 2 of 2");
  assert.equal(t.epicOf(lines[1].id), "github:alexec/Agents#2");
});

test("no dot is before its fork", () => {
  const [line] = t.timelineLines({ epics: [epic(3, [child(12, { closed: -30 }), child(13, { started: -10, closed: -2 })], [[-10, -2]])], releases: [] }, now);
  assert.ok(line.dots.every((d) => d.at >= line.start && d.at <= line.end));
});

test("an open line is forecast, waits or stops at Now", () => {
  const timeline = { epics: [
    epic(4, [child(20, { started: -8, closed: -3 }), child(21, { started: -1, forecast: 3 }), child(22, { forecast: 5 })], [[-8, null]],
      { forecast: fc(2, 5, 11) }),
    epic(5, [child(23, { started: -4 }), child(24, { waits: true })], [[-4, null]], { forecast: fc(1, 2, 3, true) }),
    epic(6, [child(25, { started: -4 })], [[-4, null]]),
    // Not started, but forecast: it forks at its first child's forecast.
    epic(7, [child(26, { forecast: 6 })], [[null, null]], { forecast: fc(5, 6, 8) }),
  ], releases: [] };
  const lines = t.timelineLines(timeline, now);
  assert.deepEqual(lines.map((l) => l.how), [{ how: "forecast" }, { how: "waits", count: 1 }, { how: "open" }, { how: "forecast" }]);
  assert.equal(lines[0].end, h(5));
  assert.deepEqual(lines[0].band, { start: h(2), end: h(11) });
  assert.deepEqual(lines[0].dots.map((d) => d.closed), [true, false, false]);
  assert.equal(lines[0].working, 1);
  assert.equal(lines[2].end, now);
  assert.equal(lines[3].start, h(6));
  // Forecast off: the past only.
  const past = t.timelineLines(timeline, now, false);
  assert.deepEqual(past.map((l) => l.how.how), ["open", "waits", "open"]);
  assert.ok(past[0].dots.every((d) => d.closed) && past[0].band === undefined);
});

test("a dropped epic ends in a cross", () => {
  const lines = t.timelineLines({ epics: [epic(8, [child(30, { started: -5, closed: -4 })], [[-5, -4]], { reason: "not_planned" })], releases: [] }, now);
  assert.deepEqual(lines.map((l) => l.how.how), ["dropped"]);
});

test("only the lines that overlap the window are drawn", () => {
  const lines = t.overlapping(t.timelineLines({ epics: [
    epic(9, [child(31, { started: -60, closed: -50 })], [[-60, -50]]),
    epic(10, [child(32, { started: -30, closed: -20 })], [[-30, -20]]),
    epic(11, [child(33, { started: -90 }), child(34, { waits: true })], [[-90, null]], { forecast: fc(-80, -80, -80, true) }),
  ], releases: [] }, now), axis.interval);
  // A line that waits for the person is drawn while it is open.
  assert.deepEqual(lines.map((l) => l.number), ["#10", "#11"]);
});

test("each line takes the free lane nearest the releases line", () => {
  const timeline = { epics: [
    epic(12, [child(40, { started: -20, closed: -10 })], [[-20, -10]]),
    epic(13, [child(41, { started: -18, closed: -12 })], [[-18, -12]]),
    epic(14, [child(42, { started: -16, closed: -14 })], [[-16, -14]]),
    // Starts after #12's line and label have ended: lane 1 is free again.
    epic(15, [child(43, { started: -5, closed: -1 })], [[-5, -1]]),
  ], releases: [] };
  const lines = t.layout(t.timelineLines(timeline, now), axis, () => 60);
  assert.deepEqual(lines.map((l) => l.lane), [1, -1, 2, 1]);
  assert.deepEqual(t.lanes(lines), { above: 2, below: 1 });
  // A long label keeps its lane busy after its line has joined.
  assert.deepEqual(t.layout(t.timelineLines(timeline, now), axis, () => 400).map((l) => l.lane), [1, -1, 2, -2]);
  assert.deepEqual(t.lanes([]), { above: 0, below: 0 });
});

test("the riser is in pixels", () => {
  assert.equal(t.riser(1), 16);
  assert.equal(t.riser(-9), 48);
});

test("joins within six pixels are one ring with a count", () => {
  const forecast = fc(4, 5, 6);
  const lines = t.layout(t.timelineLines({ epics: [
    epic(16, [child(50, { started: -2, forecast: 5 })], [[-2, null]], { forecast }),
    epic(17, [child(51, { started: -3, forecast: 5 })], [[-3, null]], { forecast }),
    epic(18, [child(52, { started: -9, closed: -1 })], [[-9, -1]]),
  ], releases: [] }, now), axis, () => 10);
  const joins = t.joins(lines, axis);
  assert.equal(joins.length, 2);
  assert.equal(joins[1].lines.length, 2);
  assert.equal(joins[1].forecast, true);
});

test("a label drops its title before the next thing on its lane", () => {
  const [line] = t.timelineLines({ epics: [epic(19, [child(60, { started: -1, forecast: 5 })], [[-1, null]], { forecast: fc(3, 5, 8) })], releases: [] }, now);
  const measure = (s) => s.length * 6;
  // Now is 20 px on: room for nothing.
  const room = t.labelRoom(line, axis.x(line.start), axis, now);
  assert.equal(room, 14);
  assert.equal(t.fitLabel(line, room, measure), undefined);
  assert.equal(t.fitLabel(line, 80, measure), "#19 · 0 of 1");
  assert.equal(t.fitLabel(line, Infinity, measure), "Issue 19  #19 · 0 of 1");
});

test("a feature keeps its colour, the window's", () => {
  assert.equal(t.colourIndex("work", 12), t.colourIndex("Work", 12));
  // FNV-1a of "work", as the window's WorkTimeline.colour has it.
  assert.equal(t.colourIndex("work", 12), 8);
  assert.equal(t.colourIndex(undefined, 12), 11);
  assert.ok(t.colourIndex("autonomy", 12) >= 0 && t.colourIndex("autonomy", 12) < 11);
});

test("the hit is the nearest dot, then the line", () => {
  const timeline = { epics: [epic(21, [child(80, { started: -10, closed: -6 })], [[-10, -2]])],
    releases: [{ tag: "v1.2.0", at: wire(-12), repo: "alexec/Agents" }] };
  const lines = t.layout(t.timelineLines(timeline, now), axis, () => 10);
  const trunk = 200, lane = 30, y = trunk - lane;
  const at = (x, yy) => t.hit({ x, y: yy }, lines, timeline.releases, axis, trunk, lane);
  assert.equal(at(axis.x(h(-6)) + 3, y)?.dot?.number, "#80");
  assert.equal(at(axis.x(h(-4)), y + 5)?.line?.number, "#21");
  assert.equal(at(axis.x(h(-4)), y + 5)?.kind, "line");
  assert.equal(at(axis.x(h(-12)), trunk)?.release?.tag, "v1.2.0");
  assert.equal(at(axis.x(h(-4)), y - 20), undefined);
});

test("the words say about", () => {
  const backtest = { error: 2.16, width: 1.3, cuts: 69, holds: 55, epics: 21, at: wire(0) };
  const [line] = t.timelineLines({ epics: [
    epic(22, [child(90, { started: -3, closed: -1 }), child(91, { forecast: 2 })], [[-3, null]], { forecast: fc(1, 2, 4) }),
  ], releases: [] }, now);
  const words = t.joinWords(line, backtest, now);
  assert.equal(words.length, 3);
  assert.match(words[0], /^Closes about /);
  assert.match(words[1], /^8 times in 10 between /);
  assert.equal(words[2], "Past forecasts were off by ×2.2");
  assert.match(t.spoken([line], now)[0].words, /^Issue 22, 1 of 2 done, closes about /);
  assert.equal(t.waitWords(3), "3 wait for you");
  assert.equal(t.waitWords(1), "1 waits for you");
  assert.deepEqual(t.lineWords(line, undefined, now).slice(0, 2), ["#22 Issue 22", "1 of 2 done"]);
  assert.equal(t.dotWords(line.dots[0], now)[0], "#90 Issue 90");
});

test("machines merge each epic and release once", () => {
  const a = { epics: [epic(23, [child(1, { closed: -1 })], [[-2, -1]])], releases: [{ tag: "v2", at: wire(-1), repo: "a/b" }], errors: ["x"] };
  const b = { epics: [epic(23, [child(1, { closed: -1 })], [[-2, -1]])],
    releases: [{ tag: "v1", at: wire(-3), repo: "a/b" }, { tag: "v2", at: wire(-1), repo: "a/b" }], errors: ["x", "y"] };
  const merged = t.mergeTimelines([a, b]);
  assert.equal(merged.epics.length, 1);
  assert.deepEqual(merged.releases.map((r) => r.tag), ["v1", "v2"]);
  assert.deepEqual(merged.errors, ["x", "y"]);
});

test("a child that closed since the last read lands", () => {
  const before = { epics: [epic(24, [child(2, { started: -2 }), child(3, { started: -1 })], [[-2, null]])], releases: [] };
  const after = { epics: [epic(24, [child(2, { started: -2, closed: 0 }), child(3, { started: -1 })], [[-2, null]]),
    epic(25, [child(4, { started: -2, closed: -1 })], [[-2, -1]])], releases: [] };
  // A child the page had not seen yet does not pulse.
  assert.deepEqual(t.landed(before, after), ["github:alexec/Agents#2"]);
});

test("Timeline is a row after Releases in Work", () => {
  const ids = nav.navPages.work.map((p) => p.id);
  assert.deepEqual(ids.slice(-2), ["release", "timeline"]);
  assert.deepEqual(nav.navPages.work.at(-1).draw, { kind: "timeline" });
});
