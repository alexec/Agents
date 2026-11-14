// Where a release or a pull request is live (#5243, spec 5239-deploy-model boards 1 to 3): the rows of
// Deployed on a release's Work page and Live in on a pull request's, one for each environment, from one
// lineage/walk. A deploy node's resolved details carry the deploy itself (its target, version, times and
// job), its state as the host computes it (replaced when a newer deploy is live in its environment), and
// rollback and share:<per cent> as labels (#5241, #5246). Web + Mac link (#4937, Lead role, #5290): the
// Mac draws one link here, and the Remote has none.
import type { Deploy, LineageGraph, LineageNode, LineageResolved } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

/** The row's state, as its chip says it. */
export type DeployRowState = "waiting" | "running" | "live" | "failed" | "cancelled" | "replaced" | "rollback";

export const deployStateWords: Record<DeployRowState, string> = {
  waiting: "Waiting", running: "Going out", live: "Live", failed: "Failed", cancelled: "Cancelled",
  replaced: "Replaced", rollback: "Rollback",
};

/** One row: an environment, its tier when it is production, the component, then two lines. */
export interface DeployRow {
  /** The deploy the row is about. */
  node: LineageNode;
  environment: string;
  /** "production", only for the production tier (note 1). */
  tier?: string;
  component?: string;
  state: DeployRowState;
  /** "Remote 0.18.0 · since 8 Nov, 10:52" */
  line: string;
  /** "waited 28 min for approval · went out in 30 min", "replaced by v0.19.0" */
  more?: string;
  /** The job's page: a failed row's "the job's log ↗" (note 10). */
  url?: string;
  /** A waiting deploy's GitHub run, for its Approve and Deny (note 9): `owner/name/<run id>`. */
  gate?: string;
}

const same = (a: LineageNode, b: LineageNode) => a.kind === b.kind && a.ref === b.ref;

/** "28 min", "17 h 48 min", "42 s", "2 d 3 h". */
export function spanWords(seconds: number): string {
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return `${s} s`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  if (h < 48) return m % 60 === 0 ? `${h} h` : `${h} h ${m % 60} min`;
  const d = Math.floor(h / 24);
  return h % 24 === 0 ? `${d} d` : `${d} d ${h % 24} h`;
}

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "8 Nov, 10:52"; "14:05" today. */
export function whenWords(at: Date, now: Date): string {
  const clock = `${String(at.getHours()).padStart(2, "0")}:${String(at.getMinutes()).padStart(2, "0")}`;
  const today = at.getFullYear() === now.getFullYear() && at.getMonth() === now.getMonth() && at.getDate() === now.getDate();
  return today ? clock : `${at.getDate()} ${months[at.getMonth()]}, ${clock}`;
}

/** The environment's name: the id after `#` in an environment ref. */
function envName(ref: string): string {
  const i = ref.lastIndexOf("#");
  return i < 0 ? ref : ref.slice(i + 1);
}

/** "v0.18.0", else the first artifact's short id, from the deploy, else its title before " to ". */
export function versionWords(d: Deploy | undefined, r: LineageResolved | undefined): string {
  if (d?.version.name) return d.version.name;
  const a = d?.version.artifacts[0];
  if (a) return a.kind === "commit" ? a.id.slice(0, 7) : a.id;
  const title = r?.title ?? "";
  const i = title.indexOf(" to ");
  return i < 0 ? title : title.slice(0, i);
}

/** `owner/name/<run id>` of a GitHub job's address, as the waiting deploys' approvals are keyed (#3587). */
export function gateKey(url: string | undefined): string | undefined {
  const m = url ? /^https:\/\/github\.com\/([^/]+\/[^/]+)\/actions\/runs\/(\d+)/.exec(url) : null;
  return m ? `${m[1]}/${m[2]}` : undefined;
}

/** What one deploy is, before it becomes a row. */
interface Seen {
  node: LineageNode;
  resolved: LineageResolved | undefined;
  deploy: Deploy | undefined;
  environment: string;
  started?: Date;
  finished?: Date;
}

function seen(n: LineageNode, g: LineageGraph): Seen[] {
  const resolved = g.resolved?.[n.ref];
  const deploy = resolved?.deploy;
  const envs = g.links.filter((l) => l.rel === "part-of" && same(l.from, n) && l.to.kind === "environment").map((l) => envName(l.to.ref));
  const names = envs.length > 0 ? [...new Set(envs)] : deploy ? [deploy.target.environment.name] : [];
  const started = deploy?.started !== undefined ? fromWireDate(deploy.started)
    : resolved?.createdAt !== undefined ? fromWireDate(resolved.createdAt) : undefined;
  const finished = deploy?.finished !== undefined ? fromWireDate(deploy.finished) : undefined;
  return names.map((environment) => ({
    node: n, resolved, deploy, environment, ...(started ? { started } : {}), ...(finished ? { finished } : {}),
  }));
}

/** The resolved state: waiting, running, succeeded, failed, cancelled or replaced. */
const rawState = (s: Seen) => s.resolved?.state ?? s.deploy?.state ?? "";

/** The deploy that is live in an environment now, from its `live` links (#5246), other than this one. */
function liveInstead(s: Seen, g: LineageGraph): Seen | undefined {
  const live = g.links.filter((l) => l.rel === "live" && l.from.kind === "environment" && envName(l.from.ref) === s.environment
    && l.to.kind === "deploy" && !same(l.to, s.node)).map((l) => l.to);
  const n = live[0];
  return n ? seen(n, g).find((o) => o.environment === s.environment) : undefined;
}

function share(r: LineageResolved | undefined): number | undefined {
  const label = r?.labels?.find((l) => l.startsWith("share:"));
  const n = label ? Number(label.slice("share:".length)) : NaN;
  return Number.isFinite(n) ? n : undefined;
}

/** A row from a deploy, as a release's page says it. `since` is the PR's merge, for its lead time (note 6). */
function row(s: Seen, g: LineageGraph, now: Date, merged?: Date): DeployRow {
  const d = s.deploy;
  const version = versionWords(d, s.resolved);
  const component = d?.target.component.name ?? undefined;
  const what = component ? `${component} ${version.replace(/^v(?=\d)/, "")}` : version;
  const tier = d?.target.environment.tier === "production" ? "production" : undefined;
  const ran = s.started && s.finished ? spanWords((s.finished.getTime() - s.started.getTime()) / 1000) : undefined;
  const state = rawState(s);
  const rollback = s.resolved?.labels?.includes("rollback") === true || d?.rollback === true;
  const base = { node: s.node, environment: s.environment, ...(tier ? { tier } : {}), ...(component ? { component } : {}) };
  const after = merged && s.finished ? ` · ${spanWords((s.finished.getTime() - merged.getTime()) / 1000)} after merge` : "";
  switch (state) {
    case "waiting": {
      const gate = gateKey(d?.url);
      return { ...base, state: "waiting", line: `${what} · waiting for approval${s.started ? ` for ${spanWords((now.getTime() - s.started.getTime()) / 1000)}` : ""}`,
        ...(gate ? { gate } : {}), ...(d?.url ? { url: d.url } : {}) };
    }
    case "running":
      return { ...base, state: "running", line: `${what} · going out${s.started ? ` for ${spanWords((now.getTime() - s.started.getTime()) / 1000)}` : ""}`,
        ...(d?.url ? { url: d.url } : {}) };
    case "failed":
      return { ...base, state: "failed", line: `${what} · failed${ran ? ` after ${ran}` : ""}`,
        ...(d?.url ? { url: d.url, more: "the job’s log ↗" } : {}) };
    case "cancelled":
      return { ...base, state: "cancelled", line: `${what} · cancelled${ran ? ` after ${ran}` : ""}`, ...(d?.url ? { url: d.url } : {}) };
    case "replaced": {
      const next = liveInstead(s, g);
      const to = next?.finished ?? next?.started;
      const from = s.finished ?? s.started;
      const live = from ? `live ${whenWords(from, now)}${to ? ` to ${whenWords(to, now)}` : ""}` : undefined;
      const by = next ? `replaced by ${versionWords(next.deploy, next.resolved)}` : "replaced";
      return { ...base, state: "replaced", line: `${what} · ${live ?? by}`, ...(live ? { more: by } : {}) };
    }
    default: {
      const at = s.finished ?? s.started;
      const part = share(s.resolved);
      const since = at ? ` · since ${whenWords(at, now)}` : "";
      const more = [ran ? `went out in ${ran}` : undefined, part !== undefined ? `${part} % of the traffic` : undefined]
        .filter((w) => w !== undefined).join(" · ");
      if (merged) {
        const withIt = at ? `since ${whenWords(at, now)}, with ${version}` : `with ${version}`;
        return { ...base, state: rollback ? "rollback" : "live", line: `${what}${after}`, more: withIt };
      }
      return { ...base, state: rollback ? "rollback" : "live", line: `${what}${since}`, ...(more ? { more } : {}) };
    }
  }
}

const newest = (a: Seen, b: Seen) => (b.started?.getTime() ?? 0) - (a.started?.getTime() ?? 0);
const byEnvironment = (a: DeployRow, b: DeployRow) => a.environment.localeCompare(b.environment);

/** Deployed on a release's page (board 1): for each environment the release went to, its newest deploy there. */
export function deployedRows(release: LineageNode, g: LineageGraph, now: Date): DeployRow[] {
  const deploys = g.links.filter((l) => l.rel === "deploys" && same(l.to, release) && l.from.kind === "deploy").map((l) => l.from);
  const all = deploys.flatMap((n) => seen(n, g)).sort(newest);
  const first = all.filter((s, i) => all.findIndex((o) => o.environment === s.environment) === i);
  return first.map((s) => row(s, g, now)).sort(byEnvironment);
}

/**
 * Live in on a pull request's page (board 2): the environments its change reached, through the deploys of the
 * releases it is part of and the deploys that bring it. In each, the first deploy that went out with it, since a
 * newer deploy there carries the change too; with none yet, the newest one (waiting, going out or failed).
 */
export function liveInRows(pr: LineageNode, g: LineageGraph, now: Date, merged?: Date): DeployRow[] {
  const releases = g.links.filter((l) => l.rel === "part-of" && same(l.from, pr) && l.to.kind === "release").map((l) => l.to);
  const deploys = [
    ...g.links.filter((l) => l.rel === "deploys" && l.from.kind === "deploy" && releases.some((r) => same(r, l.to))).map((l) => l.from),
    ...g.links.filter((l) => l.rel === "brings" && same(l.to, pr) && l.from.kind === "deploy").map((l) => l.from),
  ].filter((n, i, list) => list.findIndex((m) => same(m, n)) === i);
  const all = deploys.flatMap((n) => seen(n, g));
  const envs = [...new Set(all.map((s) => s.environment))];
  return envs.map((env) => {
    const here = all.filter((s) => s.environment === env);
    const went = here.filter((s) => rawState(s) === "succeeded" || rawState(s) === "replaced")
      .sort((a, b) => (a.finished ?? a.started)!.getTime() - (b.finished ?? b.started)!.getTime());
    const first = went[0];
    if (first) {
      // Live with it, whether or not a newer deploy has replaced this one since.
      return row({ ...first, resolved: first.resolved ? { ...first.resolved, state: "succeeded" } : first.resolved }, g, now, merged);
    }
    return row(here.sort(newest)[0]!, g, now);
  }).sort(byEnvironment);
}

/** Deployed's count: "3 targets". */
export function targetsWords(n: number): string {
  return n === 1 ? "1 target" : `${n} targets`;
}

/** A release with no deploy in lineage. */
export const noDeploys = "Not deployed yet.";
/** A merged pull request in no deploy yet (note 7). */
export const notLiveYet = "Not deployed yet. Goes out with the next release.";
