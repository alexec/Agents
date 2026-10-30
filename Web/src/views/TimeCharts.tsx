// Where the time of running chats went (#852): the page's half of the window's and the Remote's
// TimeChartsSection. D / W / M / 3M, each bar stacked by kind of time, the daily average above the
// bars, and a bar picked to read its own figures. The bars are worked out in model/time.ts.
import { useSignal } from "@preact/signals";
import type { TimeHistory } from "../protocol/generated";
import { usageRanges, usageRangeWords, type UsageRange } from "../model/usage";
import {
  type TimeBar, type TimeKind, timeChart, timeKinds, timeKindTitles, timePercent, timeTotal, timeWords,
} from "../model/time";
import { Choice } from "./Choice";

const width = 600;
const height = 200;
const axis = 56;

export function TimeCharts({ history, runtimeName }: { history: TimeHistory | undefined; runtimeName: (id: string) => string }) {
  const range = useSignal<UsageRange>("W");
  const picked = useSignal<string | null>(null);
  if (!history) return <p class="quiet">Loading…</p>;
  const chart = timeChart(history, range.value);
  const bar = chart.bars.find((b) => b.stamp === picked.value) ?? null;
  const averageLine = chart.range === "3M" ? chart.average * 7 : chart.average;
  const top = Math.max(...chart.bars.map((b) => b.total), averageLine, 0) || 1;
  const step = (width - axis) / chart.bars.length;
  const y = (value: number) => height - (value / top) * (height - 8);
  const shown = bar ? bar.time : chart.time;
  const choose = (r: UsageRange) => { range.value = r; picked.value = null; };

  return (
    <section class="usage-charts time-charts">
      <Choice label="Range" value={range.value} options={usageRanges.map((r) => [r, usageRangeWords[r]] as const)} onPick={(r) => choose(r)} />
      <div class="usage-headline">
        <p class="quiet small strong">{(bar ? "Total" : chart.range === "D" ? "Total" : "Daily average").toUpperCase()}</p>
        <p class="usage-figure">{timeWords(bar?.total ?? chart.average)}</p>
        <p class="quiet">{when(chart.range, chart.bars, bar)}</p>
      </div>
      {timeTotal(chart.time) === 0 ? (
        <p class="quiet">No chat ran in this range.</p>
      ) : (
        <>
          <svg class="usage-bars" viewBox={`0 0 ${width} ${height + 18}`} role="img"
            aria-label={`${chart.range === "D" ? "Total" : "Daily average"} ${timeWords(chart.average)}`}>
            {[0.5, 1].map((f) => (
              <g key={f}>
                <line class="usage-grid" x1={0} x2={width - axis} y1={y(top * f)} y2={y(top * f)} />
                <text class="usage-axis" x={width - axis + 6} y={y(top * f) + 4}>{timeWords(top * f)}</text>
              </g>
            ))}
            <line class="usage-grid" x1={0} x2={width - axis} y1={height} y2={height} />
            {chart.bars.map((b, i) => {
              let base = 0;
              return (
                <g key={b.stamp} class={bar && bar !== b ? "dim" : ""}
                  onClick={() => { picked.value = picked.value === b.stamp ? null : b.stamp; }}>
                  <rect class="usage-hit" x={i * step} y={0} width={step} height={height} />
                  {timeKinds.map((kind) => {
                    const value = b.time[kind];
                    if (value <= 0) return null;
                    const rect = <rect key={kind} class={`time-bar ${kind}`} x={i * step + step * 0.15}
                      y={y(base + value)} width={step * 0.7} height={y(base) - y(base + value)} />;
                    base += value;
                    return rect;
                  })}
                  <title>{`${label(chart.range, b)}: ${timeWords(b.total)}`}</title>
                  {tick(chart.range, i, chart.bars.length) && (
                    <text class="usage-axis" x={i * step + step / 2} y={height + 14} text-anchor="middle">{label(chart.range, b, true)}</text>
                  )}
                </g>
              );
            })}
            {chart.range !== "D" && !bar && chart.average > 0 && (
              <line class="usage-average" x1={0} x2={width - axis} y1={y(averageLine)} y2={y(averageLine)} />
            )}
          </svg>
          {timeKinds.map((kind: TimeKind) => (
            <p key={kind} class="usage-share time-kind">
              <span><span class={`time-swatch ${kind}`} aria-hidden="true" />{timeKindTitles[kind]}</span>
              <span>{timeWords(shown[kind])} <span class="quiet">{timePercent({ ...chart, time: shown }, shown[kind])}</span></span>
            </p>
          ))}
          {!bar && chart.shares.length > 1 && (
            <>
              <h2 class="section-head">By runtime</h2>
              {chart.shares.map((share) => (
                <p key={share.runtime} class="usage-share"
                  title={timeKinds.map((k) => `${timeKindTitles[k]} ${timeWords(share.time[k])}`).join(", ")}>
                  <span>{runtimeName(share.runtime)}</span><span>{timeWords(share.total)}</span>
                </p>
              ))}
            </>
          )}
        </>
      )}
      <p class="quiet small">Chats run side by side, so an hour can hold more than an hour of chat time. Time between turns is not counted.</p>
    </section>
  );
}

function tick(range: UsageRange, i: number, count: number): boolean {
  if (range === "D") return i % 6 === 0;
  if (range === "W") return true;
  return (count - 1 - i) % (range === "M" ? 7 : 3) === 0;
}

function label(range: UsageRange, bar: TimeBar, short = false): string {
  const d = bar.start;
  if (range === "D") return d.toLocaleTimeString(undefined, { hour: "numeric" });
  if (range === "W") return d.toLocaleDateString(undefined, short ? { weekday: "short" } : { weekday: "long", day: "numeric", month: "long" });
  if (range === "3M" && !short) return `Week of ${d.toLocaleDateString(undefined, { day: "numeric", month: "long" })}`;
  return d.toLocaleDateString(undefined, short ? { day: "numeric", month: "short" } : { weekday: "long", day: "numeric", month: "long" });
}

function when(range: UsageRange, bars: TimeBar[], bar: TimeBar | null): string {
  if (bar) {
    if (range === "D") {
      const next = new Date(bar.start.getTime() + 3600_000);
      return `${label(range, bar)}–${label(range, { ...bar, start: next })}`;
    }
    return label(range, bar);
  }
  if (range === "D") return "Today";
  const first = bars[0]?.start;
  const lastStart = bars[bars.length - 1]?.start;
  if (!first || !lastStart) return "";
  // 3M's last bar is a week that ends today, not on the day it starts.
  const last = range === "3M" ? new Date(lastStart.getFullYear(), lastStart.getMonth(), lastStart.getDate() + 6) : lastStart;
  const f = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric" });
  return f.formatRange(first, last);
}
