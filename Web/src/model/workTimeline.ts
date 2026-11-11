// Work ▸ Timeline (#4206), as the window's WorkTimeline in AgentsKitCore (#4173,
// specs/time-stream/wireframe.md sections 2, 7, 9 and 12): the epics as lines that leave the
// releases line when their first child starts and join it when their last child closes, on a
// linear time axis. The range, the lines, their lanes, the marks and the words; the view draws them
// in SVG. Times are milliseconds since 1970.
import type { ForgeLabel, WorkTimeline, WorkTimelineBacktest, WorkTimelineRelease } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { shortAge, shortRef } from "./work";

const ms = (d: number | undefined) => d === undefined ? undefined : fromWireDate(d as never).getTime();
const day = 86_400_000;

/** The toolbar's range. 1 Day and 2 Days keep Now in the centre; Week puts it at three quarters, as
 * the forecast reaches only about 1.5 days ahead (Alex, 2026-11-09, #4173). */
export type TimelineRange = "day" | "twoDays" | "week";
export const timelineRanges: readonly TimelineRange[] = ["day", "twoDays", "week"];
export const rangeTitle: Record<TimelineRange, string> = { day: "1 Day", twoDays: "2 Days", week: "Week" };
export const rangeSpan: Record<TimelineRange, number> = { day, twoDays: 2 * day, week: 7 * day };

/** Where Now is, from the left edge, as a share of the width. */
export const nowAt = (r: TimelineRange) => r === "week" ? 0.75 : 0.5;

/** The window seen when the page opens or Now is clicked. */
export function rangeWindow(r: TimelineRange, now: number): Interval {
  const start = now - rangeSpan[r] * nowAt(r);
  return { start, end: start + rangeSpan[r] };
}

/** A pinch, or ctrl and the wheel, steps the range: apart is a shorter one, together a longer one. */
export function zoomed(r: TimelineRange, zoomIn: boolean): TimelineRange {
  const i = timelineRanges.indexOf(r) + (zoomIn ? -1 : 1);
  return timelineRanges[Math.min(Math.max(i, 0), timelineRanges.length - 1)]!;
}

export interface Interval { start: number; end: number }

/** A time axis: `interval` across `width` pixels. */
export class Axis {
  constructor(readonly interval: Interval, readonly width: number) {}

  x(t: number): number {
    const d = this.interval.end - this.interval.start;
    return d <= 0 ? 0 : (t - this.interval.start) / d * this.width;
  }

  date(x: number): number {
    return this.interval.start + (this.width <= 0 ? 0 : x / this.width * (this.interval.end - this.interval.start));
  }

  /** The hour ticks for a range seen across the width: every 3 hours at 1 Day, 6 at 2 Days, 24 at
   * Week, on the hour of the page's clock. */
  ticks(seen: number): number[] {
    const hours = seen <= day * 1.5 ? 3 : seen <= day * 3 ? 6 : 24;
    const hour = new Date(this.interval.start);
    hour.setMinutes(0, 0, 0);
    const out: number[] = [];
    // Each hour on the clock, so a tick stays on the hour across a change of summer time.
    while (hour.getTime() <= this.interval.end) {
      if (hour.getTime() >= this.interval.start && hour.getHours() % hours === 0) out.push(hour.getTime());
      hour.setHours(hour.getHours() + 1);
    }
    return out;
  }
}

/** How an epic's line ends: joined (its last child closed), dropped (closed as not planned: ✕, no
 * join), forecast (dashed to a hollow ring), waits (children wait for the person: a pill, no join),
 * open (nothing to forecast: it stops at Now). */
export type TimelineEnd = { how: "joined" } | { how: "dropped" } | { how: "forecast" } | { how: "waits"; count: number } | { how: "open" };

/** A child's dot on its line: filled when closed, hollow when forecast. */
export interface TimelineDot { ref: string; number: string; title: string; at: number; closed: boolean; notPlanned: boolean }

/** One line: a segment of an epic. */
export interface TimelineLine {
  id: string;
  epic: string;
  segment: number;
  title: string;
  number: string;
  feature: string | undefined;
  /** The epic's children closed, and all of them. */
  done: number;
  total: number;
  start: number;
  /** The join, the forecast join, the pill, or Now. */
  end: number;
  how: TimelineEnd;
  band: Interval | undefined;
  dots: TimelineDot[];
  /** Children working now: a ring at Now on the line. */
  working: number;
  /** 1, 2, … above the releases line, −1, −2, … below. */
  lane: number;
}

/** The figures of a label: `#n · 6 of 8`. */
export const figures = (l: TimelineLine) => `${l.number} · ${l.done} of ${l.total}`;
/** The label: the name, then the figures. */
export const label = (l: TimelineLine) => `${l.title}  ${figures(l)}`;
/** Whether a line runs on (it has not ended). */
export const isOpen = (l: TimelineLine) => l.how.how === "forecast" || l.how.how === "waits" || l.how.how === "open";

/** The lines of a timeline, past and forecast, as section 7 says: one per segment, an epic with no
 * children not drawn, a line that has not started not drawn unless it is forecast. `forecast` off
 * draws the past only: an open line stops at Now. */
export function timelineLines(timeline: WorkTimeline, now: number, forecast = true): TimelineLine[] {
  return timeline.epics.flatMap((epic) => {
    if (epic.children.length === 0) return [];
    const total = epic.children.length;
    const done = epic.children.filter((c) => c.closedAt !== undefined).length;
    const last = epic.segments.length - 1;
    return epic.segments.flatMap((segment, i): TimelineLine[] => {
      const open = segment.closedAt === undefined && i === last;
      // The children of this line: those that closed in it, and the open ones on the open line.
      const next = i < last ? ms(epic.segments[i + 1]!.startedAt) : undefined;
      const mine = epic.children.filter((child) => {
        const closed = ms(child.closedAt);
        if (closed !== undefined) {
          const from = i === 0 ? -Infinity : ms(segment.startedAt) ?? -Infinity;
          return closed >= from && closed < (next ?? Infinity);
        }
        return open;
      });
      const forecastStarts = mine.flatMap((c) => c.forecastAt === undefined ? [] : [ms(c.forecastAt)!]);
      const start = ms(segment.startedAt) ?? (forecast && forecastStarts.length > 0 ? Math.min(...forecastStarts) : undefined);
      if (start === undefined) return [];
      let how: TimelineEnd = { how: "joined" };
      let end = ms(segment.closedAt) ?? now;
      let band: Interval | undefined;
      const waiting = mine.filter((c) => c.closedAt === undefined && c.waitsForPerson === true).length;
      const f = epic.forecast;
      if (open) {
        if (waiting > 0) {
          how = { how: "waits", count: waiting };
          if (forecast && f) end = Math.max(ms(f.mid)!, now);
        } else if (forecast && f) {
          how = { how: "forecast" };
          end = Math.max(ms(f.mid)!, now);
          const low = ms(f.low)!, high = ms(f.high)!;
          band = { start: Math.min(low, high), end: Math.max(low, high) };
        } else {
          how = { how: "open" };
        }
      } else if (epic.stateReason === "not_planned" || (epic.closedAt !== undefined && epic.item.state === "closed"
                 && mine.every((c) => c.stateReason === "not_planned"))) {
        how = { how: "dropped" };
      }
      end = Math.max(end, start);
      const dots = mine.flatMap((child): TimelineDot[] => {
        const number = shortRef(child.item.node.ref);
        const base = { ref: child.item.node.ref, number, title: child.item.title };
        const closed = ms(child.closedAt);
        // A child closed before its line forked sits at the fork (section 12, item 7).
        if (closed !== undefined) {
          return [{ ...base, at: Math.min(Math.max(closed, start), end), closed: true, notPlanned: child.stateReason === "not_planned" }];
        }
        const at = ms(child.forecastAt);
        if (!forecast || child.waitsForPerson === true || at === undefined) return [];
        return [{ ...base, at: Math.min(Math.max(at, Math.max(start, now)), end), closed: false, notPlanned: false }];
      });
      const working = open ? mine.filter((c) => c.closedAt === undefined && c.startedAt !== undefined && c.waitsForPerson !== true).length : 0;
      return [{
        id: `${epic.item.node.ref}/${i}`, epic: epic.item.node.ref, segment: i, title: epic.item.title,
        number: shortRef(epic.item.node.ref), feature: epic.item.feature, done, total, start, end, how, band,
        dots: dots.sort((a, b) => a.at - b.at), working, lane: 0,
      }];
    });
  });
}

/** Where a line's drawing ends: its end or its band's, whichever is later. */
const reach = (l: TimelineLine) => Math.max(l.end, l.band?.end ?? l.end);

/** Only the lines that overlap the window (Alex, 2026-11-08). A line that waits for the person has
 * no end, so it is drawn while it is open. */
export function overlapping(lines: readonly TimelineLine[], window: Interval): TimelineLine[] {
  return lines.filter((l) => l.start <= window.end && (l.how.how === "waits" ? Infinity : reach(l)) >= window.start);
}

/** The fork's and the join's width, in pixels: 12 and 4 for each lane (section 12, item 2). */
export const riser = (lane: number) => 12 + 4 * Math.abs(lane);

/** The lanes nearest the releases line first, above and below in turn: 1, −1, 2, −2, … */
export const laneAt = (i: number) => i % 2 === 0 ? i / 2 + 1 : -(Math.floor(i / 2) + 1);

const byStart = (a: TimelineLine, b: TimelineLine) => a.start - b.start || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

/** Put each line on the free lane nearest the releases line, sorted by start (section 9). A lane is
 * free when its last line has joined and that line's label has ended: `labelWidth` measures a label
 * in pixels, and `gap` keeps a little air after each. */
export function layout(lines: readonly TimelineLine[], axis: Axis, labelWidth: (l: TimelineLine) => number, gap = 8): TimelineLine[] {
  const busy = new Map<number, number>();
  return [...lines].sort(byStart).map((line) => {
    const startX = axis.x(line.start);
    let i = 0;
    while ((busy.get(laneAt(i)) ?? -Infinity) > startX) i++;
    const lane = laneAt(i);
    const labelEnd = startX + riser(lane) + labelWidth(line);
    const ends = line.how.how === "waits" ? Infinity : Math.max(axis.x(line.end), line.band ? axis.x(line.band.end) : -Infinity);
    busy.set(lane, Math.max(labelEnd, ends) + gap);
    return { ...line, lane };
  });
}

/** The lanes in use, above and below: the plot is as tall as the higher of the two sides. */
export function lanes(lines: readonly TimelineLine[]): { above: number; below: number } {
  return { above: Math.max(0, ...lines.map((l) => l.lane)), below: Math.max(0, ...lines.map((l) => -l.lane)) };
}

/** A join on the releases line: one ring, or one ring with a count for joins within 6 px of each
 * other (section 12, item 5). `lines` are the lines' ids. */
export interface TimelineJoin { at: number; lines: string[]; forecast: boolean }

export function joins(lines: readonly TimelineLine[], axis: Axis, within = 6): TimelineJoin[] {
  const rings = lines.flatMap((l): TimelineJoin[] => l.how.how === "joined" ? [{ at: l.end, lines: [l.id], forecast: false }]
    : l.how.how === "forecast" ? [{ at: l.end, lines: [l.id], forecast: true }] : []).sort((a, b) => a.at - b.at);
  const out: TimelineJoin[] = [];
  for (const ring of rings) {
    const prev = out[out.length - 1];
    if (prev && prev.forecast === ring.forecast && axis.x(ring.at) - axis.x(prev.at) < within) prev.lines.push(...ring.lines);
    else out.push({ ...ring, lines: [...ring.lines] });
  }
  return out;
}

/** How far a line's label may run from `x`: the whole line, to its end (Alex, 2026-11-10). It runs
 * past Now and over its band, on its halo; a pill where the line waits is after its end. */
export function labelRoom(line: TimelineLine, x: number, axis: Axis): number {
  return axis.x(line.end) - x;
}

/** Where a dot is drawn: at its time, held to the stretch of the line that is on its lane, so no dot
 * is on the fork's or the join's curve, off the line (Alex, 2026-11-10). */
export function dotX(dot: TimelineDot, line: TimelineLine, axis: Axis): number {
  const r = riser(line.lane);
  const sx = axis.x(line.start), ex = Math.max(axis.x(line.end), sx);
  const from = sx + r;
  const to = line.how.how === "joined" || line.how.how === "forecast" ? Math.max(ex - r, from) : Math.max(ex, from);
  return Math.min(Math.max(axis.x(dot.at), from), to);
}

/** What a label says: the name, whole or cut short with "…", or "" for none; then the figures. */
export interface LabelWords {
  title: string;
  figures: string;
}

/** A label's words as one string. */
export const labelText = (w: LabelWords) => (w.title ? `${w.title}  ${w.figures}` : w.figures);

/** The label that fits `room`: the whole one, then the name cut short with "…" before the figures,
 * then the figures alone, then nothing. */
export function fitLabel(line: TimelineLine, room: number, measure: (s: string) => number): LabelWords | undefined {
  const f = figures(line);
  if (measure(label(line)) <= room) return { title: line.title, figures: f };
  const title = Array.from(line.title);
  let best: string | undefined;
  let low = 1;
  let high = title.length - 1;
  while (low <= high) {
    const mid = Math.floor((low + high) / 2);
    const cut = title.slice(0, mid).join("").trim();
    if (cut && measure(`${cut}…  ${f}`) <= room) {
      best = `${cut}…`;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  if (best) return { title: best, figures: f };
  if (measure(f) <= room) return { title: "", figures: f };
  return undefined;
}

// Colours

/** A feature's colour, as an index into the page's palette, the same every time for the same name
 * (FNV-1a of its lower-cased UTF-8, as the window has it). No feature takes the last one (grey). */
export function colourIndex(feature: string | undefined, count: number): number {
  if (!feature || count <= 1) return Math.max(count - 1, 0);
  let hash = 2_166_136_261;
  for (const byte of new TextEncoder().encode(feature.toLowerCase())) hash = Math.imul(hash ^ byte, 16_777_619) >>> 0;
  return hash % (count - 1);
}

// Hit testing

/** What the pointer is on: a dot within 10 px, else a join or a release, else a line within 8 px. */
export type TimelineHit =
  | { kind: "dot"; line: TimelineLine; dot: TimelineDot }
  | { kind: "line"; line: TimelineLine }
  | { kind: "join"; join: TimelineJoin }
  | { kind: "release"; release: WorkTimelineRelease };

/** `trunk` is the releases line's y; a lane is `laneHeight` from the next. */
export function hit(p: { x: number; y: number }, lines: readonly TimelineLine[], releases: readonly WorkTimelineRelease[],
                    axis: Axis, trunk: number, laneHeight: number): TimelineHit | undefined {
  const y = (lane: number) => trunk - lane * laneHeight;
  let best: [number, TimelineHit] | undefined;
  for (const line of lines) {
    for (const dot of line.dots) {
      const d = Math.hypot(dotX(dot, line, axis) - p.x, y(line.lane) - p.y);
      if (d <= 10 && d < (best?.[0] ?? Infinity)) best = [d, { kind: "dot", line, dot }];
    }
  }
  if (best) return best[1];
  for (const join of joins(lines, axis)) {
    const d = Math.hypot(axis.x(join.at) - p.x, trunk - p.y);
    if (d <= 10 && d < (best?.[0] ?? Infinity)) best = [d, { kind: "join", join }];
  }
  for (const release of releases) {
    const d = Math.hypot(axis.x(ms(release.at)!) - p.x, trunk - p.y);
    if (d <= 10 && d < (best?.[0] ?? Infinity)) best = [d, { kind: "release", release }];
  }
  if (best) return best[1];
  for (const line of lines) {
    const from = axis.x(line.start) + riser(line.lane);
    const joinsTrunk = line.how.how === "joined" || line.how.how === "forecast";
    const to = joinsTrunk ? axis.x(line.end) - riser(line.lane) : axis.x(line.end);
    const dy = Math.abs(y(line.lane) - p.y);
    if (dy <= 8 && p.x >= from - 8 && p.x <= Math.max(from, to) + 8 && dy < (best?.[0] ?? Infinity)) best = [dy, { kind: "line", line }];
  }
  return best?.[1];
}

// Words

const sameDay = (a: number, b: number) => new Date(a).toDateString() === new Date(b).toDateString();

/** A time on the page's clock: "6:38 PM" today, "Sun 6:38 PM" on another day. */
export function timeWords(t: number, now: number): string {
  return new Date(t).toLocaleString(undefined, sameDay(t, now)
    ? { hour: "numeric", minute: "2-digit" } : { weekday: "short", hour: "numeric", minute: "2-digit" });
}

/** "3 wait for you": the pill where a line stops for the person. */
export const waitWords = (count: number) => `${count} wait${count === 1 ? "s" : ""} for you`;

/** "Past forecasts were off by ×2.2". */
export const errorWords = (b: WorkTimelineBacktest) => `Past forecasts were off by ×${b.error.toFixed(1)}`;

/** The hover card on a forecast join (section 12, item 8). */
export function joinWords(line: TimelineLine, backtest: WorkTimelineBacktest | undefined, now: number): string[] {
  const out = [`Closes about ${timeWords(line.end, now)}`];
  if (line.band) out.push(`8 times in 10 between ${timeWords(line.band.start, now)} and ${timeWords(line.band.end, now)}`);
  if (backtest) out.push(errorWords(backtest));
  return out;
}

/** The hover card on a dot. */
export function dotWords(dot: TimelineDot, now: number): string[] {
  const when = timeWords(dot.at, now);
  return [`${dot.number} ${dot.title}`, dot.closed ? (dot.notPlanned ? `Closed as not planned ${when}` : `Closed ${when}`) : `Closes about ${when}`];
}

/** The hover card on a line. */
export function lineWords(line: TimelineLine, backtest: WorkTimelineBacktest | undefined, now: number): string[] {
  const out = [`${line.number} ${line.title}`, `${line.done} of ${line.total} done`];
  switch (line.how.how) {
    case "joined": out.push(`Closed ${timeWords(line.end, now)}`); break;
    case "dropped": out.push("Closed as not planned"); break;
    case "forecast": out.push(...joinWords(line, backtest, now)); break;
    case "waits": { const w = waitWords(line.how.count); out.push(w.charAt(0).toUpperCase() + w.slice(1)); break; }
    case "open": out.push("Open"); break;
  }
  return out;
}

/** The hover card on a join: each of its lines. */
export function joinCardWords(join: TimelineJoin, lines: readonly TimelineLine[], backtest: WorkTimelineBacktest | undefined, now: number): string[] {
  return join.lines.flatMap((id) => {
    const line = lines.find((l) => l.id === id);
    if (!line) return [];
    return line.how.how === "forecast" ? [`${line.number} ${line.title}`, ...joinWords(line, backtest, now)] : lineWords(line, backtest, now);
  });
}

/** The hover card on a release. */
export const releaseWords = (r: WorkTimelineRelease) =>
  [r.tag, `Released ${fromWireDate(r.at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}`];

/** A row of the hover card, on three lines (Alex, 2026-11-10): the state glyph and the title; the label
 * chips, where the wire has them; then the prediction, in the window's words. A release has no glyph. */
export interface CardRow { state?: "open" | "closed"; title: string; labels: ForgeLabel[]; line: string }

/** "2 h ago", or "just now". */
function agoWords(t: number, now: number): string {
  const age = shortAge((now - t) / 1000);
  return age === "now" ? "just now" : `${age} ago`;
}

/** On a dot: "#4250 · closed 2 h ago" or "#4250 · closes about 5:00 PM". */
export function dotLine(dot: TimelineDot, now: number): string {
  const state = dot.closed ? `${dot.notPlanned ? "closed as not planned" : "closed"} ${agoWords(dot.at, now)}` : `closes about ${timeWords(dot.at, now)}`;
  return `${dot.number} · ${state}`;
}

/** On an epic's line or its join: "#4250 · 11 of 16 · closes about 5:00 PM · 3:00 PM–9:00 PM, 8 in 10". */
export function lineLine(line: TimelineLine, now: number): string {
  const out = [figures(line)];
  switch (line.how.how) {
    case "joined": out.push(`closed ${agoWords(line.end, now)}`); break;
    case "dropped": out.push("closed as not planned"); break;
    case "forecast":
      out.push(`closes about ${timeWords(line.end, now)}`);
      if (line.band) out.push(`${timeWords(line.band.start, now)}–${timeWords(line.band.end, now)}, 8 in 10`);
      break;
    case "waits": out.push(waitWords(line.how.count)); break;
    case "open": out.push("open"); break;
  }
  return out.join(" · ");
}

/** The hover card's rows: one for a dot, a line or a release, one for each line of a join. The
 * backtest is not in it: it is the title line's help. */
export function cardRows(h: TimelineHit, lines: readonly TimelineLine[], timeline: WorkTimeline, now: number): CardRow[] {
  const lineRow = (l: TimelineLine): CardRow => {
    const epic = timeline.epics.find((e) => e.item.node.ref === l.epic);
    return { state: (epic?.item.state ?? (isOpen(l) ? "open" : "closed")) === "open" ? "open" : "closed", title: l.title,
      labels: epic?.item.labels ?? [], line: lineLine(l, now) };
  };
  switch (h.kind) {
    case "dot": {
      const child = timeline.epics.flatMap((e) => e.children).find((c) => c.item.node.ref === h.dot.ref);
      return [{ state: h.dot.closed ? "closed" : "open", title: h.dot.title, labels: child?.item.labels ?? [], line: dotLine(h.dot, now) }];
    }
    case "line": return [lineRow(h.line)];
    case "join": return h.join.lines.flatMap((id) => { const l = lines.find((x) => x.id === id); return l ? [lineRow(l)] : []; });
    case "release": return [{ title: h.release.tag, labels: [], line: `${h.release.repo} · released ${agoWords(ms(h.release.at)!, now)}` }];
  }
}

/** The epics with a line in `window`. */
export const epicCount = (lines: readonly TimelineLine[], window: Interval) => new Set(overlapping(lines, window).map((l) => l.epic)).size;

/** The title line above the plot (note 32): "Agents · 6 epics in these 2 days"; no project when a
 * menu names it. Its help is the forecast's backtest (Alex, 2026-11-10). */
export function titleWords(project: string, epics: number, r: TimelineRange): string {
  const these: Record<TimelineRange, string> = { day: "these 24 hours", twoDays: "these 2 days", week: "these 7 days" };
  const count = `${epics} epic${epics === 1 ? "" : "s"} in ${these[r]}`;
  return project ? `${project} · ${count}` : count;
}

/** What a screen reader reads, a row per line in time order (section 5): "Azure DevOps, 3 of 7
 * done, closes about 6:00 PM". */
export function spoken(lines: readonly TimelineLine[], now: number): { line: TimelineLine; words: string }[] {
  return [...lines].sort(byStart).map((line) => {
    const end = line.how.how === "joined" ? `closed ${timeWords(line.end, now)}`
      : line.how.how === "dropped" ? "closed as not planned"
      : line.how.how === "forecast" ? `closes about ${timeWords(line.end, now)}`
      : line.how.how === "waits" ? waitWords(line.how.count) : "open";
    return { line, words: `${line.title}, ${line.done} of ${line.total} done, ${end}` };
  });
}

/** Several machines' timelines of one project as one: each epic and release once. */
export function mergeTimelines(timelines: readonly WorkTimeline[]): WorkTimeline {
  const out: WorkTimeline = { epics: [], releases: [] };
  const epics = new Set<string>(), releases = new Set<string>();
  for (const t of timelines) {
    out.epics.push(...t.epics.filter((e) => !epics.has(e.item.node.ref) && epics.add(e.item.node.ref)));
    out.releases.push(...t.releases.filter((r) => !releases.has(`${r.repo}@${r.tag}`) && releases.add(`${r.repo}@${r.tag}`)));
    if (out.timeZone === undefined && t.timeZone !== undefined) out.timeZone = t.timeZone;
    if (out.backtest === undefined && t.backtest !== undefined) out.backtest = t.backtest;
    for (const e of t.errors ?? []) if (!(out.errors ?? []).includes(e)) out.errors = [...out.errors ?? [], e];
  }
  out.releases.sort((a, b) => a.at - b.at);
  return out;
}

/** The epic a line's id (`<ref>/<segment>`) is of. */
export const epicOf = (id: string) => id.slice(0, id.lastIndexOf("/"));

/** The children that closed since the last read of the same epics: their dots pulse once. */
export function landed(before: WorkTimeline, after: WorkTimeline): string[] {
  const was = new Set(before.epics.flatMap((e) => e.children).filter((c) => c.closedAt !== undefined).map((c) => c.item.node.ref));
  const known = new Set(before.epics.flatMap((e) => e.children).map((c) => c.item.node.ref));
  return after.epics.flatMap((e) => e.children)
    .filter((c) => c.closedAt !== undefined && !was.has(c.item.node.ref) && known.has(c.item.node.ref)).map((c) => c.item.node.ref);
}

export const noEpics = "No epic has work in this time. An epic is drawn once one of its children starts.";
export const noProject = "Timeline shows a project’s epics. Add a folder to a project to see them.";
export const noMachine = "No machine draws the timeline yet. Update Agents on a machine to see it.";
