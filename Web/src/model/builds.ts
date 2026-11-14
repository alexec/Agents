// Reports ▸ Planning ▸ Builds (#5178, spec 5166, boards 1, 2 and 4): how long CI takes, as a trend by day, and a
// change in one job's run time with the runs around it. The figures come from builds/history and builds/run
// (#5177) on a machine that reads the forge's CI runs; this file has the page's words, its address and the
// shapes of its charts. Run time points to a commit; waiting for a runner and waiting its turn are load.
import type { BuildsBetween, BuildsChange, BuildsDay, BuildsFigures, BuildsHistory, BuildsRunRef, BuildsStat, ReportRange, WireDate } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { rangeSpan, ranges } from "./reports";

/** The page's filters and what is picked, as the address keeps them after "?" (spec 5166 board 1 note 1). */
export interface BuildsAsk {
  /** A repository, as builds/history names it: github:alexec/agents. */
  repo?: string | undefined;
  range: ReportRange;
  /** A workflow's file name (ci.yml); absent is the page's choice. */
  workflow?: string | undefined;
  /** One job; absent is All jobs. */
  job?: string | undefined;
  /** "" is the default branch, "pulls" the pull requests' runs, anything else one branch. */
  branch: string;
  /** The bars at the 90th percentile, not the median. */
  p90: boolean;
  /** A change picked (board 2): its job and its first slow run's ref. */
  change?: { job: string; ref: string } | undefined;
}

export const pullsBranch = "pulls";

/** The filters an address names: #/reports/value/builds?repo=github:alexec/agents&range=month. */
export function parseBuildsQuery(query: string | undefined): BuildsAsk {
  const q = new URLSearchParams(query ?? "");
  const range = ranges.find((r) => r === q.get("range")) ?? "month";
  const change = q.get("change");
  const of = q.get("of");
  return {
    repo: q.get("repo") || undefined,
    range,
    workflow: q.get("workflow") || undefined,
    job: q.get("job") || undefined,
    branch: q.get("branch") ?? "",
    p90: q.get("stat") === "p90",
    change: change && of ? { job: of, ref: change } : undefined,
  };
}

/** The address's query for a set of filters, in a fixed order; a default is left out. */
export function buildsQuery(a: BuildsAsk): string {
  const q = new URLSearchParams();
  if (a.repo) q.set("repo", a.repo);
  q.set("range", a.range);
  if (a.workflow) q.set("workflow", a.workflow);
  if (a.job) q.set("job", a.job);
  if (a.branch) q.set("branch", a.branch);
  if (a.p90) q.set("stat", "p90");
  if (a.change) { q.set("change", a.change.ref); q.set("of", a.change.job); }
  return q.toString().replace(/%3A/gi, ":").replace(/%2F/gi, "/");
}

/** builds/history's name for a repository in another form: a lineage repo ref (github:repo:#alexec/agents, the
 * Delivery row's), or a forge and a path (forge/releases'). Lower case, as the store keeps it. */
export function buildsRepo(repo: string, forge?: string): string {
  if (forge) return `${forge}:${repo.replace(/^\/+|\/+$/g, "")}`.toLowerCase();
  const full = /^([a-z][a-z0-9-]*):repo:#?(.+)$/i.exec(repo);
  if (full) return `${full[1]}:${full[2]}`.toLowerCase();
  return repo.toLowerCase();
}

/** "alexec/agents" of "github:alexec/agents". */
export function buildsRepoWords(repo: string): string {
  return repo.replace(/^[a-z][a-z0-9-]*:/, "");
}

const forgeNames: Record<string, string> = {
  github: "GitHub", gitlab: "GitLab", azuredevops: "Azure DevOps", bitbucket: "Bitbucket", forgejo: "Forgejo", gitea: "Gitea",
};

/** The forge's name, from the repository's prefix. */
export function forgeName(repo: string): string {
  const forge = /^([a-z][a-z0-9-]*):/.exec(repo)?.[1] ?? "";
  return forgeNames[forge] ?? (forge || "This forge");
}

/** The Delivery row's CI card link (board 4 note 5): the page with the card's repository and the range. */
export function buildsLinkQuery(deliveryRepo: string, range: ReportRange): string {
  return buildsQuery({ repo: buildsRepo(deliveryRepo), range, branch: "", p90: false });
}

const rangeDays: Record<ReportRange, number> = { day: 1, week: 7, month: 30, threeMonths: 90 };
const day = 24 * 60 * 60 * 1000;

/** The range's runs: made in [from, to), to being now. */
export function rangeBounds(range: ReportRange, now: number): { from: Date; to: Date } {
  return { from: new Date(now - rangeDays[range] * day), to: new Date(now) };
}

/** The headline tiles' two windows (board 1 note 2): the last 7 days, and the 7 days before. */
export function tileWindows(now: number): { last: { from: Date; to: Date }; before: { from: Date; to: Date } } {
  return {
    last: { from: new Date(now - 7 * day), to: new Date(now) },
    before: { from: new Date(now - 14 * day), to: new Date(now - 7 * day) },
  };
}

/** The workflow the page opens on: the one asked for, else ci.yml (spec: "ci to start with"), else the first. */
export function workflowShown(asked: string | undefined, workflows: readonly string[]): string | undefined {
  if (asked) return asked;
  return workflows.find((w) => /^ci\.ya?ml$/.test(w)) ?? workflows[0];
}

/** A workflow's name without its file's extension: ci of ci.yml. */
export function workflowWords(workflow: string): string {
  return workflow.replace(/\.ya?ml$/, "");
}

/** A time in seconds, said as the boards say it: 79 s, 4.8 min, 14.2 min, 1 h 43 min. */
export function secondsWords(seconds: number): string {
  const s = Math.max(0, seconds);
  if (s < 100) return `${Math.round(s)} s`;
  if (s < 3600) return `${(s / 60).toFixed(1)} min`;
  const minutes = Math.round(s / 60);
  return `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
}

/** The branch filter's words: main for the default branch, "Pull requests", or the branch's name. */
export function branchWords(branch: string, defaultBranch: string | undefined): string {
  if (branch === "") return defaultBranch ?? "The default branch";
  return branch === pullsBranch ? "Pull requests" : branch;
}

/** The Branch filter's choices: the default branch, the pull requests, then the other branches of the range. */
export function branchOptions(h: Pick<BuildsHistory, "branches" | "defaultBranch">, asked: string): (readonly [string, string])[] {
  const others = h.branches.filter((b) => b !== h.defaultBranch).slice(0, 30);
  if (asked && asked !== pullsBranch && !others.includes(asked)) others.unshift(asked);
  return [["", branchWords("", h.defaultBranch)], [pullsBranch, "Pull requests"], ...others.map((b) => [b, b] as const)];
}

/** A rise and a fall: "+9 %", "−8 %"; the class says slower (red) or faster (green). */
export interface Delta { words: string; slower: boolean; faster: boolean }

const minus = "−";

function percentDelta(now: BuildsStat, before: BuildsStat): Delta | null {
  if (now.n === 0 || before.n === 0 || before.median <= 0) return null;
  const pct = Math.round(((now.median - before.median) / before.median) * 100);
  return { words: `${pct > 0 ? "+" : pct < 0 ? minus : ""}${Math.abs(pct)} %`, slower: pct >= 1, faster: pct <= -1 };
}

/** Queue time's change in seconds, not a share: 7 s to 79 s is +1,000 %, which says nothing (board 1 note 3). */
function secondsDelta(now: number, before: number): Delta {
  const d = Math.round(now - before);
  const words = Math.abs(d) < 100 ? `${Math.abs(d)} s` : secondsWords(Math.abs(d));
  return { words: `${d > 0 ? "+" : d < 0 ? minus : "±"}${words}`, slower: d >= 1, faster: d <= -1 };
}

export interface BuildsTile { key: string; title: string; value: string; detail: string; delta: Delta | null }

/** The four headline tiles, the last 7 days against the 7 days before (board 1 notes 2 and 3). With no runs in the
 * last 7 days each value is "–". reruns is the range's later attempts, counted apart. */
export function buildsTiles(last: BuildsFigures, before: BuildsFigures | undefined, branch: string, reruns: number, range: ReportRange): BuildsTile[] {
  const none = last.green === 0;
  const queue = last.runner.median + last.turn.median;
  const queueBefore = before && before.green > 0 ? before.runner.median + before.turn.median : undefined;
  const plural = (n: number, one: string) => `${n.toLocaleString("en-GB")} ${one}${n === 1 ? "" : "s"}`;
  return [
    { key: "toGreen", title: "Time to green · median", value: none ? "–" : secondsWords(last.toGreen.median),
      detail: none ? "No green runs in the last 7 days" : `P90 ${secondsWords(last.toGreen.p90)} · ${plural(last.green, "run")}, last 7 days`,
      delta: before ? percentDelta(last.toGreen, before.toGreen) : null },
    { key: "run", title: "Run time · median", value: none ? "–" : secondsWords(last.run.median),
      detail: "Jobs running. Points to a commit.", delta: before ? percentDelta(last.run, before.run) : null },
    { key: "queue", title: "Queue time · median", value: none ? "–" : secondsWords(queue),
      detail: none ? "Waiting its turn and for a runner. Load." : `${secondsWords(last.turn.median)} its turn, ${secondsWords(last.runner.median)} a runner. Load.`,
      delta: none || queueBefore === undefined ? null : secondsDelta(queue, queueBefore) },
    { key: "green", title: `Green runs on ${branch}`, value: none ? "–" : last.green.toLocaleString("en-GB"),
      detail: `Last 7 days · ${plural(reruns, "re-run")} in ${rangeSpan[range].replace(/^The /, "the ")}`, delta: null },
  ];
}

/** One day's bar: the run, waiting for a runner and waiting its turn, stacked, at the median or the P90; and the
 * P90 of time to green, the dotted line. Zero and no runs on a day with none. */
export interface BuildsBar { day: string; run: number; runner: number; turn: number; total: number; p90: number; runs: number }

/** The days of [from, to) in timeZone, as YYYY-MM-DD, oldest first. */
export function dayKeys(from: Date, to: Date, timeZone?: string): string[] {
  const f = new Intl.DateTimeFormat("en-CA", { timeZone: timeZone ?? "UTC", year: "numeric", month: "2-digit", day: "2-digit" });
  const out: string[] = [];
  for (let t = from.getTime(); t < to.getTime() + 3_600_000; t += 3_600_000) {
    const k = f.format(new Date(Math.min(t, to.getTime() - 1)));
    if (out[out.length - 1] !== k) out.push(k);
  }
  return out;
}

const pick = (s: BuildsStat, p90: boolean) => s.n === 0 ? 0 : p90 ? s.p90 : s.median;

/** A bar for each day of the range, a day with no runs empty. */
export function buildsBars(days: readonly BuildsDay[], keys: readonly string[], p90: boolean): BuildsBar[] {
  const byDay = new Map(days.map((d) => [d.day, d.figures]));
  return keys.map((day) => {
    const f = byDay.get(day);
    if (!f || f.green === 0) return { day, run: 0, runner: 0, turn: 0, total: 0, p90: 0, runs: f?.runs ?? 0 };
    const run = pick(f.run, p90);
    const runner = pick(f.runner, p90);
    const turn = pick(f.turn, p90);
    return { day, run, runner, turn, total: run + runner + turn, p90: pick(f.toGreen, true), runs: f.green };
  });
}

/** The chart's top in seconds: a round step above the tallest bar or P90 point. */
export function chartTop(bars: readonly BuildsBar[], withLine: boolean): number {
  const most = Math.max(0, ...bars.map((b) => Math.max(b.total, withLine ? b.p90 : 0)));
  if (most <= 0) return 60;
  const steps = [60, 120, 300, 600, 900, 1200, 1800, 2700, 3600, 5400, 7200, 10800];
  return steps.find((s) => s >= most) ?? Math.ceil(most / 3600) * 3600;
}

/** A short date from a day key: "18 Oct". */
export function dayWords(key: string): string {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(Date.UTC(y!, m! - 1, d!)).toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "UTC" });
}

/** Which bars get a date under them: about six, evenly. */
export function dayTicks(count: number): Set<number> {
  const every = Math.max(1, Math.round(count / 6));
  const out = new Set<number>();
  for (let i = count - 1; i >= 0; i -= every) out.add(i);
  return out;
}

/** A release tag in the range, as a marker (board 1 note 5): a minor tag (vX.Y.0) is labelled, a patch is a fainter
 * line with no label. at is its share of the range, 0 to 1. */
export interface ReleaseMark { tag: string; at: number; minor: boolean }

export function releaseMarks(releases: readonly { tag: string; publishedAt?: string | undefined; createdAt?: string | undefined }[],
  from: Date, to: Date): ReleaseMark[] {
  const span = to.getTime() - from.getTime();
  return releases.flatMap((r) => {
    const when = Date.parse(r.publishedAt ?? r.createdAt ?? "");
    if (!Number.isFinite(when) || when < from.getTime() || when >= to.getTime()) return [];
    return [{ tag: r.tag, at: (when - from.getTime()) / span, minor: /^v?\d+\.\d+\.0$/.test(r.tag) }];
  }).sort((a, b) => a.at - b.at);
}

/** A change's share of its median: "+32 %", "−96 %". */
export function changeShare(c: Pick<BuildsChange, "medianBefore" | "medianAfter">): string {
  if (c.medianBefore <= 0) return "";
  const pct = Math.round(((c.medianAfter - c.medianBefore) / c.medianBefore) * 100);
  return `${pct > 0 ? "+" : pct < 0 ? minus : ""}${Math.abs(pct)} %`;
}

/** The change in the lane under the chart: "go-darwin +32 %". */
export function changeMark(c: BuildsChange): string {
  return `${c.job} ${changeShare(c)}`;
}

/** A wire date's milliseconds. */
export const wireMs = (d: WireDate) => fromWireDate(d).getTime();

const dateWords = (at: WireDate | Date, timeZone?: string) => asDate(at).toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone });
const asDate = (at: WireDate | Date) => at instanceof Date ? at : fromWireDate(at);
const longDate = (at: WireDate | Date, timeZone?: string) => asDate(at).toLocaleDateString("en-GB", { day: "numeric", month: "long", timeZone });
const timeWords = (at: WireDate | Date, timeZone?: string) => asDate(at).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone });

/** A change in the list (board 1 note 8): "go-darwin slower, 8 Nov". */
export function changeTitle(c: BuildsChange, timeZone?: string): string {
  return `${c.job} ${c.slower ? "slower" : "faster"}, ${dateWords(c.at, timeZone)}`;
}

/** Its line: "4.8 min → 6.4 min · 6 commits". The commits are the runs after the last fast run, to the first slow one. */
export function changeLine(c: BuildsChange): string {
  const n = c.between.length;
  return `${secondsWords(c.medianBefore)} → ${secondsWords(c.medianAfter)} · ${n} ${n === 1 ? "commit" : "commits"}`;
}

/** Board 2's heading: "go-darwin slower from 8 November: 4.8 min → 6.4 min (+32 %)". */
export function changeHeading(c: BuildsChange, timeZone?: string): string {
  return `${c.job} ${c.slower ? "slower" : "faster"} from ${longDate(c.at, timeZone)}: ${secondsWords(c.medianBefore)} → ${secondsWords(c.medianAfter)} (${changeShare(c)})`;
}

/** Whether the queue moved too: by 30 s and a fifth, the change finder's own floor for a run. */
export function queueMoved(c: Pick<BuildsChange, "queueBefore" | "queueAfter">): boolean {
  const d = Math.abs(c.queueAfter - c.queueBefore);
  return d >= 30 && d >= 0.2 * Math.max(c.queueBefore, 1);
}

/** Under the heading (board 2 note 1): where, the runner, and the queue before and after. */
export function changeContext(c: BuildsChange, branch: string): string {
  const runner = c.runner ? ` Runner: ${c.runner}.` : "";
  const queue = `Queue time: ${secondsWords(c.queueBefore)} before, ${secondsWords(c.queueAfter)} after`;
  const verdict = queueMoved(c) ? ": load moved too, but the run time is the jobs' own, so look at the commits." : ", so not load: look at the commits.";
  return `Run time on ${branch}, the median of the runs before and after.${runner} ${queue}${verdict}`;
}

/** A run's short name: its commit's first 7 characters, else its run number. */
export function runName(r: Pick<BuildsRunRef, "headSha" | "id">): string {
  return r.headSha ? r.headSha.slice(0, 7) : `run ${r.id}`;
}

/** A run's time: "8 Nov 16:08". */
export function runWhen(made: WireDate | Date, timeZone?: string): string {
  return `${dateWords(made, timeZone)} ${timeWords(made, timeZone)}`;
}

export type BetweenKind = "lastFast" | "firstSlow" | "ran" | "notRun" | "cancelled";

/** A commit between the last fast run and the first slow one (board 2 notes 3 and 4): what its run did with the job. */
export function betweenLine(b: BuildsBetween, c: BuildsChange): { kind: BetweenKind; words: string } {
  const failed = b.run.conclusion === "failure" ? " · the run failed" : "";
  if (b.run.ref === c.firstSlow.ref) return { kind: "firstSlow", words: `${c.job} ${secondsWords(b.jobRun ?? 0)}${failed}` };
  if (b.run.conclusion === "cancelled") return { kind: "cancelled", words: "Its run was cancelled for a newer push; the next run tested it too" };
  if (!b.ran) return { kind: "notRun", words: `Did not run ${c.job}: its paths did not select it` };
  return { kind: "ran", words: `${c.job} ${secondsWords(b.jobRun ?? 0)}${failed}` };
}

/** The last fast run's line, from its point: "Last fast run: go-darwin 5.0 min". */
export function lastFastLine(c: BuildsChange): string {
  const p = c.points.find((x) => x.ref === c.lastFast.ref);
  return p ? `Last fast run: ${c.job} ${secondsWords(p.ran)}` : "Last fast run";
}

/** A pull request's Work page ref, from the repository and its number: github:pr:alexec/agents#4145. */
export function pullRef(repo: string, pr: number): string {
  const [forge, path] = [repo.slice(0, repo.indexOf(":")), repo.slice(repo.indexOf(":") + 1)];
  return `${forge}:${forge === "gitlab" ? "mr" : "pr"}:${path}#${pr}`;
}

/** Board 2's scatter: each run of the job around the change, x its share of the time, y its run time; the queue as
 * a grey mark, at most at the top. The two medians as a step at the change. */
export interface ChangePlot { points: { ref: string; x: number; ran: number; queue: number; after: boolean }[]; at: number; top: number; from: number; to: number }

export function changePlot(c: BuildsChange): ChangePlot {
  const times = c.points.map((p) => wireMs(p.made));
  const at = wireMs(c.at);
  const from = Math.min(at, ...times);
  const to = Math.max(at, ...times);
  const span = Math.max(1, to - from);
  // The scale is the run times': a long queue is drawn at the top, so one outlier does not flatten the runs.
  const most = Math.max(c.medianBefore, c.medianAfter, ...c.points.map((p) => p.ran));
  return {
    points: c.points.map((p, i) => ({ ref: p.ref, x: (times[i]! - from) / span, ran: p.ran, queue: p.queue, after: times[i]! >= at })),
    at: (at - from) / span, top: most > 0 ? most * 1.1 : 60, from, to,
  };
}

/** Changes in the lane, placed so their labels do not overlap: each in the first row that is free at its place. x and
 * the label's width are in the chart's units. */
export function laneRows<T>(items: readonly T[], x: (t: T) => number, width: (t: T) => number): { item: T; row: number }[] {
  const ends: number[] = [];
  return [...items].sort((a, b) => x(a) - x(b)).map((item) => {
    const start = x(item);
    let row = ends.findIndex((end) => end <= start);
    if (row < 0) { row = ends.length; ends.push(0); }
    ends[row] = start + width(item);
    return { item, row };
  });
}

// The empty states (board 4).

/** No runs in the range (board 4 note 2). */
export function noRunsWords(workflow: string | undefined, branch: string, range: ReportRange): string {
  const what = workflow ? `${workflowWords(workflow)} runs` : "CI runs";
  return `No ${what} on ${branch} finished in ${rangeSpan[range].replace(/^The /, "the ")}. Try a longer range, or Branch ▸ Pull requests.`;
}

/** The forge has no CI runs for the repository (board 4 note 3). */
export function noCIWords(repo: string): string {
  return `${buildsRepoWords(repo)} has no ${repo.startsWith("github:") ? "GitHub Actions" : "CI"} runs. Builds come from the forge’s CI runs.`;
}

/** A forge Agents does not read CI timings from yet (board 4 note 4). */
export function noReaderWords(repo: string): string {
  return `${forgeName(repo)}: Agents does not read its CI runs yet, so there is nothing to draw for ${buildsRepoWords(repo)}.`;
}

/** The machine has not read the repository's runs yet. */
export function notReadWords(repo: string): string {
  return `Your machine has not read the CI runs of ${buildsRepoWords(repo)} yet. It reads them every 5 minutes, and fills the last 90 days over some hours, today first.`;
}

/** The backfill has not reached the range's start yet. */
export function fillingWords(filledFrom: WireDate, timeZone?: string): string {
  return `Your machine is still reading the older runs: this page has them from ${longDate(filledFrom, timeZone)}, and fills further back each hour.`;
}

/** No machine that reads build timings answers. */
export const noMachine = "None of your machines that read build timings answers now. Builds come from your machines’ reads of the forge, while they are awake.";
/** No repository to pick. */
export const noRepos = "No repository yet. Builds shows the repositories of Planning’s Delivery row and those your machines’ folders release from.";

/** The colours in words, beside the chart (board 1 note 7): the design point. */
export const legend: readonly { key: "run" | "runner" | "turn"; title: string; words: string }[] = [
  { key: "run", title: "Run time", words: "The jobs ran. A rise that stays points to a commit: the change finder looks here, on the default branch." },
  { key: "runner", title: "Waiting for a runner", words: "A job waited for a machine: some runners are few. Load, never a culprit." },
  { key: "turn", title: "Waiting its turn", words: "The run before it on the branch was still going. Load from merges, never a culprit." },
];

/** Under the chart with All jobs (board 1 note 4). */
export const allJobsNote = "With All jobs a bar is whole runs, which mix in which jobs ran. The changes are each job’s own run time.";
/** Under the changes lane (board 1 note 5). */
export const releasesNote = "A dashed purple line is a release tag: a marker only.";
/** Under board 2's run cards. */
export const cardsNote = "The cards are the whole run: its queue is mostly waiting its turn, which the change finder never looks at. Only run time on the default branch is searched for changes; a pull request’s runs are its author’s own.";
