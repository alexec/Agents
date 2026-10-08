// The GitHub side of the CI watcher: every call is `gh` as the signed-in person, so the
// server holds no token. `fakeGitHub` reads and writes a JSON file instead, for tests and walks.
import { execFile } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";

export interface PR { number: number; title: string; branch: string; url: string }
export type Checks = "passing" | "failing" | "running" | "none";
export interface BoardPR extends PR { checks: Checks; failedRunId?: number }

/** A failed run as listed, before its PR and jobs are looked up. */
export interface RunRef {
  id: number; attempt: number; name: string; url: string;
  headSha: string; branch: string; prNumber?: number; updatedAt: string;
}
export interface FailedRunData {
  pr: PR; headSha: string;
  run: { id: number; attempt: number; name: string; url: string };
  failedJobs: { name: string; url: string }[];
}
export interface MergedPR { pr: PR; mergedAt: string; mergeSha: string }

export interface GitHub {
  /** Failed `pull_request` runs updated at or after `since`, oldest first or in any order. */
  failedRuns(repo: string, branch: string | undefined, since: string): Promise<{ runs: RunRef[]; truncated: boolean }>;
  /** The run's PR and failed jobs, or null when it belongs to no PR. */
  runDetails(repo: string, run: RunRef): Promise<FailedRunData | null>;
  /** PRs merged at or after `since`. */
  mergedPRs(repo: string, since: string): Promise<{ prs: MergedPR[]; truncated: boolean }>;
  listPRs(repo: string): Promise<BoardPR[]>;
  failedLog(repo: string, runId: number, job?: string): Promise<string>;
  rerunFailed(repo: string, runId: number): Promise<{ rerun: true; url: string }>;
  commentOnPR(repo: string, number: number, body: string): Promise<{ url: string }>;
}

export type GhErrorKind = "notSignedIn" | "rateLimited" | "notFound" | "failed";

export class GhError extends Error {
  kind: GhErrorKind;
  retryAfterMs?: number;
  constructor(kind: GhErrorKind, message: string, retryAfterMs?: number) {
    super(message);
    this.kind = kind;
    this.retryAfterMs = retryAfterMs;
  }
}

export const LOG_LINES = 300;
const MAX_PAGES = 10;
const PER_PAGE = 100;
/** How far back past `since` a run may have been created and still be rerun into view. */
const RERUN_WINDOW_MS = 24 * 3600_000;

const tail = (text: string, lines = LOG_LINES) => text.replace(/\n+$/, "").split("\n").slice(-lines).join("\n");
/** Text without terminal escapes or other control characters, but with its tabs and newlines. */
const plain = (text: string) =>
  text.replace(/\x1b\[[0-9;?]*[ -\/]*[@-~]/g, "").replace(/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/g, "")
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "");
const at = (time: string) => Date.parse(time);
const runURL = (repo: string, runId: number) => `https://github.com/${repo}/actions/runs/${runId}`;
const isFailed = (conclusion: string | null | undefined) =>
  ["failure", "timed_out", "startup_failure"].includes((conclusion ?? "").toLowerCase());

function formatLogs(jobs: { name: string; url: string; log: string }[], runId: number): string {
  if (jobs.length === 0) return `No failed jobs in run ${runId}.`;
  return jobs.map((j) => `== ${j.name} (${j.url}), last ${LOG_LINES} lines ==\n${tail(plain(j.log))}`).join("\n\n");
}

/** The rollup of one PR's checks, as `gh pr list --json statusCheckRollup` gives them. */
export function rollup(items: any[] | null | undefined): { checks: Checks; failedRunId?: number } {
  if (!items || items.length === 0) return { checks: "none" };
  let running = false;
  let failedRunId: number | undefined;
  let failing = false;
  for (const item of items) {
    if (item.__typename === "StatusContext") {
      const state = String(item.state ?? "").toUpperCase();
      if (state === "FAILURE" || state === "ERROR") failing = true;
      else if (state === "PENDING" || state === "EXPECTED") running = true;
      continue;
    }
    if (String(item.status ?? "").toUpperCase() !== "COMPLETED") { running = true; continue; }
    if (isFailed(item.conclusion) || String(item.conclusion).toUpperCase() === "ACTION_REQUIRED") {
      failing = true;
      const m = String(item.detailsUrl ?? "").match(/\/actions\/runs\/(\d+)/);
      if (m && failedRunId === undefined) failedRunId = Number(m[1]);
    }
  }
  if (failing) return failedRunId === undefined ? { checks: "failing" } : { checks: "failing", failedRunId };
  return { checks: running ? "running" : "passing" };
}

// MARK: gh

interface Response { status: number; headers: Map<string, string>; body: string }

function run(args: string[]): Promise<{ code: number; stdout: string; stderr: string; missing: boolean }> {
  return new Promise((resolve) => {
    execFile("gh", args, { maxBuffer: 64 * 1024 * 1024, timeout: 30_000 }, (error: any, stdout, stderr) => {
      resolve({
        code: error ? (typeof error.code === "number" ? error.code : 1) : 0,
        stdout: String(stdout), stderr: String(stderr), missing: error?.code === "ENOENT",
      });
    });
  });
}

function parse(stdout: string): Response | null {
  if (!stdout.startsWith("HTTP/")) return null;
  const split = stdout.match(/\r?\n\r?\n/);
  const head = split ? stdout.slice(0, split.index) : stdout;
  const body = split ? stdout.slice(split.index! + split[0].length) : "";
  const [statusLine, ...lines] = head.split(/\r?\n/);
  const headers = new Map<string, string>();
  for (const line of lines) {
    const i = line.indexOf(":");
    if (i > 0) headers.set(line.slice(0, i).trim().toLowerCase(), line.slice(i + 1).trim());
  }
  return { status: Number(statusLine.split(" ")[1]), headers, body };
}

function retryAfter(headers: Map<string, string>): number | undefined {
  const after = headers.get("retry-after");
  if (after) return Math.max(1000, Number(after) * 1000);
  if (headers.get("x-ratelimit-remaining") === "0") {
    const reset = Number(headers.get("x-ratelimit-reset"));
    if (reset) return Math.max(1000, reset * 1000 - Date.now());
  }
  return undefined;
}

function failure(missing: boolean, stderr: string, res: Response | null): GhError {
  if (missing) return new GhError("notSignedIn", "gh not signed in: gh is not installed");
  if (res?.status === 401 || /auth login|not logged in|authentication required|HTTP 401/i.test(stderr)) {
    return new GhError("notSignedIn", "gh not signed in: run `gh auth login`");
  }
  if (res && (res.status === 403 || res.status === 429)) {
    const ms = retryAfter(res.headers);
    if (ms !== undefined || /rate limit/i.test(res.body)) return new GhError("rateLimited", "GitHub rate limit", ms ?? 60_000);
  }
  if (!res && /rate limit/i.test(stderr)) return new GhError("rateLimited", "GitHub rate limit", 60_000);
  if (res?.status === 404 || /HTTP 404|Could not resolve/i.test(stderr)) return new GhError("notFound", "not found on GitHub");
  const why = res ? `HTTP ${res.status}` : stderr.trim().split("\n")[0] || "gh failed";
  return new GhError("failed", `gh: ${why}`);
}

export function realGitHub(): GitHub {
  // ETags of GET bodies, so an unchanged listing costs no rate limit (GitHub doesn't count 304s).
  const etags = new Map<string, { etag: string; body: string }>();

  async function api(path: string, options: { method?: string; fields?: Record<string, string>; cache?: boolean; log?: boolean } = {}) {
    const args = ["api", "-i", path, "-H", "Accept: application/vnd.github+json"];
    // gh refuses a body with terminal escapes, which job logs have; formatLogs strips them.
    if (options.log) args.push("--allow-escape-sequences");
    if (options.method) args.push("-X", options.method);
    for (const [key, value] of Object.entries(options.fields ?? {})) args.push("-f", `${key}=${value}`);
    const cached = options.cache ? etags.get(path) : undefined;
    if (cached) args.push("-H", `If-None-Match: ${cached.etag}`);
    const result = await run(args);
    const res = parse(result.stdout);
    if (res?.status === 304 && cached) return cached.body;
    if (res && res.status >= 200 && res.status < 300) {
      const etag = res.headers.get("etag");
      if (options.cache && etag) {
        etags.delete(path);
        etags.set(path, { etag, body: res.body });
        if (etags.size > 200) etags.delete(etags.keys().next().value!);
      }
      return res.body;
    }
    throw failure(result.missing, result.stderr, res);
  }
  const json = async (path: string) => JSON.parse(await api(path, { cache: true }));

  async function pr(repo: string, number: number): Promise<PR> {
    const p = await json(`repos/${repo}/pulls/${number}`);
    return { number: p.number, title: p.title, branch: p.head.ref, url: p.html_url };
  }

  async function failedJobs(repo: string, runId: number) {
    const { jobs } = await json(`repos/${repo}/actions/runs/${runId}/jobs?filter=latest&per_page=100`);
    return (jobs as any[]).filter((j) => isFailed(j.conclusion));
  }

  return {
    async failedRuns(repo, branch, since) {
      const runs: RunRef[] = [];
      const floor = at(since) - RERUN_WINDOW_MS;
      const query = `event=pull_request&status=failure&per_page=${PER_PAGE}` +
        (branch ? `&branch=${encodeURIComponent(branch)}` : "");
      for (let page = 1; page <= MAX_PAGES; page++) {
        const { workflow_runs: list } = await json(`repos/${repo}/actions/runs?${query}&page=${page}`);
        for (const r of list as any[]) {
          if (r.status !== "completed" || !isFailed(r.conclusion) || at(r.updated_at) < at(since)) continue;
          runs.push({
            id: r.id, attempt: r.run_attempt ?? 1, name: r.name ?? r.display_title ?? "", url: r.html_url,
            headSha: r.head_sha, branch: r.head_branch, prNumber: r.pull_requests?.[0]?.number,
            updatedAt: r.updated_at,
          });
        }
        // Runs are listed newest created first; a rerun keeps its created_at.
        if (list.length < PER_PAGE || at(list[list.length - 1].created_at) < floor) return { runs, truncated: false };
      }
      return { runs, truncated: true };
    },

    async runDetails(repo, ref) {
      let number = ref.prNumber;
      if (number === undefined) {
        // A fork's PR isn't on the run; find it by the head commit.
        const pulls = await json(`repos/${repo}/commits/${ref.headSha}/pulls`);
        number = (pulls as any[]).find((p) => p.head?.ref === ref.branch)?.number ?? (pulls as any[])[0]?.number;
      }
      if (number === undefined) return null;
      const jobs = await failedJobs(repo, ref.id);
      return {
        pr: await pr(repo, number), headSha: ref.headSha,
        run: { id: ref.id, attempt: ref.attempt, name: ref.name, url: ref.url },
        failedJobs: jobs.map((j) => ({ name: j.name, url: j.html_url })),
      };
    },

    async mergedPRs(repo, since) {
      const prs: MergedPR[] = [];
      for (let page = 1; page <= MAX_PAGES; page++) {
        const list = await json(`repos/${repo}/pulls?state=closed&sort=updated&direction=desc&per_page=${PER_PAGE}&page=${page}`);
        for (const p of list as any[]) {
          if (at(p.updated_at) < at(since)) return { prs, truncated: false };
          if (p.merged_at && at(p.merged_at) >= at(since)) {
            prs.push({ pr: { number: p.number, title: p.title, branch: p.head.ref, url: p.html_url },
              mergedAt: p.merged_at, mergeSha: p.merge_commit_sha });
          }
        }
        if (list.length < PER_PAGE) return { prs, truncated: false };
      }
      return { prs, truncated: true };
    },

    async listPRs(repo) {
      const result = await run(["pr", "list", "-R", repo, "--state", "open", "--limit", "100",
        "--json", "number,title,headRefName,statusCheckRollup,url"]);
      if (result.code !== 0) throw failure(result.missing, result.stderr, null);
      return (JSON.parse(result.stdout) as any[]).map((p) => ({
        number: p.number, title: p.title, branch: p.headRefName, url: p.url, ...rollup(p.statusCheckRollup),
      }));
    },

    async failedLog(repo, runId, job) {
      const jobs = (await failedJobs(repo, runId)).filter((j) => !job || j.name === job);
      const logs = [];
      for (const j of jobs) logs.push({ name: j.name, url: j.html_url, log: await api(`repos/${repo}/actions/jobs/${j.id}/logs`, { log: true }) });
      return formatLogs(logs, runId);
    },

    async rerunFailed(repo, runId) {
      await api(`repos/${repo}/actions/runs/${runId}/rerun-failed-jobs`, { method: "POST" });
      return { rerun: true, url: runURL(repo, runId) };
    },

    async commentOnPR(repo, number, body) {
      const comment = JSON.parse(await api(`repos/${repo}/issues/${number}/comments`, { method: "POST", fields: { body } }));
      return { url: comment.html_url };
    },
  };
}

// MARK: The fake

/**
 * Reads `file` on every call, so a test or a walk can append runs and PRs while it runs.
 * `"gh": "notSignedIn"` or `"gh": {"rateLimitedForMs": n}` makes every call fail that way.
 */
export function fakeGitHub(file: string): GitHub {
  const load = async () => {
    const data = JSON.parse(await readFile(file, "utf8"));
    if (data.gh === "notSignedIn") throw new GhError("notSignedIn", "gh not signed in: run `gh auth login`");
    if (data.gh?.rateLimitedForMs) throw new GhError("rateLimited", "GitHub rate limit", data.gh.rateLimitedForMs);
    return data;
  };
  const repoOf = (data: any, repo: string) => data.repos?.[repo] ?? { prs: [], runs: [] };
  const toPR = (p: any): PR => ({ number: p.number, title: p.title, branch: p.branch, url: p.url });
  const findRun = (data: any, repo: string, runId: number) => {
    const found = repoOf(data, repo).runs.find((r: any) => r.id === runId);
    if (!found) throw new GhError("notFound", `no run ${runId} in ${repo}`);
    return found;
  };

  return {
    async failedRuns(repo, branch, since) {
      const runs = (repoOf(await load(), repo).runs as any[])
        .filter((r) => r.event === "pull_request" && r.status === "completed" && isFailed(r.conclusion))
        .filter((r) => !branch || r.branch === branch)
        .filter((r) => at(r.updatedAt) >= at(since))
        .map((r) => ({ id: r.id, attempt: r.attempt ?? 1, name: r.name, url: r.url, headSha: r.headSha,
          branch: r.branch, prNumber: r.pr, updatedAt: r.updatedAt }));
      return { runs, truncated: false };
    },

    async runDetails(repo, ref) {
      const data = await load();
      const p = repoOf(data, repo).prs.find((x: any) => x.number === ref.prNumber);
      if (!p) return null;
      const run = findRun(data, repo, ref.id);
      return {
        pr: toPR(p), headSha: ref.headSha,
        run: { id: ref.id, attempt: ref.attempt, name: ref.name, url: ref.url },
        failedJobs: (run.jobs ?? []).filter((j: any) => isFailed(j.conclusion)).map((j: any) => ({ name: j.name, url: j.url })),
      };
    },

    async mergedPRs(repo, since) {
      const prs = (repoOf(await load(), repo).prs as any[])
        .filter((p) => p.state === "merged" && p.mergedAt && at(p.mergedAt) >= at(since))
        .map((p) => ({ pr: toPR(p), mergedAt: p.mergedAt, mergeSha: p.mergeSha }));
      return { prs, truncated: false };
    },

    async listPRs(repo) {
      return (repoOf(await load(), repo).prs as any[]).filter((p) => p.state === "open").map((p) => {
        const out: BoardPR = { ...toPR(p), checks: p.checks ?? "none" };
        if (p.checks === "failing" && p.failedRunId !== undefined) out.failedRunId = p.failedRunId;
        return out;
      });
    },

    async failedLog(repo, runId, job) {
      const run = findRun(await load(), repo, runId);
      const jobs = (run.jobs ?? []).filter((j: any) => isFailed(j.conclusion) && (!job || j.name === job));
      return formatLogs(jobs.map((j: any) => ({ name: j.name, url: j.url, log: j.log ?? "" })), runId);
    },

    async rerunFailed(repo, runId) {
      const data = await load();
      const run = findRun(data, repo, runId);
      const p = repoOf(data, repo).prs.find((x: any) => x.number === run.pr);
      if (p) { p.checks = "running"; delete p.failedRunId; }
      (data.reruns ??= []).push({ repo, runId, at: new Date().toISOString() });
      await writeFile(file, JSON.stringify(data, null, 2) + "\n");
      return { rerun: true, url: runURL(repo, runId) };
    },

    async commentOnPR(repo, number, body) {
      const data = await load();
      const p = repoOf(data, repo).prs.find((x: any) => x.number === number);
      if (!p) throw new GhError("notFound", `no PR ${number} in ${repo}`);
      (data.comments ??= []).push({ repo, number, body, at: new Date().toISOString() });
      await writeFile(file, JSON.stringify(data, null, 2) + "\n");
      return { url: `${p.url}#issuecomment-${data.comments.length}` };
    },
  };
}
