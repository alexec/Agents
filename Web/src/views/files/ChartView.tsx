// A chart from a file (#836), drawn as an SVG of our own, as UsageCharts draws its bars: in the
// Files pane, and small on the chat's card. The window and the Remote draw the same ChartSpec
// with Swift Charts (Shared/UI/ChartView.swift). Nothing in the file runs; the colours are the
// theme's.
//
// Compact is the card's: no title, no legend, no axes but the baseline, so it reads as a picture
// of the chart and a click opens it whole. ChartPage is the pane's: the chart or why it is not
// drawn, with its source a toggle away.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import {
  dataURL, isVegaLite, markWords, neighbourURL, problemWords, read, series as seriesOf, summary,
  type ChartHint, type ChartResult, type ChartSpec, type XValue,
} from "../../model/chart";
import { FileLines } from "./FileLines";

/** The colours a series takes, in turn: the theme's tints (app.css, .chart-series-N). */
const seriesColours = 6;
/** Past this many marks, each is not named on hover: a <title> each is too much page. */
const namedMarksAtMost = 500;

interface Frame { width: number; height: number; left: number; right: number; top: number; bottom: number }

const full: Frame = { width: 600, height: 300, left: 52, right: 12, top: 22, bottom: 40 };
const small: Frame = { width: 300, height: 130, left: 4, right: 4, top: 6, bottom: 4 };

/** About `count` round steps from `low` to `high`: 1, 2 or 5 times a power of ten. */
export function niceTicks(low: number, high: number, count = 4): number[] {
  if (!(high > low)) return [low];
  const rough = (high - low) / count;
  const power = 10 ** Math.floor(Math.log10(rough));
  const step = [1, 2, 5, 10].map((m) => m * power).find((s) => s >= rough) ?? rough;
  const ticks: number[] = [];
  for (let v = Math.ceil(low / step) * step; v <= high + step * 1e-9; v += step) ticks.push(Math.round(v / step) * step);
  return ticks;
}

const numberWords = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2, notation: "compact" });

function xWords(x: XValue): string {
  if (x instanceof Date) {
    const midnight = x.getUTCHours() === 0 && x.getUTCMinutes() === 0 && x.getUTCSeconds() === 0;
    return x.toLocaleString(undefined, midnight ? { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }
      : { day: "numeric", month: "short", hour: "numeric", minute: "2-digit", timeZone: "UTC" });
  }
  return typeof x === "number" ? numberWords.format(x) : x;
}

function xNumber(x: XValue): number {
  return x instanceof Date ? x.getTime() : typeof x === "number" ? x : 0;
}

/** Where everything goes: the scales, the series and their marks, worked out once. */
function layout(spec: ChartSpec, frame: Frame) {
  const plot = { x0: frame.left, x1: frame.width - frame.right, y0: frame.top, y1: frame.height - frame.bottom };
  const names = seriesOf(spec);
  const seriesIndex = (name: string | undefined) => (name === undefined ? 0 : names.indexOf(name));
  const nominal = spec.xAxis === "nominal";
  const categories: string[] = [];
  if (nominal) for (const p of spec.points) if (!categories.includes(p.x as string)) categories.push(p.x as string);
  const distinct = nominal ? categories.length : new Set(spec.points.map((p) => xNumber(p.x))).size;

  // Bars of several series stack, as Swift Charts stacks them; the top is the tallest stack.
  const stackedBars = spec.mark === "bar" && names.length > 0;
  const stacks = new Map<string, { up: number; down: number }>();
  const bars = spec.points.map((p) => {
    const key = nominal ? (p.x as string) : String(xNumber(p.x));
    const stack = stacks.get(key) ?? { up: 0, down: 0 };
    let from = 0;
    if (stackedBars) {
      from = p.y >= 0 ? stack.up : stack.down;
      if (p.y >= 0) stack.up += p.y; else stack.down += p.y;
      stacks.set(key, stack);
    }
    return { point: p, from, to: from + p.y };
  });
  const ys = [0, ...bars.flatMap((b) => [b.from, b.to])];
  const ticks = niceTicks(Math.min(...ys), Math.max(...ys));
  const yLow = Math.min(ticks[0]!, ...ys);
  const yHigh = Math.max(ticks[ticks.length - 1]!, ...ys);
  const y = (v: number) => plot.y1 - ((v - yLow) / (yHigh - yLow || 1)) * (plot.y1 - plot.y0);

  // Names are bands; numbers and dates a scale, padded by half a bar where there are bars.
  const xs = spec.points.map((p) => xNumber(p.x));
  const xLow = nominal ? 0 : Math.min(...xs);
  const xHigh = nominal ? 0 : Math.max(...xs);
  const band = (plot.x1 - plot.x0) / Math.max(1, distinct);
  const pad = spec.mark === "bar" || xLow === xHigh ? band / 2 : 0;
  const x = (value: XValue) => nominal
    ? plot.x0 + band * (categories.indexOf(value as string) + 0.5)
    : plot.x0 + pad + ((xNumber(value) - xLow) / (xHigh - xLow || 1)) * (plot.x1 - plot.x0 - pad * 2);
  const xTicks: { at: number; words: string }[] = nominal
    ? categories.flatMap((name, i) => (i % Math.ceil(categories.length / (frame === full ? 10 : 1)) === 0
      ? [{ at: x(name), words: name }] : []))
    : xLow === xHigh ? [{ at: x(spec.points[0]!.x), words: xWords(spec.points[0]!.x) }]
    : (spec.xAxis === "temporal" ? niceTicks(xLow, xHigh, 4) : niceTicks(xLow, xHigh, 5))
      .map((v) => ({ at: x(spec.xAxis === "temporal" ? new Date(v) : v), words: xWords(spec.xAxis === "temporal" ? new Date(v) : v) }));

  // A line or an area per series, its points in order along the bottom.
  const lines = (names.length ? names : [undefined]).map((name) => {
    const points = spec.points.filter((p) => p.series === name);
    if (!nominal) points.sort((a, b) => xNumber(a.x) - xNumber(b.x));
    return { index: seriesIndex(name), points: points.map((p) => [x(p.x), y(p.y)] as const) };
  });
  return { plot, names, seriesIndex, bars, band, x, y, yTicks: ticks.filter((t) => t >= yLow && t <= yHigh), xTicks, lines };
}

export function ChartView({ spec, compact = false }: { spec: ChartSpec; compact?: boolean }) {
  const frame = compact ? small : full;
  const { plot, names, seriesIndex, bars, band, x, y, yTicks, xTicks, lines } = layout(spec, frame);
  const named = spec.points.length <= namedMarksAtMost;
  const label = (p: { x: XValue; y: number; series?: string | undefined }) =>
    `${p.series === undefined ? "" : `${p.series}, `}${xWords(p.x)}: ${numberWords.format(p.y)}`;
  const colour = (index: number) => `chart-series-${index % seriesColours}`;
  const path = (points: readonly (readonly [number, number])[]) => points.map(([px, py], i) => `${i ? "L" : "M"}${px},${py}`).join("");
  // On the card it sits in a button, where only phrasing content goes: a span, not a figure.
  const Root = compact ? "span" : "figure";
  return (
    <Root class={`chart${compact ? " compact" : ""}`} role="img"
      aria-label={`${spec.title ?? markWords(spec.mark)}, ${spec.yField} by ${spec.xField}`}>
      {!compact && spec.title && <figcaption class="chart-title">{spec.title}</figcaption>}
      <svg viewBox={`0 0 ${frame.width} ${frame.height}`} class="chart-svg" aria-hidden="true">
        {!compact && yTicks.map((t) => (
          <g key={t}>
            <line class="chart-grid" x1={plot.x0} x2={plot.x1} y1={y(t)} y2={y(t)} />
            <text class="chart-axis" x={plot.x0 - 6} y={y(t) + 4} text-anchor="end">{numberWords.format(t)}</text>
          </g>
        ))}
        {!compact && xTicks.map((t, i) => (
          <text key={i} class="chart-axis" x={t.at} y={plot.y1 + 14} text-anchor="middle">{t.words}</text>
        ))}
        {!compact && <text class="chart-axis chart-field" x={plot.x0 - 6} y={plot.y0 - 10} text-anchor="start">{spec.yField}</text>}
        {!compact && <text class="chart-axis chart-field" x={(plot.x0 + plot.x1) / 2} y={frame.height - 6} text-anchor="middle">{spec.xField}</text>}
        {spec.mark === "bar" && bars.map((b, i) => {
          const width = Math.max(1, band * 0.7);
          const top = Math.min(y(b.from), y(b.to));
          return (
            <rect key={i} class={`chart-bar ${colour(seriesIndex(b.point.series))}`} x={x(b.point.x) - width / 2} y={top}
              width={width} height={Math.max(0.5, Math.abs(y(b.to) - y(b.from)))} rx={compact ? 1 : 2}>
              {named && <title>{label(b.point)}</title>}
            </rect>
          );
        })}
        {spec.mark === "area" && lines.map((l) => l.points.length > 0 && (
          <path key={`a${l.index}`} class={`chart-area ${colour(l.index)}`}
            d={`${path(l.points)}L${l.points[l.points.length - 1]![0]},${y(0)}L${l.points[0]![0]},${y(0)}Z`} />
        ))}
        {(spec.mark === "line" || spec.mark === "area") && lines.map((l) => (
          <path key={`l${l.index}`} class={`chart-line ${colour(l.index)}`} d={path(l.points)} />
        ))}
        {spec.mark === "point" && spec.points.map((p, i) => (
          <circle key={i} class={`chart-point ${colour(seriesIndex(p.series))}`} cx={x(p.x)} cy={y(p.y)} r={compact ? 2.5 : 3.5}>
            {named && <title>{label(p)}</title>}
          </circle>
        ))}
        <line class="chart-baseline" x1={plot.x0} x2={plot.x1} y1={y(0)} y2={y(0)} />
      </svg>
      {!compact && names.length > 0 && (
        <ul class="chart-legend" aria-label={spec.colorField ?? "Series"}>
          {names.map((name, i) => <li key={name}><span class={`chart-swatch ${colour(i)}`} aria-hidden="true" />{name}</li>)}
        </ul>
      )}
    </Root>
  );
}

/**
 * The chart a file draws, with the one file its `data.url` names read first (ChartPage.read).
 * `readText` gives a file's text, or null when it cannot be read.
 */
export async function readChart(text: string, path: string, hint: ChartHint | undefined,
  readText: (path: string) => Promise<string | null>): Promise<ChartResult> {
  const beside = new Map<string, string | null>();
  const name = isVegaLite(path) ? dataURL(text) : undefined;
  const named = name === undefined ? undefined : neighbourURL(name, path);
  if (name !== undefined && named !== undefined) beside.set(name, await readText(named));
  return read(text, path, hint, (url) => beside.get(url) ?? null);
}

/** A chart file in the Files pane (ChartPage): the chart or why it is not drawn, and its source. */
export function ChartPage({ text, path, hint, line, readText }: {
  text: string; path: string; hint: ChartHint | undefined; line?: number | undefined;
  readText: (path: string) => Promise<string | null>;
}) {
  const result = useSignal<ChartResult | null>(null);
  const showsSource = useSignal(false);
  useEffect(() => {
    let current = true;
    void readChart(text, path, hint, readText).then((r) => { if (current) result.value = r; });
    return () => { current = false; };
  }, [text, path, hint?.mark, hint?.x, hint?.y, hint?.color, hint?.title]);
  const r = result.value;
  return (
    <div class="chart-page">
      <div class="chart-head">
        <span class="quiet small">{r === null ? "" : "spec" in r ? summary(r.spec) : "Not drawn"}</span>
        <div class="tabs" role="tablist" aria-label="Show">
          {([false, true] as const).map((source) => (
            <button key={String(source)} role="tab" aria-selected={showsSource.value === source}
              class={showsSource.value === source ? "on" : ""} onClick={() => (showsSource.value = source)}>
              {source ? "Source" : "Chart"}
            </button>
          ))}
        </div>
      </div>
      {showsSource.value ? <FileLines text={text} line={line} />
        : r === null ? <p class="hint">Drawing the chart…</p>
        : "spec" in r ? <ChartView spec={r.spec} />
        : <><p class="quiet small chart-problem">{problemWords(r.problem)}</p><FileLines text={text} line={line} /></>}
    </div>
  );
}
