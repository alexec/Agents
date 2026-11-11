// A pull request's page in the Work look (#4408, specs/4328-work-look/pull-request.md), as the window's WorkPullLook
// (#4406): the merge box at the end of the timeline (the review, the checks and conflicts as rows, then Merge, Approve
// and Rerun failed), Files changed in the header, the state line, and the Checks page of a 390 px page.
import type { ForgeAction, ForgeCheck, ForgeItemDetail, ForgeMergeMethod } from "../protocol/generated";
import { failedChecks, forgeName, mergeTitle, mergeWaits, shortAge } from "./work";
import { ago } from "./connectorSetup";

/** How a merge box row stands: its glyph's colour. pass is green, fail red, wait amber, info grey. */
export type MergeSign = "pass" | "fail" | "wait" | "info";

/** What a merge box row is about; the view picks its glyph by it and its sign. */
export type MergeRowKind = "review" | "draft" | "checks" | "conflicts" | "autoMerge";

/** One row of the merge box: Review required · No one approved yet · 2 unresolved threads. */
export interface MergeRow { kind: MergeRowKind; sign: MergeSign; title: string; line?: string | undefined }

/** The merge box of an open pull request (pull-request.md note 10 and its states). */
export interface MergeBox {
  /** Green when it can merge, red when a check failed or it has conflicts, grey otherwise (info). */
  border: MergeSign;
  rows: MergeRow[];
  /** The checks list is open from the start: a check failed. */
  checksOpen: boolean;
  /** Merge ▾ is there: not on a draft, nor with conflicts, nor while auto-merge is on. */
  merges: boolean;
  /** The main button waits for the checks (the accent colour), or merges now (green). */
  waits: boolean;
  approves: boolean;
  reruns: boolean;
  /** Resolve on GitHub: the branch has conflicts. */
  resolve: boolean;
}

/** Whether the item's page offers an action now (#4361); all of them from an earlier daemon, which sends none. */
export const offers = (d: ForgeItemDetail, action: ForgeAction) => !d.actions || d.actions.includes(action);

/** The merge box, from what the wire has; undefined for an item that is not an open pull request. */
export function mergeBox(d: ForgeItemDetail): MergeBox | undefined {
  const item = d.item;
  if (item.node.kind !== "pr" || item.state !== "open") return undefined;
  const draft = item.draft === true;
  const checks = checksRow(d.checks, item.checks);
  const conflicts = item.mergeable === "conflicting";
  const auto = item.autoMerge === true;
  const rows: MergeRow[] = [];
  if (draft) rows.push({ kind: "draft", sign: "info", title: "This is a draft", line: "It cannot merge until it is ready for review." });
  else {
    const review = reviewRow(item.review, d.reviewThreads);
    if (review) rows.push(review);
  }
  if (checks) rows.push(checks);
  if (item.mergeable === "conflicting") rows.push({ kind: "conflicts", sign: "fail", title: "This branch has conflicts", line: "Resolve them before it can merge." });
  else if (item.mergeable === "mergeable") rows.push({ kind: "conflicts", sign: "pass", title: "No conflicts with the base branch" });
  if (auto && !draft) rows.push({ kind: "autoMerge", sign: "info", title: "Auto-merge is on", line: `${methodTitle(d.mergeMethods?.[0])} when the checks pass` });
  const failed = checks?.sign === "fail";
  const waits = mergeWaits(d) || failed;
  const reviewed = item.review === undefined || item.review === "approved";
  const border: MergeSign = failed || conflicts ? "fail" : !draft && !waits && !auto && reviewed ? "pass" : "info";
  const head = d.head !== undefined;
  return {
    border, rows, checksOpen: failed,
    merges: !draft && !conflicts && !auto && head && (offers(d, "merge") || offers(d, "autoMerge")),
    waits, approves: !draft && head && offers(d, "approve"),
    reruns: failedChecks(d).length > 0 && offers(d, "rerun"), resolve: conflicts,
  };
}

const methodTitle = (m: ForgeMergeMethod | undefined) => m ? mergeTitle[m] : "Merge";

/** The main button's words: the repo's first method, Merge when checks pass while they run. */
export const mergeMain = (methods: readonly ForgeMergeMethod[] | undefined, waits: boolean) =>
  waits ? "Merge when checks pass" : methodTitle(methods?.[0]);

const threadsWords = (n: number | undefined) => n && n > 0 ? (n === 1 ? "1 unresolved thread" : `${n} unresolved threads`) : undefined;

/** The review row: Approved, Changes requested or Review required; undefined when the forge asks no review. */
export function reviewRow(review: string | undefined, threads: number | undefined): MergeRow | undefined {
  const unresolved = threadsWords(threads);
  const line = (first: string) => [first, ...unresolved ? [unresolved] : []].join(" · ");
  switch (review) {
    case "approved": return { kind: "review", sign: "pass", title: "Approved", line: unresolved };
    case "changes_requested": return { kind: "review", sign: "fail", title: "Changes requested", line: line("A reviewer asked for changes") };
    case "review_required": return { kind: "review", sign: "wait", title: "Review required", line: line("No one approved yet") };
    default: return undefined;
  }
}

/** The checks row: All checks passed · 14 passed, 1 skipped; Checks are running · 9 passed, 4 running; 1 check failed.
 * With no list, the summary word alone; undefined with none. */
export function checksRow(checks: readonly ForgeCheck[] | undefined, summary: string | undefined): MergeRow | undefined {
  const all = checks ?? [];
  const n = (state: string) => all.filter((c) => c.state === state).length;
  const [failing, running, passing, skipped] = [n("failing"), n("running"), n("passing"), n("skipped")];
  let state: string;
  if (all.length > 0) state = failing > 0 ? "failing" : running > 0 ? "running" : "passing";
  else if (summary === "failing" || summary === "running" || summary === "passing") state = summary;
  else return undefined;
  const counts = ([[failing, "failed"], [passing, "passed"], [running, "running"], [skipped, "skipped"]] as const)
    .filter(([k]) => k > 0).map(([k, w]) => `${k} ${w}`);
  const line = counts.length === 0 ? undefined : counts.join(", ");
  switch (state) {
    case "failing":
      return { kind: "checks", sign: "fail", title: failing === 0 ? "Some checks failed" : failing === 1 ? "1 check failed" : `${failing} checks failed`, line };
    case "running": return { kind: "checks", sign: "wait", title: "Checks are running", line };
    default: return { kind: "checks", sign: "pass", title: "All checks passed", line };
  }
}

/** The checks in the box's list: the failed first, then the running, then the rest, each in the forge's order. */
export function checksInOrder(checks: readonly ForgeCheck[]): ForgeCheck[] {
  const rank: Record<string, number> = { failing: 0, running: 1, passing: 2, skipped: 3 };
  return checks.map((c, i) => ({ c, i })).sort((a, b) => ((rank[a.c.state] ?? 4) - (rank[b.c.state] ?? 4)) || a.i - b.i).map((x) => x.c);
}

/** A check's sign: its glyph's colour. */
export const checkSign = (state: string): MergeSign => state === "passing" ? "pass" : state === "failing" ? "fail" : state === "running" ? "wait" : "info";

/** The Checks page's heading (note 17): 1 failed, 12 passed, 1 running; No checks with none. */
export function checksPageWords(checks: readonly ForgeCheck[]): string {
  const n = (state: string) => checks.filter((c) => c.state === state).length;
  const parts = ([["failing", "failed"], ["passing", "passed"], ["running", "running"], ["skipped", "skipped"]] as const)
    .map(([s, w]) => [n(s), w] as const).filter(([k]) => k > 0).map(([k, w]) => `${k} ${w}`);
  return parts.length === 0 ? "No checks" : parts.join(", ");
}

/** The header's Files changed 6; Files changed when the forge gives no count. */
export const filesChangedWords = (n: number | undefined) => n === undefined ? "Files changed" : `Files changed ${n}`;

/** The side panel's Branch, until the wire has the branches (#4406, missing fields): 6 files. */
export const branchWords = (n: number | undefined) => n === undefined ? undefined : n === 1 ? "1 file" : `${n} files`;

/** A pull request's state line after its pill, wide and narrow: "sam opened this pull request 2 hours ago · 4 comments";
 * merged: "sam's pull request was merged 10 min ago"; on a phone: "sam · 2 h · 4 comments". With no opened or merged time
 * from the forge (#4373), the last update's: "sam opened this pull request · updated 2 h ago". */
export function pullStateWords(p: {
  author?: string | undefined; state: string; updated?: Date | undefined; created?: Date | undefined; closed?: Date | undefined; comments: number;
}, now: Date = new Date()): { wide: string; short: string } {
  const comments = p.comments > 0 ? [p.comments === 1 ? "1 comment" : `${p.comments} comments`] : [];
  const at = p.state === "open" ? p.created : p.closed;
  const shortOf = (d: Date) => shortAge(Math.max(0, (now.getTime() - d.getTime()) / 1000));
  const age = !at && p.updated ? shortOf(p.updated) : undefined;
  const when = at ? ` ${ago(at, now)}` : "";
  const lead = p.state === "merged" ? (p.author ? `${p.author}’s pull request was merged${when}` : `Merged${when}`)
    : p.state === "closed" ? (p.author ? `${p.author}’s pull request was closed with unmerged commits${when}` : `Closed with unmerged commits${when}`)
    : p.author ? `${p.author} opened this pull request${when}` : undefined;
  const short = at ?? p.updated;
  return {
    wide: [...lead ? [lead] : [], ...age ? [age === "now" ? "updated now" : `updated ${age} ago`] : [], ...comments].join(" · "),
    short: [...p.author ? [p.author] : [], ...short ? [shortOf(short)] : [], ...comments].join(" · "),
  };
}

const reviewWord: Record<string, string> = { approved: "Approved", changes_requested: "Changes requested", review_required: "Review required" };

/** The Reviewers section, until the wire has each reviewer (#4406, missing fields): the review's state, or No one. */
export const reviewersWords = (review: string | undefined) => review ? reviewWord[review] ?? review.replaceAll("_", " ") : "No one";

/** In the merge box's place on a merged pull request. */
export const mergedStrip = "Merged.";
/** In place of the buttons when no machine of the person's writes to the forge. */
export const noWriter = (ref: string) => `No machine of yours can write to ${forgeName(ref)}.`;
/** Under a draft's merge box: the forge has the button. */
export const readyOnForge = (ref: string) => `Ready for review is on ${forgeName(ref)}.`;
export const resolveOnForge = (ref: string) => `Resolve on ${forgeName(ref)}`;
