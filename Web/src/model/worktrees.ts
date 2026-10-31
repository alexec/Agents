// Activity ▸ Worktrees (#790), as AgentsKitCore's WorktreeTally and WorktreeSummary.cleanupOrder
// say it, so the page says what the window's and the Remote's say: idle ones first, largest first.
import type {
  BuildOutputRemoved, FolderWorktrees, RemovalCheck, WorktreeSize, WorktreeStatus, WorktreeSummary,
} from "../protocol/generated";
import { diskWords } from "./disk";
import type { Draft } from "./drafts";
import { giveBackInto } from "./promptQuote";

/** "4.1 GB", or "over 4.1 GB" when the walk ran out: WorktreeSize.words. */
export function sizeWords(size: WorktreeSize): string {
  return `${size.partial ? "over " : ""}${diskWords(size.bytes)}`;
}

/** No agent that is not archived works in it: WorktreeSummary.isIdle. */
export function isIdle(worktree: WorktreeSummary): boolean {
  return worktree.agents.length === 0;
}

/** Idle first, the largest of each first, unmeasured after, then by name: cleanupOrder. */
export function cleanupOrder(a: WorktreeSummary, b: WorktreeSummary): number {
  if (isIdle(a) !== isIdle(b)) return isIdle(a) ? -1 : 1;
  const x = a.size?.bytes ?? -1;
  const y = b.size?.bytes ?? -1;
  if (x !== y) return y - x;
  return a.name.localeCompare(b.name, undefined, { numeric: true });
}

export interface WorktreeTally {
  count: number; idle: number; bytes: number; idleBytes: number; partial: boolean; unmeasured: number;
}

export function tally(worktrees: readonly WorktreeSummary[]): WorktreeTally {
  const t: WorktreeTally = { count: 0, idle: 0, bytes: 0, idleBytes: 0, partial: false, unmeasured: 0 };
  for (const w of worktrees) {
    t.count += 1;
    if (isIdle(w)) t.idle += 1;
    if (!w.size) { t.unmeasured += 1; continue; }
    t.bytes += w.size.bytes;
    if (isIdle(w)) t.idleBytes += w.size.bytes;
    t.partial ||= w.size.partial;
  }
  return t;
}

/** The Activity row's tooltip: "12 worktrees, 5 idle". */
export function rowWords(t: WorktreeTally): string | null {
  if (t.count === 0) return null;
  return `${t.count} ${t.count === 1 ? "worktree" : "worktrees"}, ${t.idle} idle`;
}

export const worktreesEmpty = "No worktrees. A session started in a new worktree makes one.";
export const worktreesIntro = "Every folder's worktrees and how much each holds on disk. Idle ones, with no session in them, come first, largest first.";
export const measuring = "Measuring…";
export const cleanUpPrompt = "Remove worktrees and delete branches for any work that has been merged to the default branch.";

/**
 * Clean up worktrees' new-session draft (#1863): the words after what was half-typed there, and its
 * attachments kept, as the window's bar gives words back (PromptQuote.givingBack, #1739).
 */
export function cleanUpDraft(kept: Draft | undefined): Draft {
  return { text: giveBackInto(cleanUpPrompt, kept?.text ?? ""), attachments: kept?.attachments ?? [] };
}

/** The line at the top of the page: "Worktrees hold 38.2 GB, 30.1 GB of it idle." */
export function pageLine(t: WorktreeTally): string {
  if (t.count === 0) return worktreesEmpty;
  if (t.unmeasured >= t.count) return `Measuring ${t.count === 1 ? "1 worktree" : `${t.count} worktrees`}…`;
  return `Worktrees hold ${t.partial ? "over " : ""}${diskWords(t.bytes)}, ${diskWords(t.idleBytes)} of it idle.`;
}

/** After Remove build output. */
export function freedWords(removed: BuildOutputRemoved): string {
  if (removed.removed.length === 0) return "No build output to remove.";
  return `Freed ${sizeWords(removed.freed)}: ${removed.removed.join(", ")}.`;
}

/** What Remove… asks before it loses work. */
export function removalMessage(check: RemovalCheck, branch: string | undefined): string {
  const lost: string[] = [];
  if (check.uncommitted === 1) lost.push("1 uncommitted change");
  if (check.uncommitted > 1) lost.push(`${check.uncommitted} uncommitted changes`);
  if (check.unmerged) lost.push("commits that are not merged");
  return `This loses ${lost.join(" and ")}, and removes its branch ${branch ?? ""}.`;
}

/** "2 uncommitted · 1 unmerged · ↑1", or "clean": WorktreeStatus.summary. */
export function statusSummary(status: WorktreeStatus): string {
  const parts: string[] = [];
  if (status.uncommitted > 0) parts.push(`${status.uncommitted} uncommitted`);
  if ((status.unmerged ?? 0) > 0) parts.push(`${status.unmerged} unmerged`);
  const arrows = [(status.ahead ?? 0) > 0 ? `↑${status.ahead}` : null, (status.behind ?? 0) > 0 ? `↓${status.behind}` : null]
    .filter((a): a is string => a !== null);
  if (arrows.length > 0) parts.push(arrows.join(" "));
  return parts.length === 0 ? "clean" : parts.join(" · ");
}

/** Its branch, git status and who is in it, as the Remote's worktreeDetail; "Missing" when gone. */
export function worktreeDetail(worktree: WorktreeSummary, size?: WorktreeSize): string {
  if (!worktree.exists) return "Missing";
  const parts = [worktree.branch ?? "detached"];
  if (worktree.status) parts.push(statusSummary(worktree.status));
  const n = worktree.agents.length;
  if (n > 0) parts.push(`${n} agent${n === 1 ? "" : "s"} working`);
  if (size) parts.push(sizeWords(size));
  return parts.join(" · ");
}

/** Folders holding the most idle first, each folder's worktrees in cleanupOrder, sizes heard since filled in. */
export function forCleanup(groups: readonly FolderWorktrees[], heard: Record<string, WorktreeSize> = {}): FolderWorktrees[] {
  const sized = groups.map((g) => ({
    folder: g.folder,
    worktrees: g.worktrees.map((w): WorktreeSummary => {
      const size = heard[w.root];
      return size ? { ...w, size } : w;
    }).sort(cleanupOrder),
  }));
  return sized.map((g, i) => ({ g, i, idle: tally(g.worktrees).idleBytes }))
    .sort((a, b) => (b.idle - a.idle) || (a.i - b.i)).map((x) => x.g);
}
