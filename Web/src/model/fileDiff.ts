// A file's change as numbered rows (#1472), as CodeText's LineDiff.rows(hunks:), breaks(_:) and
// sideBySide(_:in:) and Folds.of have it: what the web's FileDiff draws, on the Review page and on a
// pull request's page (#1341). Its input is hunks, not what they came from.
import type { DiffLineKind } from "../protocol/generated";
import { markWords } from "./diff";

/** One stretch of a file's change: where it starts in the old file and the new, and its lines. */
export interface Hunk { oldStart: number; newStart: number; lines: { kind: DiffLineKind; text: string }[] }

/** One line, with its number in the old file and the new where it has one, and its changed words. */
export interface FileDiffRow {
  kind: DiffLineKind;
  text: string;
  oldLine?: number;
  newLine?: number;
  changed?: [number, number][];
}

/** An unchanged run longer than this is folded (Limits.foldMinimum)… */
export const foldMinimum = 8;
/** …keeping this many lines beside each change (Limits.foldContext). */
export const foldContext = 3;

/** The rows of a file's change from its hunks: every line numbered, the changed words marked. */
export function hunkRows(hunks: readonly Hunk[]): FileDiffRow[] {
  const rows: FileDiffRow[] = [];
  for (const hunk of hunks) {
    let old = hunk.oldStart, next = hunk.newStart;
    for (const line of hunk.lines) {
      const row: FileDiffRow = { kind: line.kind, text: line.text };
      if (line.kind !== "added") row.oldLine = old++;
      if (line.kind !== "removed") row.newLine = next++;
      rows.push(row);
    }
  }
  return markWords(rows);
}

/** The rows that start after lines not shown: a hunk that does not go on from the one before. */
export function breaks(rows: readonly FileDiffRow[]): Set<number> {
  const out = new Set<number>();
  // After a break a side is not known until a row gives its number: a removed row says nothing of the new file.
  let nextOld: number | undefined = 1, nextNew: number | undefined = 1;
  rows.forEach((row, index) => {
    const jumped = (row.oldLine !== undefined && nextOld !== undefined && row.oldLine !== nextOld)
      || (row.newLine !== undefined && nextNew !== undefined && row.newLine !== nextNew);
    if (jumped) {
      out.add(index);
      nextOld = nextNew = undefined;
    }
    if (row.oldLine !== undefined) nextOld = row.oldLine + 1;
    if (row.newLine !== undefined) nextNew = row.newLine + 1;
  });
  return out;
}

/** A fold: the rows [from, to) it hides. */
export interface Fold { from: number; to: number }

/** A fold for every unchanged run longer than `foldMinimum`, leaving `foldContext` lines beside each change. */
export function folds(rows: readonly FileDiffRow[]): Fold[] {
  if (!rows.some((row) => row.kind !== "context")) return [];
  const out: Fold[] = [];
  let index = 0;
  while (index < rows.length) {
    if (rows[index]!.kind !== "context") { index++; continue; }
    let end = index;
    while (end < rows.length && rows[end]!.kind === "context") end++;
    if (end - index > foldMinimum) {
      const from = index + (index > 0 ? foldContext : 0);
      const to = end - (end < rows.length ? foldContext : 0);
      if (from < to) out.push({ from, to });
    }
    index = end;
  }
  return out;
}

/** Rows side by side: an unchanged row on both sides, and in each run of changes the removed rows beside the added ones. */
export function sideBySide(indices: readonly number[], rows: readonly FileDiffRow[]): [number | undefined, number | undefined][] {
  const out: [number | undefined, number | undefined][] = [];
  let at = 0;
  while (at < indices.length) {
    const index = indices[at]!;
    if (rows[index]!.kind === "context") { out.push([index, index]); at++; continue; }
    const removed: number[] = [], added: number[] = [];
    while (at < indices.length && rows[indices[at]!]!.kind !== "context") {
      const row = indices[at]!;
      (rows[row]!.kind === "removed" ? removed : added).push(row);
      at++;
    }
    for (let k = 0; k < Math.max(removed.length, added.length); k++) out.push([removed[k], added[k]]);
  }
  return out;
}

/** What a page draws, in order: rows (or pairs), closed folds, and breaks between hunks. */
export type DiffItem =
  | { kind: "row"; row: number }
  | { kind: "pair"; old: number | undefined; next: number | undefined }
  | { kind: "fold"; fold: Fold }
  | { kind: "gap"; before: number };

export function diffItems(rows: readonly FileDiffRow[], opened: ReadonlySet<number>, split: boolean): DiffItem[] {
  const closed = folds(rows).filter((fold) => !opened.has(fold.from));
  const gaps = breaks(rows);
  const out: DiffItem[] = [];
  let run: number[] = [];
  const flush = () => {
    if (!run.length) return;
    if (split) for (const [old, next] of sideBySide(run, rows)) out.push({ kind: "pair", old, next });
    else for (const row of run) out.push({ kind: "row", row });
    run = [];
  };
  let index = 0, f = 0;
  while (index < rows.length) {
    if (gaps.has(index)) { flush(); out.push({ kind: "gap", before: index }); }
    const fold = closed[f];
    if (fold && fold.from === index) {
      flush();
      out.push({ kind: "fold", fold });
      index = fold.to;
      f++;
    } else {
      run.push(index);
      index++;
    }
  }
  flush();
  return out;
}
