// An edit as a line diff (LineDiff.rows, Packages/CodeText): the lines of the old text against
// the new, each unchanged, removed or added; and the words that changed within a line (WordDiff).
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

/** A diff line with the stretches of it that changed, as UTF-16 [from, to) offsets (WordDiff). */
export type MarkedLine = DiffLine & { changed?: [number, number][] };

/** Lines longer than this are not compared word by word (Limits.wordMarkMaxLine). */
const wordMarkMaxLine = 1_000;
/** Change blocks with more pairs than this are left unmarked (Limits.wordMarkMaxPairs). */
const wordMarkMaxPairs = 200;

type Token = { text: string; from: number; to: number };

/** A line in words: runs of letters, digits and underscores; runs of whitespace; every other character alone. */
export function tokens(line: string): Token[] {
  const kind = (c: string) => /[\p{L}\p{N}_]/u.test(c) ? 0 : /\s/u.test(c) ? 1 : 2;
  const result: Token[] = [];
  let start = 0, offset = 0, current: number | undefined;
  for (const c of line) {
    const k = kind(c);
    if (current !== undefined && (current !== k || k === 2)) {
      result.push({ text: line.slice(start, offset), from: start, to: offset });
      start = offset;
    }
    current = k;
    offset += c.length;
  }
  if (current !== undefined) result.push({ text: line.slice(start), from: start, to: offset });
  return result;
}

/**
 * The indices removed from a and inserted from b by a shortest edit (Myers), or null when it
 * takes more than `most` edits.
 */
function editScript(a: string[], b: string[], most: number): { removed: number[]; inserted: number[] } | null {
  const n = a.length, m = b.length, max = Math.min(n + m, most);
  const offset = max + 1;
  const v = new Int32Array(2 * max + 3);
  const trace: Int32Array[] = [];
  for (let d = 0; d <= max; d++) {
    trace.push(v.slice());
    for (let k = -d; k <= d; k += 2) {
      let x = k === -d || (k !== d && v[offset + k - 1]! < v[offset + k + 1]!) ? v[offset + k + 1]! : v[offset + k - 1]! + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) { x++; y++; }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        const removed: number[] = [], inserted: number[] = [];
        let cx = n, cy = m;
        for (let e = d; e > 0; e--) {
          const w = trace[e]!, kk = cx - cy;
          const down = kk === -e || (kk !== e && w[offset + kk - 1]! < w[offset + kk + 1]!);
          const pk = down ? kk + 1 : kk - 1;
          const px = w[offset + pk]!, py = px - pk;
          while (cx > px + (down ? 0 : 1) && cy > py + (down ? 1 : 0)) { cx--; cy--; }
          if (down) inserted.push(py); else removed.push(px);
          cx = px; cy = py;
        }
        return { removed: removed.reverse(), inserted: inserted.reverse() };
      }
    }
  }
  return null;
}

/** Neighbouring tokens that both changed read as one change: `foo(bar` not `foo`,`(`,`bar`. */
function merged(ranges: [number, number][]): [number, number][] {
  const result: [number, number][] = [];
  for (const r of [...ranges].sort((x, y) => x[0] - y[0])) {
    const last = result[result.length - 1];
    if (last && last[1] >= r[0]) last[1] = Math.max(last[1], r[1]);
    else result.push([r[0], r[1]]);
  }
  return result;
}

/**
 * The changed stretches on each side of a changed line, or null when the two have too little in
 * common to be one line edited (a rewrite, marked as a whole by its line), or are too long (WordDiff.marks).
 */
export function wordMarks(old: string, next: string): { old: [number, number][]; next: [number, number][] } | null {
  if (old.length > wordMarkMaxLine || next.length > wordMarkMaxLine) return null;
  const a = tokens(old), b = tokens(next);
  // At least a third shared: more edits than this and the pair is a rewrite.
  const fewest = Math.ceil(Math.max(a.length, b.length) / 3);
  const script = editScript(a.map((t) => t.text), b.map((t) => t.text), a.length + b.length - 2 * fewest);
  if (!script) return null;
  return {
    old: merged(script.removed.map((i) => [a[i]!.from, a[i]!.to])),
    next: merged(script.inserted.map((i) => [b[i]!.from, b[i]!.to])),
  };
}

/** Pairs the removed and added lines of each change block, first with first, and marks the words that differ (LineDiff.markWords). */
export function markWords(lines: readonly DiffLine[]): MarkedLine[] {
  const rows: MarkedLine[] = lines.map((line) => ({ ...line }));
  let index = 0;
  while (index < rows.length) {
    if (rows[index]!.kind === "context") { index++; continue; }
    let end = index;
    while (end < rows.length && rows[end]!.kind !== "context") end++;
    const removed: number[] = [], added: number[] = [];
    for (let i = index; i < end; i++) (rows[i]!.kind === "removed" ? removed : added).push(i);
    const pairs = Math.min(removed.length, added.length);
    if (pairs <= wordMarkMaxPairs) {
      for (let k = 0; k < pairs; k++) {
        const marks = wordMarks(rows[removed[k]!]!.text, rows[added[k]!]!.text);
        if (marks) {
          rows[removed[k]!]!.changed = marks.old;
          rows[added[k]!]!.changed = marks.next;
        }
      }
    }
    index = end;
  }
  return rows;
}

/** What the diff is showing: the agent's edits, or the file as it stands (ChangeFileView). */
export type DiffShown = "edits" | "whole";

/** The agent's own edits, or one still being made. */
export function canShowEdits(file: ChangedFile | undefined): boolean {
  return (file?.editCount ?? 0) > 0 || file?.inProgress === true;
}

/** The file as it stands, where git can say what changed in it. Binary and files outside the folder cannot. */
export function canShowWhole(file: ChangedFile | undefined, git: GitView | undefined): boolean {
  return file !== undefined && git !== undefined && !("unavailable" in git)
    && file.outsideFolder === false && file.state !== "binary";
}

/** Both, so the page can offer the choice. One alone is just shown. */
export function offersDiffChoice(file: ChangedFile | undefined, git: GitView | undefined): boolean {
  return canShowEdits(file) && canShowWhole(file, git);
}

/**
 * The window's rule (ChangeFileView). Whole file sticks when it was chosen and can be shown.
 * Otherwise the agent's edits, unless there are none, as for a file a command wrote; then the file.
 */
export function shownDiff(choice: DiffShown | undefined, file: ChangedFile | undefined, git: GitView | undefined): DiffShown {
  if (choice === "whole" && canShowWhole(file, git)) return "whole";
  return canShowEdits(file) || !canShowWhole(file, git) ? "edits" : "whole";
}

/** The default, before anyone chooses: whole only when there are no edits to show. */
export function wantsWhole(file: ChangedFile | undefined, git: GitView | undefined): boolean {
  return shownDiff(undefined, file, git) === "whole";
}

/**
 * Said once above the list, and only where git's half could be read as this agent's when it may
 * not be (ChangesPane.source). An agent's own worktree needs no word.
 */
export function otherAgentsNote(git: GitView | undefined): string | null {
  if (git && "shared" in git) {
    return "Also shows what git sees changed in this folder since the agent started. That may include other agents' work, and yours.";
  }
  if (git && "sharedFromHead" in git) {
    return "This agent started before its starting point was recorded, so git's part is only what is uncommitted, and may include others' work.";
  }
  return null;
}

/**
 * Why git's half of the list is missing, in the Remote's words (RemoteChangesPane.unavailable):
 * a chat project's folder (#229) is not a repository, and says so rather than nothing.
 */
export function unavailableNote(git: GitView | undefined): string | null {
  if (!git || !("unavailable" in git)) return null;
  const why = git.unavailable;
  if ("notARepository" in why) return "This folder is not a Git repository.";
  if ("gitNotInstalled" in why) return "Git is not installed on the Mac.";
  if ("folderGone" in why) return "The agent's folder is gone.";
  return why.failed.message;
}

/** The first line of each run of changed lines: where Next and Previous go (LineDiff.changeStops). */
export function changeStops(lines: readonly { kind: string }[]): number[] {
  const stops: number[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i]!.kind !== "context" && (i === 0 || lines[i - 1]!.kind === "context")) stops.push(i);
  }
  return stops;
}

/**
 * Where Previous or Next goes, and whether that button is on (ChangeFileView.stepButtons).
 * Before any change has been visited, Previous is off and Next goes to the first.
 */
export function changeStep(stops: readonly number[], current: number | undefined, direction: "previous" | "next"): { to: number; enabled: boolean } {
  const index = current === undefined ? -1 : stops.indexOf(current);
  const at = index < 0 ? undefined : index;
  if (direction === "previous") {
    return {
      to: at === undefined ? stops[0]! : stops[Math.max(at - 1, 0)]!,
      enabled: at !== undefined && at !== 0,
    };
  }
  return {
    to: at === undefined ? stops[0]! : stops[Math.min(at + 1, stops.length - 1)]!,
    enabled: at !== stops.length - 1,
  };
}

/** Open in Files, unless the file is gone (ChangeFileView). Unknown still offers it. */
export function canOpenInFiles(file: ChangedFile | undefined): boolean {
  return file?.state !== "deleted";
}
