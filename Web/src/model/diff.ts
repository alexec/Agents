// An edit as a line diff (LineDiff.rows, Packages/CodeText): the lines of the old text against
// the new, each unchanged, removed or added. Without the window's per-word marks.
import type { ChangedFile, DiffLine, GitView } from "../protocol/generated";

/** Beyond this many lines either side, the edit is shown as all removed then all added. */
const largest = 3_000;

function linesOf(text: string): string[] {
  const lines = text.split("\n");
  if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

export function lineDiff(old: string | undefined, next: string): DiffLine[] {
  if (next === "" && old) return linesOf(old).map((text) => ({ kind: "removed", text }));
  const b = linesOf(next);
  if (!old) return b.map((text) => ({ kind: "added", text }));
  const a = linesOf(old);
  if (a.length > largest || b.length > largest) {
    return [...a.map((text) => ({ kind: "removed" as const, text })), ...b.map((text) => ({ kind: "added" as const, text }))];
  }
  // The longest common subsequence, then a walk that puts removals before additions.
  const lcs: number[][] = Array.from({ length: a.length + 1 }, () => new Array<number>(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i]![j] = a[i] === b[j] ? lcs[i + 1]![j + 1]! + 1 : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!);
    }
  }
  const rows: DiffLine[] = [];
  let i = 0, j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      rows.push({ kind: "context", text: b[j]! });
      i++; j++;
    } else if (i < a.length && (j >= b.length || lcs[i + 1]![j]! >= lcs[i]![j + 1]!)) {
      rows.push({ kind: "removed", text: a[i]! });
      i++;
    } else {
      rows.push({ kind: "added", text: b[j]! });
      j++;
    }
  }
  return rows;
}

/**
 * The window's rule (ChangeFileView): the agent's edits, unless there are none, as for a file a
 * command wrote; then the file as it stands, where git can say what changed in it.
 */
export function wantsWhole(file: ChangedFile | undefined, git: GitView | undefined): boolean {
  const edits = (file?.editCount ?? 0) > 0 || file?.inProgress === true;
  return !edits && git !== undefined && !("unavailable" in git) && file?.outsideFolder === false && file?.state !== "binary";
}
