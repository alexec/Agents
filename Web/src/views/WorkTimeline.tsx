// Work ▸ Timeline (#4206), as the window's WorkTimelinePane (#4173, specs/time-stream/wireframe.md):
// time across, the releases line in the middle, an epic's line leaving it when its first child
// starts and joining it when its last one closes; the forecast dashed after Now. Drawn in SVG; the
// lanes and the marks come from model/workTimeline. The state lives for the tab, so Back from an
// issue's page finds the Timeline as it was left.
import { signal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import type { ForgeItem, LineageSessionOn, WorkTimeline as Timeline } from "../protocol/generated";
import { Capability } from "../protocol/capabilities.generated";
import { fromWireDate, toWireDate } from "../protocol/dates";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { boardChoices, boardName, withBoard, type WorkProject } from "../model/work";
import { boards, forgeHosts, loadBoards } from "../model/workLists";
import {
  Axis, cardRows, colourIndex, dotX, epicCount, epicOf, epicRows, errorWords, fitLabel, hit, isOpen, joins, label, labelText, lastJoined,
  lastJoinedWords, landed as landedRefs, lanes, layout, labelRoom, mergeTimelines, noEpicsWords, noMachine, noProject, noProjectTitle,
  overlapping, rangeSpan, rangeTitle, rangeWindow, riser, sessionNodes, showTheWeek, startedBySessions, timelineLines, workingNow, timelineRanges,
  titleWords, waitWords, zoomed, type Interval, type TimelineHit, type TimelineLine, type TimelineRange,
} from "../model/workTimeline";
import { go } from "../route";
import { Choice, workProjects } from "./Work";
import { EmptyState, ErrorStrip, FilterMenu, LabelChip, PlaceholderRows, RefreshButton, StateIcon } from "./WorkParts";

const range = signal<TimelineRange>("twoDays");
/** The project, by id; "" until one is picked, then the first one. */
const project = signal("");
/** The board the epics are narrowed to (#3282), by its url; "" for every board. */
const board = signal("");
/** Where the window is: Now, until the plot is scrolled past an edge. */
const anchor = signal(Date.now());
const timeline = signal<Timeline | null>(null);
const problem = signal<string | null>(null);
const asked = signal(0);
/** Now was clicked: the plot scrolls back to it. */
const nowAsked = signal(0);
/** Children that closed since the last read: their dots pulse once. */
const landed = signal<ReadonlySet<string>>(new Set());
/** A read of `work/timeline` runs: Refresh spins (note 30). */
const reading = signal(false);
/** Every machine failed the last read: the plot is the one before it, dimmed under the strip (S12). */
const stale = signal(false);
let read: string | undefined;
/**
 * Every machine's sessions on the epics and their children, from the control plane's merged copy
 * (#4276): a sleeping machine's sessions still start their children.
 */
const sessions = signal<LineageSessionOn[]>([]);
/** The machines' timelines as one, before the sessions start their children. */
let fromMachines: Timeline | undefined;

const laneHeight = 60;
const axisHeight = 26;

/** The system colours for the features, as the window's palette; the last, grey, for an epic with none. */
const palette = ["#007aff", "#af52de", "#ff2d55", "#ff9500", "#34c759", "#30b0c7", "#5856d6", "#00c7be", "#a2845e", "#32ade6", "#ff3b30", "#8e8e93"];

/** What the plot holds: the window, and a range's width on each side of it to scroll through. */
function content(): Interval {
  const w = rangeWindow(range.value, anchor.value);
  return { start: w.start - rangeSpan[range.value], end: w.end + rangeSpan[range.value] };
}

/** The machines that draw the Timeline (`work.timeline/1`). */
const timelineHosts = (store: Store) => forgeHosts(store).filter((h) => store.has(h.id, Capability.workTimeline1));

/** The projects the Timeline can draw: those with a folder on a machine that draws it. */
function timelineProjects(store: Store): WorkProject[] {
  const hosts = new Set<string>(timelineHosts(store).map((h) => h.id));
  return workProjects(store).filter((p) => [...p.folders].some((f) => hosts.has(f.slice(0, f.indexOf("|")))));
}

async function loadTimeline(store: Store) {
  const projects = timelineProjects(store);
  const chosen = projects.find((p) => p.id === project.value) ?? projects[0];
  const span = content();
  const key = `${asked.value} ${chosen?.id} ${board.value} ${range.value} ${span.start} ${timelineHosts(store).map((h) => h.id).join(",")}`;
  if (read === key && timeline.value !== null) return;
  read = key;
  if (!chosen) { timeline.value = { epics: [], releases: [] }; stale.value = false; return; }
  if (project.value !== chosen.id) project.value = chosen.id;
  const on = new Set<string>([...chosen.folders].map((f) => f.slice(0, f.indexOf("|"))));
  const hosts = timelineHosts(store).filter((h) => on.has(h.id));
  const chosenBoard = board.value;
  reading.value = true;
  const got = await Promise.all(hosts.map(async (h) => {
    try {
      const t = await store.link.call("work/timeline", { project: chosen.id, from: toWireDate(new Date(span.start)), to: toWireDate(new Date(span.end)) }, h.id);
      // A board narrows to its epics: the forge says which they are.
      let refs: string[] | undefined;
      if (chosenBoard) {
        try {
          const list = await store.link.call("forge/issues", withBoard({ state: "all", label: "epic", limit: 100 }, chosenBoard), h.id);
          refs = list.items.map((i: ForgeItem) => i.node.ref);
        } catch { refs = []; }
      }
      return { t, refs };
    } catch (e) {
      return { problem: hosts.length > 1 ? `${h.name}: ${describe(e)}` : describe(e) };
    }
  }));
  if (read !== key) return;
  reading.value = false;
  const failed = got.flatMap((g) => g.problem ? [g.problem] : []);
  problem.value = failed.length === 0 ? null : failed.join("\n");
  // With every machine failing, the last plot stays, dimmed.
  stale.value = hosts.length > 0 && failed.length === hosts.length && timeline.value !== null;
  if (stale.value) return;
  const merged = mergeTimelines(got.flatMap((g) => g.t ? [g.t] : []));
  const epics = chosenBoard ? new Set(got.flatMap((g) => g.refs ?? [])) : undefined;
  if (epics) merged.epics = merged.epics.filter((e) => epics.has(e.item.node.ref));
  if (timeline.value) {
    const fresh = landedRefs(timeline.value, merged);
    if (fresh.length > 0) landed.value = new Set(fresh);
  }
  fromMachines = merged;
  sessions.value = await readSessions(store, merged);
  if (read !== key || fromMachines !== merged) return;
  timeline.value = startedBySessions(merged, sessions.value);
}

/** Every machine's sessions on the timeline's epics and children, from the control plane's merged copy (#4276); none from one before it. */
async function readSessions(store: Store, t: Timeline): Promise<LineageSessionOn[]> {
  const nodes = sessionNodes(t);
  if (nodes.length === 0) return [];
  try {
    return (await store.link.call("lineage/sessionsOn", { nodes })).sessions;
  } catch {
    return [];
  }
}

/** The sessions again, on control/lineageChanged (#4276): a session that starts on a child on any machine starts it, with no read of the forges. */
async function readSessionsAgain(store: Store) {
  const machines = fromMachines;
  if (!machines) return;
  const got = await readSessions(store, machines);
  if (fromMachines !== machines) return;
  sessions.value = got;
  timeline.value = startedBySessions(machines, got);
}

function goToNow() {
  anchor.value = Date.now();
  nowAsked.value++;
}

/** A label's width, as the plot draws it. */
let measurer: CanvasRenderingContext2D | null | undefined;
function measure(text: string): number {
  if (measurer === undefined) measurer = typeof document === "undefined" ? null : document.createElement("canvas").getContext("2d");
  if (!measurer) return text.length * 6.5;
  measurer.font = "11px -apple-system, BlinkMacSystemFont, system-ui, sans-serif";
  return measurer.measureText(text).width;
}

export function WorkTimeline({ store }: { store: Store }) {
  const hosts = timelineHosts(store);
  const projects = timelineProjects(store);
  const hostKey = hosts.map((h) => h.id).join(",");
  const projectKey = projects.map((p) => p.id).join(",");
  useEffect(() => { void loadTimeline(store); }, [asked.value, project.value, board.value, range.value, anchor.value, hostKey, projectKey]);
  useEffect(() => { void loadBoards(store); }, [hostKey]);
  // A machine sent new lineage to the control plane (#4276): the sessions again, no polling.
  const lineageChanges = store.lineageChanges.value;
  useEffect(() => {
    if (lineageChanges === 0) return;
    const t = setTimeout(() => { void readSessionsAgain(store); }, 500);
    return () => clearTimeout(t);
  }, [lineageChanges]);
  // Read again every five minutes, so closes land while the page is open.
  useEffect(() => {
    const t = setInterval(() => { asked.value++; }, 300_000);
    return () => clearInterval(t);
  }, [project.value]);
  const t = timeline.value;
  const problems = [...problem.value ? problem.value.split("\n") : [], ...t?.errors ?? []];
  const refresh = () => { asked.value++; void loadBoards(store, true); };
  return (
    <div class="work-list timeline-page">
      {/* The filter bar of parts.md section 4 (note 31 and 32): Project and Board at the leading edge, the title line, then
          the range and Now at the trailing edge, where Sort is on a list, and Refresh (note 30). */}
      <div class="work-filters timeline-bar" role="group" aria-label="Timeline">
        <div class="work-menus">
          {projects.length > 1 && (
            <FilterMenu label="Project" value={project.value} choices={projects.map((p) => ({ value: p.id, words: p.name }))}
              onPick={(id) => { project.value = id; }} />
          )}
          <Choice label="Board" any="All boards" value={board.value} options={boardChoices(boards.value, board.value)}
            words={(url) => boardName(boards.value, url)} onChange={(url) => { board.value = url; }} />
          {/* The forecast is always drawn (Alex, 2026-11-10): how past forecasts did is the title line's help. */}
          {t && projects.length > 0 && (
            <span class="quiet timeline-title" title={t.backtest ? `The forecast after now. ${errorWords(t.backtest)}.` : "The forecast after now"}>
              {titleWords(projects.length > 1 ? "" : projects[0]!.name,
                epicCount(timelineLines(t, Date.now()), rangeWindow(range.value, anchor.value)), range.value)}
            </span>
          )}
        </div>
        <span class="timeline-trailing">
          <div class="diff-choice" role="group" aria-label="Range">
            {timelineRanges.map((r) => (
              <button key={r} type="button" aria-pressed={range.value === r} onClick={() => { range.value = r; goToNow(); }}>{rangeTitle[r]}</button>
            ))}
          </div>
          <button type="button" class="timeline-now-button" onClick={goToNow} title="Back to now">Now</button>
        </span>
        <RefreshButton busy={reading.value} onClick={refresh} />
      </div>
      {hosts.length === 0 ? <EmptyState kind="timeline" title={noMachine} />
        : projects.length === 0 ? <EmptyState kind="timeline" title={noProjectTitle} line={noProject} />
        : (
          <>
            <ErrorStrip lines={problems} retry={refresh} />
            <Plot timeline={t ?? { epics: [], releases: [] }} loading={t === null} dim={stale.value}
              projectName={projects.find((p) => p.id === project.value)?.name ?? ""}
              working={t ? workingNow(t, sessions.value, Object.values(store.agents.value).flat()) : new Set()} />
          </>
        )}
    </div>
  );
}

/** The minute, so Now moves while the page is open. */
function useMinute(): number {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 60_000);
    return () => clearInterval(t);
  }, []);
  return now;
}

interface Hover { hit: TimelineHit; x: number; y: number }

/** The plot; under 700 px the list of epics in its place (note 36). `loading`: the first read, the releases line and
 * Now with grey lanes that shimmer (S10). `dim`: the last plot under the error strip (S12). `working`: the epics and
 * children a session is in a turn on now (#4265); their open lines pulse. */
function Plot({ timeline: t, projectName, loading, dim, working }: {
  timeline: Timeline; projectName: string; loading: boolean; dim: boolean; working: ReadonlySet<string>;
}) {
  const now = useMinute();
  const scroller = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const [offset, setOffset] = useState(0);
  const [hover, setHover] = useState<Hover | null>(null);
  const settle = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const pinch = useRef(0);

  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setSize({ width: el.clientWidth, height: el.clientHeight }));
    ro.observe(el);
    setSize({ width: el.clientWidth, height: el.clientHeight });
    return () => ro.disconnect();
  }, []);

  // A card is for what was under the pointer: a new range or window draws other things.
  useEffect(() => setHover(null), [range.value, anchor.value, nowAsked.value]);

  const visible = Math.max(size.width, 1);
  const span = content();
  const axis = new Axis(span, visible * (span.end - span.start) / rangeSpan[range.value]);
  const lines = layout(overlapping(timelineLines(t, now, true, working), span), axis, (l) => measure(label(l)));
  const { above, below } = lanes(lines);
  const sides = Math.max(above, below, 2);
  const height = Math.max((2 * sides + 2) * laneHeight, size.height - axisHeight);
  const trunk = height / 2;

  // The window starts a screen in: a range's width is before it. Up and down, the releases line in the middle.
  const scrollTo = (x: number) => {
    const el = scroller.current;
    if (!el) return;
    el.scrollLeft = x;
    setOffset(x);
  };
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el || size.width === 0) return;
    scrollTo(visible);
    el.scrollTop = Math.max((height + axisHeight - el.clientHeight) / 2, 0);
  }, [nowAsked.value, size.width === 0]);

  // Past an edge of what the plot holds, the window moves by a range, and the plot with it.
  const onScroll = () => {
    const el = scroller.current;
    if (!el) return;
    setOffset(el.scrollLeft);
    clearTimeout(settle.current);
    settle.current = setTimeout(() => {
      const x = el.scrollLeft;
      if (x < visible * 0.05) {
        anchor.value -= rangeSpan[range.value];
        scrollTo(x + visible);
      } else if (x > axis.width - visible * 1.05 && axis.width > visible * 2) {
        anchor.value += rangeSpan[range.value];
        scrollTo(x - visible);
      }
    }, 150);
  };

  // A pinch (ctrl and the wheel, as browsers send it) steps the range: apart is closer in, together further out.
  const onWheel = (e: WheelEvent) => {
    if (!e.ctrlKey) return;
    e.preventDefault();
    pinch.current += e.deltaY;
    if (Math.abs(pinch.current) > 40) {
      range.value = zoomed(range.value, pinch.current < 0);
      pinch.current = 0;
      goToNow();
    }
  };
  useEffect(() => {
    const el = scroller.current;
    el?.addEventListener("wheel", onWheel, { passive: false });
    return () => el?.removeEventListener("wheel", onWheel);
  });

  const point = (e: MouseEvent) => {
    const r = (e.currentTarget as SVGElement).getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };
  const hitAt = (p: { x: number; y: number }) => hit(p, lines, t.releases, axis, trunk, laneHeight);
  const open = (h: TimelineHit) => {
    switch (h.kind) {
      case "dot": go({ nav: "work", section: "issue", item: h.dot.ref }); break;
      case "line": go({ nav: "work", section: "issue", item: h.line.epic }); break;
      case "join": if (h.join.lines[0]) go({ nav: "work", section: "issue", item: epicOf(h.join.lines[0]) }); break;
      case "release": if (h.release.url) window.open(h.release.url, "_blank", "noopener"); break;
    }
  };

  const d = new Drawing(lines, t, axis, now, trunk, height, offset, visible, projectName);
  const win = rangeWindow(range.value, anchor.value);
  const rows = epicRows(timelineLines(t, now), win, now);
  const last = rows.length === 0 && !loading ? lastJoined(t, win.start) : undefined;
  return (
    <div class={`timeline${dim ? " dim" : ""}`}>
      <div class="timeline-scroll" ref={scroller} onScroll={onScroll}>
        <div class="timeline-content" style={{ width: `${axis.width}px` }}>
          <svg class={`timeline-plot${hover ? " pointing" : ""}`} width={axis.width} height={height} aria-hidden="true"
            onMouseMove={(e) => { const p = point(e); const h = hitAt(p); setHover(h ? { hit: h, ...p } : null); }}
            onMouseLeave={() => setHover(null)}
            onClick={(e) => { const h = hitAt(point(e)); if (h) open(h); }}>
            {d.plot()}
            {loading && d.placeholders()}
          </svg>
          {hover && <Card hover={hover} lines={lines} timeline={t} now={now} right={offset + visible} />}
          <svg class="timeline-axis" width={axis.width} height={axisHeight} aria-hidden="true">{d.axisMarks()}</svg>
        </div>
      </div>
      {/* S11: no epic in the window, and the way to a wider one. */}
      {rows.length === 0 && !loading && (
        <div class="timeline-empty" role="status">
          <span class="strong">{noEpicsWords(range.value)}</span>
          {last !== undefined && <span class="quiet">{lastJoinedWords(last, now)}</span>}
          {range.value !== "week" && <button type="button" onClick={() => { range.value = "week"; goToNow(); }}>{showTheWeek}</button>}
        </div>
      )}
      {/* The list of epics (note 36): what a screen reader reads over the plot, and the Timeline itself under 700 px, where
          a plot of 24 h is not readable. In the order they close; a tap opens the epic's page. */}
      <div class="timeline-list">
        <p class="timeline-list-now small"><span class="strong">Now</span> · {new Date(now).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</p>
        {loading ? <PlaceholderRows /> : rows.length > 0 && (
          <ul class="work-rows" aria-label="Epics">
            {rows.map(({ line, line2 }) => (
              <li key={line.id}>
                <button type="button" class="timeline-list-row" style={{ "--c": d.colour(line) }}
                  aria-label={`${line.title}, ${line.done} of ${line.total} done, ${line2}`}
                  onClick={() => go({ nav: "work", section: "issue", item: line.epic })}>
                  <span class="edge" aria-hidden="true" />
                  <span class="work-row-main">
                    <span class="title strong">{line.title}</span>
                    <span class={`quiet small${line.how.how === "waits" ? " waits" : ""}`}>{line2}</span>
                  </span>
                  <span class="timeline-list-progress small quiet" aria-hidden="true">
                    <span class="track"><span class="fill" style={{ width: `${line.total ? Math.round(100 * line.done / line.total) : 0}%` }} /></span>
                    {line.done} of {line.total}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

/** The card beside the pointer, on the left of it near the plot's right edge, so it stays in sight. A row on three
 * lines (Alex, 2026-11-10): the title; the label chips, where the wire has them; the prediction. A join has a row
 * for each of its lines. */
function Card({ hover, lines, timeline: t, now, right }: { hover: Hover; lines: TimelineLine[]; timeline: Timeline; now: number; right: number }) {
  return (
    <div class="timeline-card" style={hover.x + 14 + 370 > right
      ? { left: `${hover.x - 14}px`, transform: "translateX(-100%)", top: `${hover.y + 14}px` }
      : { left: `${hover.x + 14}px`, top: `${hover.y + 14}px` }}>
      {cardRows(hover.hit, lines, t, now).map((row, i) => (
        <div key={i} class="timeline-card-row">
          <div class="timeline-card-title">
            {row.state && <StateIcon kind="issue" state={row.state} size={14} />}<span class="strong">{row.title}</span>
          </div>
          {row.labels.length > 0 && (
            <div class="work-chips">
              {row.labels.slice(0, 3).map((l) => <LabelChip key={l.name} label={l} />)}
              {row.labels.length > 3 && <span class="work-chips-more quiet small">+{row.labels.length - 3}</span>}
            </div>
          )}
          <div class="quiet small timeline-card-line">{row.line}</div>
        </div>
      ))}
    </div>
  );
}

/** What one frame of the plot draws: the window, and a screen on each side of it. */
class Drawing {
  readonly nowX: number;
  readonly shown: TimelineLine[];

  constructor(readonly lines: TimelineLine[], readonly t: Timeline, readonly axis: Axis, readonly now: number, readonly trunk: number,
              readonly height: number, readonly offset: number, readonly visible: number, readonly project: string) {
    this.nowX = axis.x(now);
    this.shown = lines.filter((l) => axis.x(l.start) <= this.seenTo && axis.x(Math.max(l.end, l.band?.end ?? l.end)) >= this.seenFrom);
  }

  get seenFrom() { return this.offset - this.visible; }
  get seenTo() { return this.offset + 2 * this.visible; }
  seen(x: number) { return x >= this.seenFrom && x <= this.seenTo; }
  y(lane: number) { return this.trunk - lane * laneHeight; }

  colour(l: TimelineLine) { return palette[colourIndex(l.feature, palette.length)]!; }

  /** A child of the line is worked on now, and the line is open at Now. */
  isWorking(l: TimelineLine) { return l.working > 0 && l.start <= this.now && l.end >= this.now; }

  /** A line's path: a cubic curve up from the releases line, along its lane, and a curve back down
   * when it joins (section 10). The rise is in pixels, not minutes (section 12, item 2). */
  path(l: TimelineLine): string {
    const r = riser(l.lane), a = this.axis;
    const sx = a.x(l.start), ex = Math.max(a.x(l.end), sx), yl = this.y(l.lane), tr = this.trunk;
    let p = `M${sx},${tr} C${sx + r / 2},${tr} ${sx + r / 2},${yl} ${sx + r},${yl}`;
    if (l.how.how === "joined" || l.how.how === "forecast") {
      const jx = Math.max(ex - r, sx + r);
      p += ` L${jx},${yl} C${jx + r / 2},${yl} ${jx + r / 2},${tr} ${jx + r},${tr}`;
    } else {
      p += ` L${Math.max(ex, sx + r)},${yl}`;
    }
    return p;
  }

  /** Solid up to Now and dashed after it; at night with a soft glow (the CSS's). */
  stroke(key: string, d: string, colour: string, width: number) {
    return (
      <g key={key} class="timeline-stroke" style={{ "--c": colour }}>
        <path d={d} class="glow" stroke-width={width + 2} />
        <path d={d} clip-path="url(#timeline-past)" stroke-width={width} />
        <path d={d} clip-path="url(#timeline-ahead)" stroke-width={width} stroke-dasharray="5 4" />
      </g>
    );
  }

  plot() {
    const { axis, nowX, trunk, height, shown } = this;
    const left = this.offset, right = this.offset + this.visible;
    const out = [
      <defs key="defs">
        <clipPath id="timeline-past"><rect x={-100} y={0} width={Math.max(nowX + 100, 0)} height={height} /></clipPath>
        <clipPath id="timeline-ahead"><rect x={nowX} y={0} width={Math.max(axis.width - nowX + 100, 0)} height={height} /></clipPath>
      </defs>,
      <rect key="plot" class="timeline-ground" x={0} y={0} width={axis.width} height={height} />,
    ];
    // The bands under everything (8 times in 10).
    for (const l of shown) {
      if (!l.band) continue;
      out.push(<rect key={`band ${l.id}`} class="timeline-band" style={{ "--c": this.colour(l) }} x={axis.x(l.band.start)} y={this.y(l.lane) - 7}
        width={Math.max(axis.x(l.band.end) - axis.x(l.band.start), 2)} height={14} rx={7} />);
    }
    // The releases line: solid to Now, dashed after, the brightest at night.
    out.push(<g key="trunk" class="timeline-trunk">{this.stroke("trunk", `M0,${trunk} L${axis.width},${trunk}`, "var(--timeline-trunk)", 2.5)}</g>);
    // An epic a session is in a turn on now (#4265): under its line, a glow that breathes, and its ◐ turns, one
    // clock for every working line and ring (spinnerClock.ts); with Reduce Motion, neither (the CSS's). The line
    // itself is twice as thick.
    const working = shown.filter((l) => this.isWorking(l));
    if (working.length > 0) {
      out.push(<g key="breathing" class="timeline-breathing">
        {working.map((l) => <path key={l.id} d={this.path(l)} style={{ "--c": this.colour(l) }} />)}
      </g>);
    }
    // The lines.
    for (const l of shown) out.push(this.stroke(`line ${l.id}`, this.path(l), this.colour(l), this.isWorking(l) ? 4 : 2));
    // The joins on the releases line.
    for (const j of joins(shown, axis)) {
      const x = axis.x(j.at);
      const line = this.lines.find((l) => l.id === j.lines[0]);
      const c = line ? this.colour(line) : "var(--timeline-faint)";
      // A ring with a count is larger, so the count reads.
      const r = j.lines.length > 1 ? 9 : 6;
      out.push(
        <g key={`join ${j.lines.join(",")}`} class={`timeline-join${j.forecast ? " forecast" : ""}`} style={{ "--c": c }}>
          <circle cx={x} cy={trunk} r={r} stroke-dasharray={j.forecast ? "3 2" : undefined} />
          {j.lines.length > 1 && <text x={x} y={trunk} dy="0.35em" text-anchor="middle">{j.lines.length}</text>}
        </g>,
      );
    }
    // The releases: a ring on the releases line; its tag goes on after the labels.
    for (const rel of this.t.releases) {
      const x = axis.x(fromWireDate(rel.at).getTime());
      if (this.seen(x)) out.push(<circle key={`release ${rel.repo}@${rel.tag}`} class="timeline-release" cx={x} cy={trunk} r={5} />);
    }
    // The dots, and the children working now.
    for (const l of shown) {
      const c = this.colour(l), yl = this.y(l.lane);
      for (const dot of l.dots) {
        const x = dotX(dot, l, axis);
        out.push(<circle key={`dot ${l.id} ${dot.ref}`} class={`timeline-dot${dot.closed ? "" : " ahead"}${dot.notPlanned ? " dropped" : ""}`}
          style={{ "--c": c }} cx={x} cy={yl} r={dot.closed ? 4 : 3.5} />);
        if (landed.value.has(dot.ref)) {
          out.push(<circle key={`pulse ${dot.ref}`} class="timeline-pulse" style={{ "--c": c }} cx={x} cy={yl} r={4}
            onAnimationEnd={() => { const next = new Set(landed.value); next.delete(dot.ref); landed.value = next; }} />);
        }
      }
      if (this.isWorking(l)) {
        // ◐: a ring at Now, its left half filled; the half turns about the ring's centre.
        out.push(
          <g key={`working ${l.id}`} class="timeline-working" style={{ "--c": c }}>
            <circle cx={nowX} cy={yl} r={5} />
            <path style={{ transformOrigin: `${nowX}px ${yl}px` }} d={`M${nowX},${yl - 5} A5,5 0 0 0 ${nowX},${yl + 5} Z`} />
          </g>,
        );
      }
      if (l.how.how === "dropped") {
        const x = axis.x(l.end);
        out.push(<path key={`dropped ${l.id}`} class="timeline-cross" style={{ "--c": c }}
          d={`M${x - 4},${yl - 4} L${x + 4},${yl + 4} M${x - 4},${yl + 4} L${x + 4},${yl - 4}`} />);
      }
    }
    // Now: a grey line.
    out.push(<line key="now" class="timeline-now" x1={nowX} y1={0} x2={nowX} y2={height} />);

    // Last, on a halo: the labels, the pills that wait for the person, the arrows at the edges.
    const labels: { x: number; y: number; w: number; h: number }[] = [];
    for (const l of shown) {
      const yl = this.y(l.lane), c = this.colour(l);
      if (l.how.how === "waits") {
        // Where the forecast stops: "3 wait for you", with a person.
        const words = `👤 ${waitWords(l.how.count)}`;
        const w = measure(words) + 16;
        out.push(this.pill(`waits ${l.id}`, words, axis.x(l.end) + 6 + w / 2, yl, "timeline-pill waits"));
      }
      const startX = axis.x(l.start) + riser(l.lane) + 4;
      const endX = axis.x(l.end);
      if (!(endX >= left || isOpen(l)) || startX > right) continue;
      const cutLeft = startX < left + 8;
      const x = cutLeft ? left + 8 : startX;
      const room = labelRoom(l, x, axis) - (cutLeft ? 14 : 0);
      const words = fitLabel(l, room, measure);
      if (words) {
        const arrow = cutLeft ? "← " : "";
        const w = measure(arrow + labelText(words));
        labels.push({ x: x - 3, y: yl - 17, w: w + 6, h: 16 });
        out.push(
          <g key={`label ${l.id}`} class="timeline-label">
            <rect class="halo" x={x - 3} y={yl - 17} width={w + 6} height={16} rx={3} />
            <text x={x} y={yl - 9} dy="0.35em">
              {arrow && <tspan class="faint">{arrow}</tspan>}
              {words.title
                ? <><tspan style={{ fill: c }} class="name">{words.title}</tspan><tspan class="faint">{`  ${words.figures}`}</tspan></>
                : <tspan class="faint">{words.figures}</tspan>}
            </text>
          </g>,
        );
      }
      // → for a line that goes on past the right edge.
      if (Math.max(endX, l.band ? axis.x(l.band.end) : endX) > right && l.lane !== 0) {
        out.push(<text key={`more ${l.id}`} class="timeline-more" style={{ fill: c }} x={right - 10} y={yl - 9} dy="0.35em" text-anchor="middle">→</text>);
      }
    }
    // The releases line's name, held at the left edge.
    if (this.project) {
      labels.push({ x: left + 8, y: trunk - 20, w: measure(this.project), h: 14 });
      out.push(<text key="project" class="timeline-project" x={left + 8} y={trunk - 6}>{this.project}</text>);
    }
    // The release tags: below the releases line, unless a label is there and none is above (section 12, item 6).
    for (const rel of this.t.releases) {
      const x = axis.x(fromWireDate(rel.at).getTime());
      if (!this.seen(x)) continue;
      const w = measure(rel.tag) + 12;
      const free = (y: number) => !labels.some((b) => b.x < x + w / 2 && b.x + b.w > x - w / 2 && b.y < y + 9 && b.y + b.h > y - 9);
      // With a label on each side, the ring alone: its hover card says the tag.
      if (!free(trunk + 17) && !free(trunk - 17)) continue;
      out.push(this.pill(`tag ${rel.repo}@${rel.tag}`, rel.tag, x, trunk + (free(trunk + 17) ? 17 : -17), "timeline-pill tag"));
    }
    return out;
  }

  /** S10: grey bars that shimmer where the lanes go, on the window, over the releases line and Now. */
  placeholders() {
    const x = this.offset + this.visible * 0.08;
    return (
      <g key="placeholders" class="timeline-placeholder">
        {[[1, 0.55], [-1, 0.4], [2, 0.3], [-2, 0.5]].map(([lane, w], i) => (
          <rect key={i} x={x + i * this.visible * 0.06} y={this.y(lane!) - 4} width={this.visible * w!} height={8} rx={4} />
        ))}
      </g>
    );
  }

  pill(key: string, words: string, x: number, y: number, cls: string) {
    const w = measure(words) + 12;
    return (
      <g key={key} class={cls}>
        <rect x={x - w / 2} y={y - 9} width={w} height={18} rx={9} />
        <text x={x} y={y} dy="0.35em" text-anchor="middle">{words}</text>
      </g>
    );
  }

  /** The hour axis at the foot, and Now's time in a grey pill. */
  axisMarks() {
    const { axis, nowX } = this;
    const out = [<rect key="ground" class="timeline-ground" x={0} y={0} width={axis.width} height={axisHeight} />];
    const seenSpan = this.visible * (axis.interval.end - axis.interval.start) / Math.max(axis.width, 1);
    for (const tick of axis.ticks(seenSpan)) {
      const x = axis.x(tick);
      // Now's pill is where the tick under it would be.
      if (!this.seen(x) || Math.abs(x - nowX) <= 44) continue;
      const midnight = new Date(tick).getHours() === 0;
      // "Sun 8", as the window's ticks say it.
      const words = midnight ? `${new Date(tick).toLocaleDateString(undefined, { weekday: "short" })} ${new Date(tick).getDate()}`
        : new Date(tick).toLocaleTimeString(undefined, { hour: "numeric" });
      out.push(
        <g key={`tick ${tick}`} class={`timeline-tick${midnight ? " midnight" : ""}`}>
          <line x1={x} y1={0} x2={x} y2={midnight ? 7 : 4} />
          <text x={x} y={15} dy="0.35em" text-anchor="middle">{words}</text>
        </g>,
      );
    }
    out.push(this.pill("now", new Date(this.now).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" }), nowX, 13, "timeline-pill now"));
    return out;
  }
}
