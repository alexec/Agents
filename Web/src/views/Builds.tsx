// Reports ▸ Planning ▸ Builds (#5178, spec 5166, boards 1, 2 and 4): the trend of a repository's CI runs by day
// (run, waiting for a runner, waiting its turn), the changes found in each job's run time on the default branch, and
// a change picked, with the runs around it and the commits between. The figures are builds/history and builds/run
// (#5177), asked of each of the person's machines that reads build timings; the one with the most runs answers. The
// control plane's copy (#5232) is its own task. The words and the shapes are model/builds.ts.
import { useEffect, useRef } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { BuildsChange, BuildsHistory, BuildsHistoryRequest, BuildsRun, ForgeRelease, MachineRef } from "../protocol/generated";
import { Capability } from "../protocol/capabilities.generated";
import type { Store } from "../model/store";
import { hostAnswers } from "../model/capabilities";
import { go, replace, route, routeHash } from "../route";
import { ranges, rangeSpan } from "../model/reports";
import {
  allJobsNote, betweenLine, branchOptions, branchWords, buildsBars, buildsQuery, buildsRepo, buildsRepoWords, buildsTiles, cardsNote,
  changeContext, changeHeading, changeLine, changeMark, changePlot, changeTitle, chartTop, dayKeys, dayTicks, dayWords, fillingWords,
  lastFastLine, laneRows, legend, noCIWords, noMachine, noReaderWords, noRepos, noRunsWords, notReadWords, parseBuildsQuery, pullRef,
  pullsBranch, rangeBounds, releaseMarks, releasesNote, runName, runWhen, secondsWords, tileWindows, workflowShown, workflowWords,
  wireMs, type BuildsAsk, type BuildsBar, type ReleaseMark,
} from "../model/builds";
import { CallFailed } from "../wire/link";
import { toWireDate } from "../protocol/dates";
import { Choice } from "./Choice";
import { LastUpdate } from "./LastUpdate";

const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;

/** The page's address with other filters. */
const at = (a: BuildsAsk) => ({ nav: "reports" as const, section: "value", item: "builds", query: buildsQuery(a) });

function failed(error: unknown): string {
  if (error instanceof CallFailed) return error.code === -32601 ? "This machine does not read build timings. Update it to see them." : error.message;
  return "The machine can’t be reached.";
}

/** What the page read: the range's history, the tiles' two windows, and the machine that answered. */
interface Read { host: MachineRef; history: BuildsHistory; last?: BuildsHistory | undefined; before?: BuildsHistory | undefined; key: string }

export function BuildsPage({ store, down }: { store: Store; down: boolean }) {
  const ask = parseBuildsQuery(route.value.query);
  const hosts = store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.buildsTrends1)).map((h) => h.id);
  const mac = store.macHostID.value;
  // This Mac first, so a tie goes to it.
  hosts.sort((a, b) => Number(b === mac) - Number(a === mac));
  const repos = useSignal<string[] | null>(null);
  const releases = useSignal<ForgeRelease[]>([]);
  const read = useSignal<Read | null>(null);
  const problem = useSignal<string | null>(null);
  const hostKey = hosts.join(" ");

  // The repositories: Planning's Delivery row's (the scope Me), and those the machines' folders release from.
  useEffect(() => {
    if (down) return;
    let live = true;
    const fromValue = store.link.call("reports/value", { range: "month", scope: { kind: "me" } })
      .then((v) => (v.delivery ?? []).map((d) => buildsRepo(d.repo)), () => [] as string[]);
    const fromReleases = Promise.all(hosts.filter((h) => store.has(h, Capability.forgeReleases1))
      .map((h) => store.link.call("forge/releases", { limit: 50 }, h).then((r) => r.releases, () => [] as ForgeRelease[])))
      .then((all) => all.flat());
    void Promise.all([fromValue, fromReleases]).then(([delivery, rel]) => {
      if (!live) return;
      releases.value = rel;
      repos.value = [...new Set([...delivery, ...rel.map((r) => buildsRepo(r.repo, r.forge))])];
    });
    return () => { live = false; };
  }, [down, hostKey]);

  const list = repos.value ?? [];
  const repo = ask.repo ?? list[0];
  const repoOptions = repo && !list.includes(repo) ? [repo, ...list] : list;
  const set = (change: Partial<BuildsAsk>) => replace(at({ ...ask, repo, ...change, change: undefined }));

  // The history of the range, and the tiles' windows, asked again when a filter changes.
  const wanted = JSON.stringify([repo, ask.range, ask.workflow, ask.job, ask.branch, hostKey]);
  const current = useRef(wanted);
  current.current = wanted;
  useEffect(() => {
    if (down || !repo || hosts.length === 0) return;
    problem.value = null;
    const filters: Omit<BuildsHistoryRequest, "from" | "to"> = {
      repo, timeZone,
      ...ask.workflow ? { workflow: ask.workflow } : {},
      ...ask.job ? { job: ask.job } : {},
      ...ask.branch === pullsBranch ? { pullRequests: true } : ask.branch ? { branch: ask.branch } : {},
    };
    const now = Date.now();
    const { from, to } = rangeBounds(ask.range, now);
    const range = { ...filters, from: toWireDate(from), to: toWireDate(to) };
    void Promise.all(hosts.map((host) => store.link.call("builds/history", range, host).then((history) => ({ host, history }), (e: unknown) => e)))
      .then(async (got) => {
        if (current.current !== wanted) return;
        const answers = got.filter((g): g is { host: MachineRef; history: BuildsHistory } => typeof g === "object" && g !== null && "history" in g);
        // The machine with the most runs, then the newest read.
        const best = answers.sort((a, b) => b.history.total.runs - a.history.total.runs
          || (b.history.readAt ?? 0) - (a.history.readAt ?? 0))[0];
        if (!best) { problem.value = failed(got[0]); return; }
        // A page opened with no workflow takes ci.yml, or the first (spec: "ci to start with").
        const workflow = workflowShown(ask.workflow, best.history.workflows);
        if (!ask.workflow && workflow) { replace(at({ ...ask, repo, workflow })); return; }
        read.value = { host: best.host, history: best.history, key: wanted };
        const w = tileWindows(now);
        const [last, before] = await Promise.all([w.last, w.before].map((b) =>
          store.link.call("builds/history", { ...filters, from: toWireDate(b.from), to: toWireDate(b.to) }, best.host).catch(() => undefined)));
        if (current.current === wanted) read.value = { host: best.host, history: best.history, last, before, key: wanted };
      });
  }, [wanted, down]);

  if (down) return <p class="hint">The control plane can’t be reached.</p>;
  if (hosts.length === 0) return <p class="hint">{noMachine}</p>;
  if (repos.value === null && !ask.repo) return <p class="hint">Loading…</p>;
  if (!repo) return <p class="hint">{noRepos}</p>;
  const shown = read.value?.key === wanted ? read.value : null;
  const h = shown?.history;
  const picked = ask.change && h?.changes.find((c) => c.job === ask.change!.job && c.firstSlow.ref === ask.change!.ref);
  if (ask.change && h && picked) return <ChangePicked store={store} host={shown.host} repo={repo} ask={ask} change={picked} history={h} />;

  const branch = branchWords(ask.branch, h?.defaultBranch);
  return (
    <div class="reports-pane builds-page">
      {h?.readAt && <LastUpdate at={wireMs(h.readAt)} />}
      <div class="builds-filters">
        <Choice label="Repository" value={repo} options={repoOptions.map((r) => [r, buildsRepoWords(r)] as const)} onPick={(r) => set({ repo: r, workflow: undefined, job: undefined })} />
        <Choice label="Range" value={ask.range} options={ranges.map((r) => [r, rangeSpan[r]] as const)} onPick={(r) => set({ range: r })} />
        {h && h.reader !== "none" && (
          <>
            <Choice label="Workflow" value={ask.workflow ?? ""} options={workflowOptions(h.workflows, ask.workflow)} onPick={(w) => set({ workflow: w || undefined, job: undefined })} />
            <Choice label="Job" value={ask.job ?? ""} options={[["", "All jobs"], ...withAsked(h.jobs, ask.job).map((j) => [j, j] as const)]} onPick={(j) => set({ job: j || undefined })} />
            <Choice label="Branch" value={ask.branch} options={branchOptions(h, ask.branch)} onPick={(b) => set({ branch: b })} />
          </>
        )}
      </div>
      {problem.value && <p class="hint">{problem.value}</p>}
      {!h && !problem.value && <p class="hint">Loading…</p>}
      {h && <Trend history={h} last={shown.last} before={shown.before} ask={ask} repo={repo} branch={branch}
        releases={releases.value.filter((r) => buildsRepo(r.repo, r.forge) === repo)} pick={(c) => go(at({ ...ask, repo, change: { job: c.job, ref: c.firstSlow.ref } }))} />}
    </div>
  );
}

function withAsked(list: readonly string[], asked: string | undefined): string[] {
  return asked && !list.includes(asked) ? [asked, ...list] : [...list];
}

function workflowOptions(workflows: readonly string[], asked: string | undefined): (readonly [string, string])[] {
  const list = withAsked(workflows, asked);
  return list.length === 0 ? [["", "None"]] : list.map((w) => [w, workflowWords(w)] as const);
}

/** Board 1, or board 4's words when there is nothing to draw. */
function Trend({ history: h, last, before, ask, repo, branch, releases, pick }: { history: BuildsHistory; last: BuildsHistory | undefined;
  before: BuildsHistory | undefined; ask: BuildsAsk; repo: string; branch: string; releases: readonly ForgeRelease[]; pick: (c: BuildsChange) => void }) {
  if (h.reader === "none") return <EmptyTiles words={noReaderWords(repo)} />;
  if (!h.readAt && h.total.runs === 0) return <EmptyTiles words={notReadWords(repo)} />;
  if (h.workflows.length === 0 && h.filledFrom) return <EmptyTiles words={noCIWords(repo)} />;
  const filling = h.filledFrom && wireMs(h.filledFrom) > rangeBounds(ask.range, Date.now()).from.getTime() + 86_400_000;
  const tiles = last ? buildsTiles(last.total, before?.total, branch, h.total.reruns, ask.range) : null;
  const empty = h.total.green === 0;
  const { from, to } = rangeBounds(ask.range, Date.now());
  const keys = dayKeys(from, to, timeZone);
  const bars = buildsBars(h.days, keys, ask.p90);
  const marks = releaseMarks(releases, from, to);
  const span = to.getTime() - from.getTime();
  const changes = [...h.changes].sort((a, b) => wireMs(b.at) - wireMs(a.at));
  return (
    <>
      {filling && <p class="quiet small">{fillingWords(h.filledFrom!, timeZone)}</p>}
      {tiles ? (
        <ul class="builds-tiles">
          {tiles.map((t) => (
            <li key={t.key} class="delivery-card">
              <span class="quiet small builds-tile-title">{t.title}</span>
              <span class="builds-tile-value">
                <span class="delivery-value strong">{t.value}</span>
                {t.delta && <span class={`builds-delta${t.delta.slower ? " slower" : t.delta.faster ? " faster" : ""}`}>{t.delta.words}</span>}
              </span>
              <span class="quiet small">{t.detail}</span>
            </li>
          ))}
        </ul>
      ) : <p class="hint">Loading…</p>}
      {empty ? <p class="hint">{noRunsWords(ask.workflow, branch, ask.range)}</p> : (
        <>
          <div class="builds-chart-head">
            <h3>{`${ask.job ? `${ask.job}: ` : ""}Time to green on ${branch}, by day`}</h3>
            <div class="tabs builds-stat" role="tablist" aria-label="The bars at">
              {([false, true] as const).map((p90) => (
                <button key={String(p90)} type="button" role="tab" aria-selected={ask.p90 === p90} class={ask.p90 === p90 ? "on" : ""}
                  onClick={() => replace(at({ ...ask, repo, p90 }))}>{p90 ? "P90" : "Median"}</button>
              ))}
            </div>
          </div>
          <div class="builds-trend">
            <TrendChart bars={bars} p90={ask.p90} marks={marks} changes={changes.map((c) => ({ c, x: (wireMs(c.at) - from.getTime()) / span }))} pick={pick} />
            <ul class="builds-legend">
              {legend.map((l) => <li key={l.key}><span class={`builds-swatch ${l.key}`} aria-hidden="true" /><span><span class="strong">{l.title}</span><br /><span class="quiet small">{l.words}</span></span></li>)}
            </ul>
          </div>
          {!ask.job && <p class="quiet small">{allJobsNote}</p>}
          {marks.length > 0 && <p class="quiet small">{releasesNote}</p>}
        </>
      )}
      <h3>Changes in this range</h3>
      {changes.length === 0 ? <p class="quiet small">{`No job’s run time on ${h.defaultBranch ?? "the default branch"} changed in this range.`}</p> : (
        <ul class="report-list builds-changes">
          {changes.map((c) => (
            <li key={`${c.job} ${c.firstSlow.ref}`}>
              <a href={routeHash(at({ ...ask, repo, change: { job: c.job, ref: c.firstSlow.ref } }))}>
                <span class={c.slower ? "builds-slower" : "builds-faster"} aria-hidden="true">{c.slower ? "▲ " : "▼ "}</span>{changeTitle(c, timeZone)}
              </a>
              <span class="quiet small">{`${changeLine(c)} ›`}</span>
            </li>
          ))}
        </ul>
      )}
      {h.longestRunnerWait && h.longestRunnerWait.wait >= 60 && (
        <p class="quiet small">{`The longest wait for a runner: ${h.longestRunnerWait.job} on ${runWhen(h.longestRunnerWait.run.made, timeZone)}, ${secondsWords(h.longestRunnerWait.wait)}, then it ran for ${secondsWords(h.longestRunnerWait.ran)}. Load, not code.`}</p>
      )}
    </>
  );
}

/** The tiles with "–" and why (board 4 notes 2 to 4). */
function EmptyTiles({ words }: { words: string }) {
  return (
    <ul class="builds-tiles">
      <li class="delivery-card builds-empty">
        <span class="quiet small builds-tile-title">Time to green · median</span>
        <span class="delivery-value strong">–</span>
        <span class="quiet small">{words}</span>
      </li>
    </ul>
  );
}

const W = 720;
const H = 220;
const AXIS = 72;
const TOP = 18;
const LANE = 22;

/** Board 1's chart: a stacked bar a day, the P90 line, the release lines and the changes lane under it. */
function TrendChart({ bars, p90, marks, changes, pick }: { bars: readonly BuildsBar[]; p90: boolean; marks: readonly ReleaseMark[];
  changes: readonly { c: BuildsChange; x: number }[]; pick: (c: BuildsChange) => void }) {
  const top = chartTop(bars, !p90);
  const plot = W - AXIS;
  const step = plot / Math.max(1, bars.length);
  const y = (s: number) => H - (s / top) * (H - TOP);
  const ticks = dayTicks(bars.length);
  const rows = laneRows(changes, (t) => t.x * plot, (t) => changeMark(t.c).length * 6.4 + 22);
  const laneCount = Math.max(1, ...rows.map((r) => r.row + 1));
  const height = H + 22 + (changes.length ? 20 + laneCount * LANE : 0);
  const line = !p90 ? bars.map((b, i) => b.runs > 0 ? `${i * step + step / 2},${y(b.p90)}` : null) : [];
  return (
    <svg class="builds-chart" viewBox={`0 0 ${W} ${height}`} role="img" aria-label={`Time to green by day, at the ${p90 ? "P90" : "median"}`}>
      <defs>
        <pattern id="builds-hatch" width="5" height="5" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
          <rect width="5" height="5" class="builds-hatch-ground" />
          <line x1="0" y1="0" x2="0" y2="5" class="builds-hatch-line" />
        </pattern>
      </defs>
      {[0.5, 1].map((f) => (
        <g key={f}>
          <line class="usage-grid" x1={0} x2={plot} y1={y(top * f)} y2={y(top * f)} />
          <text class="usage-axis" x={plot + 6} y={y(top * f) + 4}>{secondsWords(top * f)}</text>
        </g>
      ))}
      <line class="usage-grid" x1={0} x2={plot} y1={H} y2={H} />
      {bars.map((b, i) => {
        const x = i * step + step * 0.15;
        const w = step * 0.7;
        return (
          <g key={b.day}>
            {b.runs > 0 && (
              <>
                <rect class="builds-run" x={x} y={y(b.run)} width={w} height={H - y(b.run)} />
                <rect class="builds-runner" x={x} y={y(b.run + b.runner)} width={w} height={y(b.run) - y(b.run + b.runner)} fill="url(#builds-hatch)" />
                <rect class="builds-turn" x={x} y={y(b.total)} width={w} height={y(b.run + b.runner) - y(b.total)} />
              </>
            )}
            <rect class="usage-hit" x={i * step} y={TOP} width={step} height={H - TOP}>
              <title>{b.runs > 0 ? `${dayWords(b.day)}: ${b.runs} green runs · run ${secondsWords(b.run)}, a runner ${secondsWords(b.runner)}, its turn ${secondsWords(b.turn)}${p90 ? "" : ` · P90 ${secondsWords(b.p90)}`}` : `${dayWords(b.day)}: no green runs`}</title>
            </rect>
            {ticks.has(i) && <text class="usage-axis" x={i * step + step / 2} y={H + 14} text-anchor="middle">{dayWords(b.day)}</text>}
          </g>
        );
      })}
      {!p90 && <polyline class="builds-p90" points={line.filter((p) => p !== null).join(" ")} />}
      {!p90 && line.map((p, i) => p && <circle key={i} class="builds-p90-dot" cx={Number(p.split(",")[0])} cy={Number(p.split(",")[1])} r={1.8} />)}
      {marks.map((m) => (
        <g key={m.tag} class={`builds-release${m.minor ? "" : " patch"}`}>
          <line x1={m.at * plot} x2={m.at * plot} y1={TOP - 6} y2={H} />
          {m.minor && <text x={m.at * plot + 3} y={TOP - 8}>{m.tag}</text>}
        </g>
      ))}
      {changes.length > 0 && (
        <g transform={`translate(0 ${H + 26})`}>
          <text class="builds-lane-title" x={0} y={10}>Changes found, each job’s own run time</text>
          {rows.map(({ item: { c, x }, row }) => (
            <g key={`${c.job} ${c.firstSlow.ref}`} class={`builds-mark ${c.slower ? "slower" : "faster"}`} transform={`translate(${x * plot} ${20 + row * LANE})`}
              role="link" tabIndex={0} onClick={() => pick(c)} onKeyDown={(e) => { if (e.key === "Enter") pick(c); }}>
              <title>{`${changeTitle(c, timeZone)}: ${changeLine(c)}`}</title>
              <path d={c.slower ? "M0 12 L5 3 L10 12 Z" : "M0 3 L10 3 L5 12 Z"} />
              <text x={14} y={12}>{changeMark(c)}</text>
            </g>
          ))}
        </g>
      )}
    </svg>
  );
}

/** Board 2: a change picked. */
function ChangePicked({ store, host, repo, ask, change: c, history: h }: { store: Store; host: MachineRef; repo: string; ask: BuildsAsk;
  change: BuildsChange; history: BuildsHistory }) {
  const branch = h.defaultBranch ?? "the default branch";
  const runs = useSignal<{ before?: BuildsRun | undefined; after?: BuildsRun | undefined } | null>(null);
  useEffect(() => {
    let live = true;
    runs.value = null;
    const one = (ref: string) => store.link.call("builds/run", { repo, ref }, host).then((r) => r.run, () => undefined);
    void Promise.all([one(c.lastFast.ref), one(c.firstSlow.ref)]).then(([before, after]) => { if (live) runs.value = { before, after }; });
    return () => { live = false; };
  }, [c.lastFast.ref, c.firstSlow.ref, host]);
  const back = at({ ...ask, repo, change: undefined });
  return (
    <div class="reports-pane builds-page builds-change">
      {h.readAt && <LastUpdate at={wireMs(h.readAt)} />}
      <p class="small"><a href={routeHash(back)}>Builds</a> ›</p>
      <h2 class={c.slower ? "builds-slower-head" : ""}>{changeHeading(c, timeZone)}</h2>
      <p class="quiet">{changeContext(c, branch)}</p>
      <div class="builds-change-body">
        <section>
          <h3>{`${c.job}: each run on ${branch}`}</h3>
          <ChangeChart change={c} />
        </section>
        <section>
          <h3>Between the last fast run and the first slow one</h3>
          <ol class="builds-between">
            <li class="last-fast">
              <span class="builds-sha">{runName(c.lastFast)}</span>
              <span>{prLink(repo, c.lastFast.pr)}<span class="quiet small">{lastFastLine(c)}</span></span>
            </li>
            {c.between.map((b) => {
              const line = betweenLine(b, c);
              return (
                <li key={b.run.ref} class={line.kind}>
                  <span class="builds-sha">{runName(b.run)}</span>
                  <span>
                    {prLink(repo, b.run.pr)}
                    {line.kind === "firstSlow" && <span class="builds-first-slow strong">First slow run </span>}
                    <span class="small">{line.words}</span>
                  </span>
                </li>
              );
            })}
          </ol>
          <p class="quiet small">The change finder does not blame: the first slow run is the one to look at first. Two commits can land in one run.</p>
        </section>
      </div>
      <div class="builds-cards">
        <RunCard title="Run before" refRun={c.lastFast} run={runs.value?.before} loading={runs.value === null} />
        <RunCard title="Run after" refRun={c.firstSlow} run={runs.value?.after} loading={runs.value === null} />
      </div>
      <p class="quiet small">{cardsNote}</p>
    </div>
  );
}

function prLink(repo: string, pr: number | undefined) {
  if (!pr) return null;
  return <><a href={routeHash({ nav: "work", section: "pr", item: pullRef(repo, pr) })}>{`#${pr}`}</a>{" "}</>;
}

/** A whole run, the one before the change or the first slow one (board 2 note 5). */
function RunCard({ title, refRun, run, loading }: { title: string; refRun: BuildsChange["lastFast"]; run: BuildsRun | undefined; loading: boolean }) {
  return (
    <div class="delivery-card builds-run-card">
      <span class="quiet small builds-tile-title">{title}</span>
      <span class="strong">{`${runName(refRun)} · ${runWhen(refRun.made, timeZone)}`}</span>
      {loading ? <span class="quiet small">Loading…</span> : run ? (
        <>
          <span>{`The whole run: time to green ${secondsWords(run.ended)}`}</span>
          <span class="quiet small">{`waiting its turn ${secondsWords(run.turn)} · ${run.jobs.length} ${run.jobs.length === 1 ? "job" : "jobs"}`}</span>
        </>
      ) : <span class="quiet small">This machine no longer keeps this run’s jobs.</span>}
      {refRun.url && <a href={refRun.url} target="_blank" rel="noreferrer">Open the run on the forge ↗</a>}
    </div>
  );
}

const CW = 560;
const CH = 220;

/** Board 2's chart: each run of the job as a dot, the two medians as a step, the queue as grey marks on the floor. */
function ChangeChart({ change: c }: { change: BuildsChange }) {
  const p = changePlot(c);
  const plot = CW - AXIS;
  const y = (s: number) => CH - (s / p.top) * (CH - 10);
  const xAt = (f: number) => 4 + f * (plot - 8);
  const cut = xAt(p.at);
  return (
    <svg class="builds-chart builds-change-chart" viewBox={`0 0 ${CW} ${CH + 22}`} role="img"
      aria-label={`${c.job}: ${c.points.length} runs, the median ${secondsWords(c.medianBefore)} before and ${secondsWords(c.medianAfter)} after`}>
      <rect class="builds-cut" x={cut - 4} y={0} width={8} height={CH} />
      {[0.5, 1].map((f) => (
        <g key={f}>
          <line class="usage-grid" x1={0} x2={plot} y1={y(p.top * f)} y2={y(p.top * f)} />
          <text class="usage-axis" x={plot + 6} y={y(p.top * f) + 4}>{secondsWords(p.top * f)}</text>
        </g>
      ))}
      <line class="usage-grid" x1={0} x2={plot} y1={CH} y2={CH} />
      {p.points.map((pt) => (
        <g key={pt.ref}>
          <rect class="builds-queue-mark" x={xAt(pt.x) - 1.5} y={y(Math.min(pt.queue, p.top)) - 1.5} width={3} height={3} />
          <circle class={`builds-dot${pt.after ? " after" : ""}`} cx={xAt(pt.x)} cy={y(pt.ran)} r={3.2}>
            <title>{`${secondsWords(pt.ran)} run · ${secondsWords(pt.queue)} queue`}</title>
          </circle>
        </g>
      ))}
      <polyline class="builds-step" points={`${xAt(0)},${y(c.medianBefore)} ${cut},${y(c.medianBefore)} ${cut},${y(c.medianAfter)} ${xAt(1)},${y(c.medianAfter)}`} />
      <text class="builds-step-label" x={xAt(0) + 4} y={y(c.medianBefore) - 6}>{`median ${secondsWords(c.medianBefore)}`}</text>
      <text class="builds-step-label" x={xAt(1) - 4} y={y(c.medianAfter) - 6} text-anchor="end">{`median ${secondsWords(c.medianAfter)}`}</text>
      <text class="usage-axis" x={xAt(0)} y={CH + 14}>{runWhen(new Date(p.from), timeZone)}</text>
      <text class="usage-axis" x={xAt(1)} y={CH + 14} text-anchor="end">{runWhen(new Date(p.to), timeZone)}</text>
    </svg>
  );
}
