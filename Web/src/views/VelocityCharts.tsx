// Velocity (#4598): the pull requests the person's agents landed, drawn as Cost's bars are
// (UsageCharts.tsx): the Range select, PRS A DAY above the figure, the bars with the dashed average
// and the right axis, a picked bar's own figure, the shares by repository, and the reverts line.
// The bars are worked out in model/velocity.ts.
import { useSignal } from "@preact/signals";
import type { VelocityHistory } from "../protocol/generated";
import { type UsageRange, usageRanges, usageRangeWords } from "../model/usage";
import { prWords, repoWords, revertWords, velocityChart, velocityHeadline } from "../model/velocity";
import { Choice } from "./Choice";
import { label, tick, when } from "./UsageCharts";

const width = 600;
const height = 200;
const axis = 56;

export function VelocityCharts({ history }: { history: VelocityHistory | undefined }) {
  const range = useSignal<UsageRange>("W");
  const picked = useSignal<string | null>(null);
  if (!history) return <p class="quiet">Loading…</p>;
  const chart = velocityChart(history, range.value);
  const bar = chart.bars.find((b) => b.stamp === picked.value) ?? null;
  // In 3M the bars are weeks, so the average line is a week's worth (note 3).
  const averageLine = chart.range === "3M" ? chart.average * 7 : chart.average;
  const top = Math.max(...chart.bars.map((b) => b.value), averageLine, 0) || 1;
  const step = (width - axis) / chart.bars.length;
  const y = (value: number) => height - (value / top) * (height - 8);

  return (
    <section class="usage-charts velocity-charts">
      <Choice label="Range" value={range.value} options={usageRanges.map((r) => [r, usageRangeWords[r]] as const)}
        onPick={(r) => { range.value = r; picked.value = null; }} />
      <div class="usage-headline">
        <p class="quiet small strong">{(bar ? "Total" : velocityHeadline).toUpperCase()}</p>
        <p class="usage-figure">{prWords(bar?.value ?? chart.average)}</p>
        <p class="quiet">{when(chart.range, chart.bars, bar)}</p>
      </div>
      {chart.total === 0 ? (
        <p class="quiet">No pull requests landed in this range.</p>
      ) : (
        <>
          <svg class="usage-bars" viewBox={`0 0 ${width} ${height + 18}`} role="img"
            aria-label={`${velocityHeadline} ${prWords(chart.average)}`}>
            {[0.5, 1].map((f) => (
              <g key={f}>
                <line class="usage-grid" x1={0} x2={width - axis} y1={y(top * f)} y2={y(top * f)} />
                <text class="usage-axis" x={width - axis + 6} y={y(top * f) + 4}>{Math.round(top * f)}</text>
              </g>
            ))}
            <line class="usage-grid" x1={0} x2={width - axis} y1={height} y2={height} />
            {chart.bars.map((b, i) => (
              <g key={b.stamp} onClick={() => { picked.value = picked.value === b.stamp ? null : b.stamp; }}>
                <rect class="usage-hit" x={i * step} y={0} width={step} height={height} />
                <rect class={`usage-bar${bar && bar !== b ? " dim" : ""}`} x={i * step + step * 0.15}
                  y={y(b.value)} width={step * 0.7} height={height - y(b.value)} rx={2}>
                  <title>{`${label(chart.range, b)}: ${prWords(b.value)}`}</title>
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
            <p key={share.repo} class="usage-share"><span>{repoWords(share.repo)}</span><span>{share.value.toLocaleString()}</span></p>
          ))}
          <p class="quiet small">{revertWords(chart)}</p>
        </>
      )}
    </section>
  );
}
