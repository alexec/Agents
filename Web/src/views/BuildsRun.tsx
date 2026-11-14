// Reports ▸ Planning ▸ Builds ▸ one run (#5179, spec 5166, board 3): the Gantt chart of a CI run's jobs and steps,
// the run before's same jobs as dashed outlines, the steps that changed most, and the range's longest wait for a
// runner, which is load and not code. The runs are asked of who answered the page's history: the control plane's
// builds/runAll (#5232, #5327), or a machine's builds/run (#5177). The shapes and words are model/buildsRun.ts.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { BuildsChange, BuildsHistory, BuildsRun, BuildsRunAnswer, BuildsRunnerWait } from "../protocol/generated";
import type { Store } from "../model/store";
import { routeHash, type Route } from "../route";
import { changeTitle, forgeName, pullRef, runName, runWhen, secondsWords, wireMs, type BuildsAsk } from "../model/builds";
import {
  attemptWords, changeWords, gantt, ganttTicks, onlyWords, ownWaitShort, queuePanelWords, rowWords, runLine, stepChanges, stepsHeading,
  stepsNote, tickWords, type GanttRow,
} from "../model/buildsRun";
import { readProblem, readRun, type BuildsFrom } from "../model/buildsRead";
import { LastUpdate } from "./LastUpdate";

const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;

interface Props {
  store: Store; from: BuildsFrom; repo: string; ask: BuildsAsk & { drill: NonNullable<BuildsAsk["drill"]> };
  history: BuildsHistory; change: BuildsChange | undefined; at: (a: BuildsAsk) => Route;
}

type Got ={ answer: BuildsRunAnswer; before: BuildsRun | undefined } | { problem: string };

/** Board 3: one run. */
export function RunDrill({ store, from, repo, ask, history: h, change, at }: Props) {
  const got = useSignal<Got | null>(null);
  const { ref, against, job: picked } = ask.drill;
  useEffect(() => {
    let live = true;
    got.value = null;
    void (async () => {
      try {
        const answer = await readRun(store, { repo, ref }, from);
        // Board 2's "Compare the two runs" names the last fast run; else the run before is builds/run's own choice.
        const before = against && against !== answer.before?.ref
          ? await readRun(store, { repo, ref: against }, from).then((r) => r.run, () => answer.before)
          : answer.before;
        if (live) got.value = { answer, before };
      } catch (e) {
        if (live) got.value = { problem: readProblem(e, from) };
      }
    })();
    return () => { live = false; };
  }, [ref, against, from]);

  const trend = at({ ...ask, change: undefined, drill: undefined });
  const fromChange = change ? at({ ...ask, drill: undefined }) : null;
  const g = got.value;
  const run = g && "answer" in g ? g.answer.run : undefined;
  return (
    <div class="reports-pane builds-page builds-drill">
      {h.readAt && <LastUpdate at={wireMs(h.readAt)} />}
      <p class="small">
        <a href={routeHash(trend)}>Builds</a> ›{" "}
        {change && fromChange && <><a href={routeHash(fromChange)}>{changeTitle(change, timeZone)}</a> ›</>}
      </p>
      {!g && <p class="hint">Loading…</p>}
      {g && "problem" in g && <p class="hint">{g.problem}</p>}
      {g && "answer" in g && run && (
        <>
          <h2>
            {`${runName(run)} · run ${run.id}`}
            {run.pr ? <>{" · "}<a href={routeHash({ nav: "work", section: "pr", item: pullRef(repo, run.pr) })}>{`#${run.pr}`}</a></> : null}
          </h2>
          <p class="quiet">{runLine(run, g.before, runWhen(run.made, timeZone))}</p>
          <p class="builds-drill-links small">
            {run.url && <a href={run.url} target="_blank" rel="noreferrer">{`Open on ${forgeName(repo)} ↗`}</a>}
            {attemptWords(run.attempt, g.answer.attempts) && <span class="quiet">{attemptWords(run.attempt, g.answer.attempts)}</span>}
          </p>
          <div class="builds-drill-body">
            <section>
              <div class="builds-chart-head">
                <h3>Jobs and steps</h3>
                <ul class="builds-gantt-key small">
                  <li><span class="builds-swatch runner" aria-hidden="true" />waiting for a runner</li>
                  <li><span class="builds-swatch run" aria-hidden="true" />running; a white tick starts a step</li>
                  {g.before && <li><span class="builds-swatch before" aria-hidden="true" />the run before, the same job</li>}
                  <li><span class="builds-swatch turn" aria-hidden="true" />waiting its turn</li>
                </ul>
              </div>
              <GanttChart run={run} before={g.before} picked={picked} />
              {g.before ? <Steps run={run} before={g.before} picked={picked} /> : <p class="quiet small">No passed run of this workflow before it, on its branch or the default branch, so nothing to compare.</p>}
            </section>
            {h.longestRunnerWait && h.longestRunnerWait.run.ref !== run.ref && ownWaitShort(run) && (
              <QueuePanel store={store} from={from} repo={repo} wait={h.longestRunnerWait} open={at({ ...ask, change: undefined, drill: { ref: h.longestRunnerWait.run.ref, job: h.longestRunnerWait.job } })} />
            )}
          </div>
        </>
      )}
      <p class="quiet small">{`A pull request’s run is compared with the run before on its own branch, or on ${h.defaultBranch ?? "the default branch"} when it has none.`}</p>
    </div>
  );
}

const W = 760;
const LABEL = 132;
const ROW = 34;
const BAR = 14;
const HEAD = 22;

/** Board 3 notes 1 and 2: a row a job, hatched while it waited for a runner, then the accent to its end with a white
 * tick a step; the run before's same job a dashed outline under it; the first row the run's wait for its turn. */
function GanttChart({ run, before, picked }: { run: BuildsRun; before: BuildsRun | undefined; picked: string | undefined }) {
  const g = gantt(run, before, picked);
  const plot = W - LABEL - 8;
  const x = (s: number) => LABEL + (s / g.end) * plot;
  const rows = 1 + g.rows.length;
  const height = HEAD + rows * ROW + 4;
  const jobs = new Map(run.jobs.map((j) => [j.name, j]));
  const prior = new Map((before?.jobs ?? []).map((j) => [j.name, j]));
  const rowY = (i: number) => HEAD + i * ROW;
  return (
    <svg class="builds-chart builds-gantt" viewBox={`0 0 ${W} ${height}`} role="img"
      aria-label={`${run.jobs.length} jobs: time to green ${secondsWords(run.ended)}${before ? `, the run before ${secondsWords(before.ended)}` : ""}`}>
      <defs>
        <pattern id="builds-gantt-hatch" width="5" height="5" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
          <rect width="5" height="5" class="builds-hatch-ground" />
          <line x1="0" y1="0" x2="0" y2="5" class="builds-hatch-line" />
        </pattern>
      </defs>
      {ganttTicks(g.end).map((t) => (
        <g key={t}>
          <line class="usage-grid" x1={x(t)} x2={x(t)} y1={HEAD - 4} y2={height} />
          <text class="usage-axis" x={x(t)} y={12} text-anchor="middle">{tickWords(t)}</text>
        </g>
      ))}
      <g transform={`translate(0 ${rowY(0)})`}>
        <text class="builds-gantt-name" x={0} y={13}>the run</text>
        <text class="builds-gantt-runner" x={0} y={26}>{`its turn${run.branch ? ` on ${run.branch}` : ""}`}</text>
        {g.turn > 0 && (
          <g>
            <rect class="builds-turn" x={x(0)} y={4} width={Math.max(1, x(g.turn) - x(0))} height={BAR} rx={2} />
            {x(g.turn) - x(0) > 130 && <text class="builds-gantt-turn-label" x={x(0) + 5} y={15}>{`waiting its turn, ${secondsWords(g.turn)}`}</text>}
            <title>{`Waiting its turn: ${secondsWords(g.turn)}`}</title>
          </g>
        )}
      </g>
      {g.rows.map((r, i) => <JobRow key={r.name} r={r} y={rowY(i + 1)} x={x} title={rowWords(r, jobs.get(r.name), prior.get(r.name))} />)}
    </svg>
  );
}

function JobRow({ r, y, x, title }: { r: GanttRow; y: number; x: (s: number) => number; title: string }) {
  const failed = r.conclusion && r.conclusion !== "success" && r.conclusion !== "skipped";
  return (
    <g transform={`translate(0 ${y})`} class={`builds-gantt-row${r.picked ? " picked" : ""}${failed ? " failed" : ""}`}>
      <title>{title}</title>
      <text class="builds-gantt-name" x={0} y={13}>{clip(r.name, 18)}</text>
      {r.runner && <text class="builds-gantt-runner" x={0} y={26}>{clip(r.runner, 20)}</text>}
      {r.before && <rect class="builds-gantt-before" x={x(r.before.made)} y={BAR + 7} width={Math.max(2, x(r.before.ended) - x(r.before.made))} height={5} rx={1} />}
      {r.started > r.made && <rect x={x(r.made)} y={4} width={Math.max(1, x(r.started) - x(r.made))} height={BAR} fill="url(#builds-gantt-hatch)" />}
      <rect class="builds-run builds-gantt-bar" x={x(r.started)} y={4} width={Math.max(2, x(r.ended) - x(r.started))} height={BAR} rx={2} />
      {r.ticks.map((t) => <line key={t} class="builds-gantt-tick" x1={x(t)} x2={x(t)} y1={4} y2={4 + BAR} />)}
      {r.named.map((s) => x(s.ended) - x(s.started) > 40 && (
        <text key={`${s.name} ${s.started}`} class="builds-gantt-step" x={x(s.started) + 4} y={15}>{clip(s.name, Math.floor((x(s.ended) - x(s.started) - 8) / 6))}</text>
      ))}
    </g>
  );
}

const clip = (s: string, n: number) => s.length <= n ? s : `${s.slice(0, Math.max(1, n - 1))}…`;

/** Board 3 note 3: the steps that changed most, the picked job's first, each with a bar for its change. */
function Steps({ run, before, picked }: { run: BuildsRun; before: BuildsRun; picked: string | undefined }) {
  const { rows, only } = stepChanges(run, before, picked);
  const most = Math.max(1, ...rows.map((r) => Math.abs(r.change)));
  return (
    <>
      <h3>{stepsHeading(picked && run.jobs.some((j) => j.name === picked) ? picked : undefined)}</h3>
      {rows.length === 0 ? <p class="quiet small">No step is in both runs.</p> : (
        <table class="builds-steps">
          <thead><tr><th>Job</th><th>Step</th><th class="num">Before</th><th class="num">After</th><th class="num">Change</th><th aria-hidden="true" /></tr></thead>
          <tbody>
            {rows.map((r) => {
              const cls = r.change >= 1 ? "builds-slower" : r.change <= -1 ? "builds-faster" : "quiet";
              return (
                <tr key={`${r.job} ${r.step}`} class={r.picked ? "picked" : ""}>
                  <td class="strong">{r.job}</td>
                  <td>{r.step}</td>
                  <td class="num quiet">{secondsWords(r.before)}</td>
                  <td class="num">{secondsWords(r.after)}</td>
                  <td class={`num ${cls}`}>{changeWords(r.change)}</td>
                  <td class="builds-steps-bar"><span class={r.change >= 0 ? "slower" : "faster"} style={{ width: `${(Math.abs(r.change) / most) * 100}%` }} /></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      {onlyWords(only).map((line) => <p key={line} class="quiet small">{line}</p>)}
      <p class="quiet small">{stepsNote}</p>
    </>
  );
}

/** Board 3 note 4: the run of the range whose job waited longest for a runner, its jobs drawn as wait and run. */
function QueuePanel({ store, from, repo, wait: w, open }: { store: Store; from: BuildsFrom; repo: string; wait: BuildsRunnerWait; open: Route }) {
  const run = useSignal<BuildsRun | null | undefined>(undefined);
  useEffect(() => {
    let live = true;
    run.value = undefined;
    void readRun(store, { repo, ref: w.run.ref }, from).then((r) => r.run, () => null).then((r) => { if (live) run.value = r; });
    return () => { live = false; };
  }, [w.run.ref, from]);
  const r = run.value;
  const runner = r?.jobs.find((j) => j.name === w.job)?.runner;
  const end = r ? Math.max(1, ...r.jobs.map((j) => j.ended - j.made)) : 1;
  return (
    <aside class="delivery-card builds-queue-panel">
      <h3>Queue time is load, not code</h3>
      <p class="quiet small">{queuePanelWords(w, runWhen(w.run.made, timeZone), runner)}</p>
      {r && (
        <ul class="builds-queue-jobs">
          {[...r.jobs].sort((a, b) => (b.started - b.made) - (a.started - a.made)).slice(0, 8).map((j) => (
            <li key={j.name} class={j.name === w.job ? "strong" : ""} title={`${j.name}: a runner ${secondsWords(j.started - j.made)}, ran ${secondsWords(j.ended - j.started)}`}>
              <span>{j.name}</span>
              <span class="builds-queue-track">
                <span class="builds-queue-wait" style={{ width: `${((j.started - j.made) / end) * 100}%` }} />
                <span class="builds-queue-ran" style={{ width: `${Math.max(0.5, ((j.ended - j.started) / end) * 100)}%` }} />
              </span>
            </li>
          ))}
        </ul>
      )}
      {r === null && <p class="quiet small">This machine no longer keeps that run’s jobs.</p>}
      <p class="quiet small">{`0 → ${secondsWords(end)}. The trend shows it hatched; the change finder never looks at it.`}</p>
      <a class="small" href={routeHash(open)}>Open that run ›</a>
    </aside>
  );
}
