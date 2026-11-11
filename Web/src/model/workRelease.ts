// A release in the Work look (#4423, specs/4328-work-look/milestones.md, Releases), as WorkReleaseLook on the
// window (#4421): its row, its page's state line, its pull requests and its pipeline, from what lineage knows. A
// release is a version tag (v0.42.0) whose pull requests lineage linked part-of it; the forge's releases
// (forge/releases, #4426) bring the name, the notes, the author, drafts and pre-releases.
import type { LineageFigures, LineageGraph, LineageNode } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { costWords, spent } from "./value";
import { stageUrl, stageWords } from "./pipeline";
import { forgeName, leadWords, newer, repoOf, shortAge, shortRef, sortRows, version, type WorkRow } from "./work";
import { ago } from "./connectorSetup";
import { lineageUrl } from "./lineage";

/** The refs of the latest release of each repo: the highest version (milestones.md note 19). */
export function latest(rows: readonly WorkRow[]): Set<string> {
  const best = new Map<string, WorkRow>();
  for (const row of rows) {
    if (!version(shortRef(row.node.ref))) continue;
    const had = best.get(row.repo);
    if (!had || newer(shortRef(row.node.ref), shortRef(had.node.ref))) best.set(row.repo, row);
  }
  return new Set([...best.values()].map((r) => r.node.ref));
}

/** The release before ref in its repo: the highest version under its own; undefined for the first. */
export function previous(ref: string, rows: readonly WorkRow[]): WorkRow | undefined {
  const repo = repoOf(ref);
  const mine = shortRef(ref);
  if (!version(mine)) return undefined;
  let best: WorkRow | undefined;
  for (const r of rows) {
    const tag = shortRef(r.node.ref);
    if (r.repo !== repo || !version(tag) || !newer(mine, tag)) continue;
    if (!best || newer(tag, shortRef(best.node.ref))) best = r;
  }
  return best;
}

/** "v0.41.0…v0.42.0" (note 23). */
export const rangeWords = (from: string, to: string) => `${from}…${to}`;

/** The forge's compare page between two tags; undefined for a forge whose address the ref does not say. */
export function compareUrl(ref: string, from: string): string | undefined {
  if (!repoOf(ref).startsWith("github:")) return undefined;
  // The release's own page, …/releases/tag/v0.42.0, is in the repo the compare page is in.
  return lineageUrl({ kind: "release", ref })?.replace(/\/releases\/tag\/[^/]+$/, `/compare/${from}...${shortRef(ref)}`);
}

/** "1 pull request", "23 pull requests". */
export const pullsWords = (n: number) => n === 1 ? "1 pull request" : `${n} pull requests`;

/** When it was released, as lineage has it: its links are at the tag's commit time. Wide: "released 2 h ago"; on a
 * phone: "2 h". */
export function releasedWords(at: Date, compact: boolean, now: Date = new Date()): string {
  if (compact) return shortAge(Math.max(0, (now.getTime() - at.getTime()) / 1000));
  return `released ${ago(at, now)}`;
}

/** The page's state line after its glyph (note 23), the range apart, as it is a link: "released 2 h ago · 23 pull
 * requests". */
export function stateWords(released: Date | undefined, pulls: number | undefined, compact: boolean, now: Date = new Date()): string {
  return [...released ? [releasedWords(released, compact, now)] : [], ...pulls === undefined ? [] : [pullsWords(pulls)]].join(" · ");
}

const same = (a: LineageNode, b: LineageNode) => a.kind === b.kind && a.ref === b.ref;

/** The pull requests lineage linked part-of the release, the newest number first, each with what its forge said of it
 * (title, state and labels) where a machine resolved it. */
export function pullRequests(release: LineageNode, g: LineageGraph): WorkRow[] {
  const rows = new Map<string, WorkRow>();
  for (const l of g.links) {
    if (l.rel !== "part-of" || !same(l.to, release) || l.from.kind !== "pr" || rows.has(l.from.ref)) continue;
    const pr = l.from;
    const resolved = g.resolved?.[pr.ref];
    rows.set(pr.ref, {
      node: pr, title: resolved?.title ?? shortRef(pr.ref), state: resolved?.state ?? "merged",
      labels: (resolved?.labels ?? []).map((name) => ({ name })), repo: repoOf(pr.ref), assignees: [],
      updated: fromWireDate(l.endedAt ?? l.at).getTime() / 1000, url: lineageUrl(pr),
    });
  }
  return sortRows([...rows.values()], "newest");
}

/** One stage of a release's pipeline on its page (note 28): its words and its address outside Agents. */
export interface Stage { words: string; url?: string | undefined }

/** The stages lineage reached from the release (note 28): the CI run that built it, then each deploy (TestFlight, the
 * App Store, Cloud Run); empty when it knows none. Lineage records a stage once it got there, so each one shown is done;
 * one still running comes with #3588. */
export function pipeline(release: LineageNode, g: LineageGraph): Stage[] {
  const runs = g.links.filter((l) => l.rel === "builds" && same(l.to, release) && l.from.kind === "ci-run").map((l) => l.from);
  const deploys = g.links.filter((l) => l.rel === "deployed-as" && same(l.from, release) && l.to.kind === "deploy").map((l) => l.to);
  const nodes = [...runs, ...deploys].filter((n, i, all) => all.findIndex((m) => same(m, n)) === i);
  return nodes.map((n) => ({ words: n.kind === "ci-run" ? "CI run" : stageWords(n), url: stageUrl(n) }));
}

/** Lineage's line on the panel (note 29): "$18.40 · 3 sessions, 1 running · lead time 2h 10m", from lineage/figures;
 * undefined with none. */
export function figuresWords(f: LineageFigures): string | undefined {
  const parts: string[] = [];
  if (spent(f.cost)) parts.push(costWords(f.cost));
  if (f.sessions > 0) {
    const sessions = f.sessions === 1 ? "1 session" : `${f.sessions} sessions`;
    parts.push(f.running > 0 ? `${sessions}, ${f.running} running` : sessions);
  }
  if (f.leadTimeSeconds !== undefined) parts.push(`lead time ${leadWords(f.leadTimeSeconds)}`);
  return parts.length === 0 ? undefined : parts.join(" · ");
}

/** The runtimes that worked on it: "Claude 3 · Codex 1"; undefined with none. */
export function runtimesWords(f: LineageFigures, name: (id: string) => string): string | undefined {
  return f.runtimes.length === 0 ? undefined : f.runtimes.map((r) => `${name(r.runtimeID)} ${r.sessions}`).join(" · ");
}

/** Where the notes are, until Agents reads them (#4426): "The release notes are on GitHub." */
export const notesElsewhere = (ref: string) => `The release notes are on ${forgeName(ref)}.`;

export const noPulls = "Lineage links no pull request to this release. The first version tag of a repo links none.";
export const noPipeline = "No CI run or deploy in lineage yet.";
export const latestWords = "Latest";
