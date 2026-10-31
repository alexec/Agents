// What the work used over time, as Health draws it (#823): the page's half of the window's and
// the Remote's UsageChartsSection. D / W / M / 3M, the daily average above the bars, and a bar
// picked to read its own figure; in cost on Cost and in tokens on Tokens (#956). The bars are worked out in model/usage.ts.
import { useSignal } from "@preact/signals";
import type { UsageHistory } from "../protocol/generated";
import { type UsageBar, type UsageMetric, type UsageRange, unattributed, usageChart, usageHeadline,
  usageRanges, usageRangeWords, usageWords, tokenWords } from "../model/usage";
import { Choice } from "./Choice";

const width = 600;
const height = 200;
const axis = 56;

export function UsageCharts({ metric, history, runtimeName }: {
  metric: UsageMetric; history: UsageHistory | undefined; runtimeName: (id: string) => string;
}) {
  const range = useSignal<UsageRange>("W");
  const picked = useSignal<string | null>(null);
  if (!history) return <p class="quiet">Loading…</p>;
  const chart = usageChart(history, range.value, metric);
  const bar = chart.bars.find((b) => b.stamp === picked.value) ?? null;
  const top = Math.max(...chart.bars.map((b) => b.value), chart.range === "3M" ? chart.average * 7 : chart.average, 0) || 1;
  const step = (width - axis) / chart.bars.length;
  const y = (value: number) => height - (value / top) * (height - 8);
  const averageLine = chart.range === "3M" ? chart.average * 7 : chart.average;
  const name = (id: string) => (id === unattributed ? "Earlier" : runtimeName(id));
  const choose = <T,>(signal: { value: T }, value: T) => { signal.value = value; picked.value = null; };

  return (
    <section class="usage-charts">
      <Choice label="Range" value={range.value} options={usageRanges.map((r) => [r, usageRangeWords[r]] as const)} onPick={(r) => choose(range, r)} />
      <div class="usage-headline">
        <p class="quiet small strong">{(bar ? "Total" : usageHeadline(chart)).toUpperCase()}</p>
        <p class="usage-figure">{usageWords(chart, bar?.value ?? chart.average)}</p>
        <p class="quiet">{when(chart.range, chart.bars, bar)}</p>
      </div>
      {chart.total === 0 ? (
        <p class="quiet">{chart.metric === "cost" ? "Nothing was spent in this range." : "No tokens were used in this range."}</p>
      ) : (
        <>
          <svg class="usage-bars" viewBox={`0 0 ${width} ${height + 18}`} role="img"
            aria-label={`${usageHeadline(chart)} ${usageWords(chart, chart.average)}`}>
            {[0.5, 1].map((f) => (
              <g key={f}>
                <line class="usage-grid" x1={0} x2={width - axis} y1={y(top * f)} y2={y(top * f)} />
                <text class="usage-axis" x={width - axis + 6} y={y(top * f) + 4}>{usageWords(chart, top * f)}</text>
              </g>
            ))}
            <line class="usage-grid" x1={0} x2={width - axis} y1={height} y2={height} />
            {chart.bars.map((b, i) => (
              <g key={b.stamp} onClick={() => { picked.value = picked.value === b.stamp ? null : b.stamp; }}>
                <rect class="usage-hit" x={i * step} y={0} width={step} height={height} />
                <rect class={`usage-bar${bar && bar !== b ? " dim" : ""}`} x={i * step + step * 0.15}
                  y={y(b.value)} width={step * 0.7} height={height - y(b.value)} rx={2}>
                  <title>{`${label(chart.range, b)}: ${usageWords(chart, b.value)}`}</title>
                </rect>
                {tick(chart.range, i, chart.bars.length) && (
                  <text class="usage-axis" x={i * step + step / 2} y={height + 14} text-anchor="middle">{label(chart.range, b, true)}</text>
                )}
              </g>
            ))}
            {chart.range !== "D" && !bar && chart.average > 0 && (
              <line class="usage-average" x1={0} x2={width - axis} y1={y(averageLine)} y2={y(averageLine)} />
            )}
          </svg>
          {chart.shares.map((share) => (
            <p key={share.runtime} class="usage-share"><span>{name(share.runtime)}</span><span>{usageWords(chart, share.value)}</span></p>
          ))}
        </>
      )}
      {chart.metric === "tokens" && chart.cachedReadTokens > 0 && (
        <p class="quiet small">Plus {tokenWords(chart.cachedReadTokens)} read from cache, not drawn.</p>
      )}
      {chart.metric === "cost" && chart.unpricedTurns > 0 && (
        <p class="quiet small">At least this much: {chart.unpricedTurns === 1 ? "1 turn" : `${chart.unpricedTurns} turns`} ran on a runtime that reported no price.</p>
      )}
      {chart.otherCurrencies.length > 0 && (
        <p class="quiet small">Also spent in {chart.otherCurrencies.join(", ")}, not drawn.</p>
      )}
    </section>
  );
}

function tick(range: UsageRange, i: number, count: number): boolean {
  if (range === "D") return i % 6 === 0;
  if (range === "W") return true;
  return (count - 1 - i) % (range === "M" ? 7 : 3) === 0;
}

function label(range: UsageRange, bar: UsageBar, short = false): string {
  const d = bar.start;
  if (range === "D") return d.toLocaleTimeString(undefined, { hour: "numeric" });
  if (range === "W") return d.toLocaleDateString(undefined, short ? { weekday: "short" } : { weekday: "long", day: "numeric", month: "long" });
  if (range === "3M" && !short) return `Week of ${d.toLocaleDateString(undefined, { day: "numeric", month: "long" })}`;
  return d.toLocaleDateString(undefined, short ? { day: "numeric", month: "short" } : { weekday: "long", day: "numeric", month: "long" });
}

function when(range: UsageRange, bars: UsageBar[], bar: UsageBar | null): string {
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
