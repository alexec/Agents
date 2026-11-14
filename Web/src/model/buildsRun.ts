// Reports ▸ Planning ▸ Builds ▸ one run (#5179, spec 5166, board 3): a CI run's jobs and steps as a Gantt chart,
// against the run before, and the steps that changed most. The run comes from builds/run (#5177); times are seconds
// from each run's made time, so the run before lines up from its own start. This file has the shapes and the words;
// views/BuildsRun.tsx draws them.
import type { BuildsJob, BuildsRun, BuildsRunnerWait } from "../protocol/generated";
import { runName, secondsWords, workflowWords } from "./builds";

/** One row of the Gantt chart: a job, its wait for a runner and its run, the ticks of its steps, the long steps
 * named, and the same job of the run before as an outline. */
export interface GanttRow {
  name: string;
  runner?: string | undefined;
  made: number;
  started: number;
  ended: number;
  conclusion?: string | undefined;
  /** Each step's start but the first: a white tick. */
  ticks: number[];
  /** The steps long enough to name: their start, end and name. */
  named: { name: string; started: number; ended: number }[];
  before?: { made: number; ended: number } | undefined;
  picked: boolean;
}

/** The chart: the run's wait for its turn (the first row), a row a job in the order they were made, and the axis's
 * end, the later of the two runs' ends. */
export interface Gantt { turn: number; rows: GanttRow[]; end: number }

/** A step is named when it is at least this share of the axis. */
const nameShare = 0.08;

export function gantt(run: BuildsRun, before: BuildsRun | undefined, picked: string | undefined): Gantt {
  const end = Math.max(1, run.ended, before?.ended ?? 0);
  const prior = new Map((before?.jobs ?? []).map((j) => [j.name, j]));
  const rows = [...run.jobs].sort((a, b) => a.made - b.made || a.started - b.started || a.name.localeCompare(b.name)).map((j): GanttRow => {
    const steps = [...j.steps].sort((a, b) => a.started - b.started || a.number - b.number);
    const b = prior.get(j.name);
    return {
      name: j.name, runner: j.runner, made: j.made, started: j.started, ended: j.ended, conclusion: j.conclusion,
      ticks: steps.slice(1).map((s) => s.started).filter((t) => t > j.started && t < j.ended),
      named: steps.filter((s) => (s.ended - s.started) / end >= nameShare).map((s) => ({ name: s.name, started: s.started, ended: s.ended })),
      before: b ? { made: b.made, ended: b.ended } : undefined,
      picked: j.name === picked,
    };
  });
  return { turn: run.turn, rows, end };
}

/** The axis's ticks: a round step that gives about four to six of them, in seconds. */
export function ganttTicks(end: number): number[] {
  const steps = [10, 15, 30, 60, 120, 300, 600, 900, 1200, 1800, 3600, 7200];
  const step = steps.find((s) => end / s <= 6) ?? Math.ceil(end / 6 / 3600) * 3600;
  const out: number[] = [];
  for (let t = 0; t <= end; t += step) out.push(t);
  return out;
}

/** An axis tick's words: "0 min", "2 min", "30 s", "1 h". */
export function tickWords(seconds: number): string {
  if (seconds === 0) return "0 min";
  if (seconds < 60) return `${seconds} s`;
  if (seconds % 3600 === 0) return `${seconds / 3600} h`;
  return seconds % 60 === 0 ? `${seconds / 60} min` : `${(seconds / 60).toFixed(1)} min`;
}

/** A whole run's queue: made to its first job's start (its turn, then a runner); its run, from there to its end. */
export function runSplit(run: Pick<BuildsRun, "jobs" | "turn" | "ended">): { queue: number; run: number } {
  const first = run.jobs.length ? Math.min(...run.jobs.map((j) => j.started)) : run.turn;
  const queue = Math.max(run.turn, first);
  return { queue, run: Math.max(0, run.ended - queue) };
}

/** The heading's line (board 3): "ci on main, 8 Nov 16:51 · time to green 10.8 min (run 8.2 min, queue 2.5 min) ·
 * against efd532a, 10.3 min". when is the run's made time in words. */
export function runLine(run: BuildsRun, before: BuildsRun | undefined, when: string): string {
  const where = run.branch ? ` on ${run.branch}` : run.pr ? ` on #${run.pr}` : "";
  const s = runSplit(run);
  const against = before ? ` · against ${runName(before)}, ${secondsWords(before.ended)}` : " · no run before it to compare with";
  return `${workflowWords(run.workflow)}${where}, ${when} · time to green ${secondsWords(run.ended)} (run ${secondsWords(s.run)}, queue ${secondsWords(s.queue)})${against}`;
}

/** A row's tooltip: "go-darwin: a runner 3 s, ran 8.0 min, 12 steps · the run before ran 6.0 min". */
export function rowWords(r: GanttRow, job: BuildsJob | undefined, prior: BuildsJob | undefined): string {
  const steps = job ? `, ${job.steps.length} ${job.steps.length === 1 ? "step" : "steps"}` : "";
  const was = prior ? ` · the run before ran ${secondsWords(prior.ended - prior.started)}` : " · not in the run before";
  const failed = r.conclusion && r.conclusion !== "success" ? ` · ${r.conclusion}` : "";
  return `${r.name}: a runner ${secondsWords(r.started - r.made)}, ran ${secondsWords(r.ended - r.started)}${steps}${failed}${was}`;
}

/** One step in both runs (board 3 note 3): its time before and after, in seconds, as the forge says them. */
export interface StepChange { job: string; step: string; before: number; after: number; change: number; picked: boolean }

/** The steps that changed most: the picked job's first, then the rest, each by the size of its change; a job in only
 * one of the two runs is not compared but named, in only. A step is matched by its name in the same job, then by its
 * number when the name is not in the run before. */
export function stepChanges(run: BuildsRun, before: BuildsRun, picked: string | undefined, most = 12):
  { rows: StepChange[]; only: { job: string; in: "this" | "before" }[] } {
  const prior = new Map(before.jobs.map((j) => [j.name, j]));
  const now = new Set(run.jobs.map((j) => j.name));
  const rows: StepChange[] = [];
  for (const j of run.jobs) {
    const b = prior.get(j.name);
    if (!b) continue;
    const byName = new Map(b.steps.map((s) => [s.name, s]));
    const names = new Set(j.steps.map((s) => s.name));
    // A step renamed: the step of the same number, when its old name is not a step of this run's job.
    const byNumber = new Map(b.steps.filter((s) => !names.has(s.name)).map((s) => [s.number, s]));
    for (const s of j.steps) {
      const p = byName.get(s.name) ?? byNumber.get(s.number);
      if (!p) continue;
      const after = Math.max(0, s.ended - s.started);
      const was = Math.max(0, p.ended - p.started);
      rows.push({ job: j.name, step: s.name, before: was, after, change: after - was, picked: j.name === picked });
    }
  }
  rows.sort((a, b) => Number(b.picked) - Number(a.picked) || Math.abs(b.change) - Math.abs(a.change) || a.job.localeCompare(b.job));
  const pickedRows = rows.filter((r) => r.picked);
  const rest = rows.filter((r) => !r.picked).slice(0, Math.max(0, most - pickedRows.length));
  const only = [
    ...run.jobs.filter((j) => !prior.has(j.name)).map((j) => ({ job: j.name, in: "this" as const })),
    ...before.jobs.filter((j) => !now.has(j.name)).map((j) => ({ job: j.name, in: "before" as const })),
  ];
  return { rows: [...pickedRows, ...rest], only };
}

/** A step's change in seconds: "+83 s", "−1 s", "+1.2 min"; ±0 s when it did not move. */
export function changeWords(change: number): string {
  const d = Math.round(change);
  if (d === 0) return "±0 s";
  const words = Math.abs(d) < 100 ? `${Math.abs(d)} s` : secondsWords(Math.abs(d));
  return `${d > 0 ? "+" : "−"}${words}`;
}

/** The step table's heading: "Steps that changed most, against the run before: go-darwin first". */
export function stepsHeading(picked: string | undefined): string {
  return `Steps that changed most, against the run before${picked ? `: ${picked} first` : ""}`;
}

/** Under the table: the jobs in only one of the two runs, by name. */
export function onlyWords(only: readonly { job: string; in: "this" | "before" }[]): string[] {
  const here = only.filter((o) => o.in === "this").map((o) => o.job);
  const there = only.filter((o) => o.in === "before").map((o) => o.job);
  return [
    ...here.length ? [`Only in this run, not compared: ${here.join(", ")}.`] : [],
    ...there.length ? [`Only in the run before, not compared: ${there.join(", ")}.`] : [],
  ];
}

export const stepsNote = "Each step’s time is the forge’s own. A job that ran in only one of the two runs is listed under the table, not compared.";

/** The queue panel's words (board 3 note 4): "On 8 Oct 09:12, packages waited 25.4 min for a runner (xcode-27), then
 * ran for 12 s. Nothing in its commit could make it wait." */
export function queuePanelWords(w: BuildsRunnerWait, when: string, runner: string | undefined): string {
  const on = runner ? ` (${runner})` : "";
  return `On ${when}, ${w.job} waited ${secondsWords(w.wait)} for a runner${on}, then ran for ${secondsWords(w.ran)}. Nothing in its commit could make it wait: some runners are few.`;
}

/** Whether the run's own wait for a runner is short, so the range's longest wait is shown beside it: under a minute. */
export function ownWaitShort(run: BuildsRun): boolean {
  return run.jobs.every((j) => j.started - j.made < 60);
}

/** A note when the run has later attempts: the figures are this attempt's; re-runs are counted apart. */
export function attemptWords(attempt: number, attempts: number): string | null {
  if (attempts <= 1) return null;
  return `Attempt ${attempt} of ${attempts}. The time figures are the first attempt’s; re-runs are counted apart.`;
}
