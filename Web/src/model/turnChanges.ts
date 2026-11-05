// The words of the Changed files card at the end of a turn (#3437), as TurnChangesTests checks them in Swift
// (Packages/AgentsKit/.../TurnChangesWords.swift).
import type { ChangeState, TurnChanges, TurnUndo } from "../protocol/generated";
import { CallFailed } from "../wire/link";

export const undoTitle = "Undo These Changes";
export const undoHelp = "Put these files back as they were before this turn";
export const undoing = "Undoing…";
export const confirmTitle = "Undo these changes?";
export const onlyReported = "Another agent worked in this folder at the same time, so this lists only the files this agent edited.";

/** How many files the turn changed, the ones not listed counted too. */
export function changedCount(changes: TurnChanges): number {
  return changes.files.length + (changes.more ?? 0);
}

/** "Changed 3 files". */
export function changedTitle(changes: TurnChanges): string {
  const n = changedCount(changes);
  return n === 1 ? "Changed 1 file" : `Changed ${n} files`;
}

export function moreWords(n: number): string {
  return `and ${n} more`;
}

export function stateMark(state: ChangeState): string {
  return state === "added" || state === "untracked" ? "+" : state === "deleted" ? "−" : "✎";
}

export function stateWord(state: ChangeState): string {
  return state === "added" || state === "untracked" ? "Added" : state === "deleted" ? "Deleted" : "Changed";
}

function names(paths: string[]): string {
  const base = paths.map((p) => p.split("/").pop() ?? p);
  return new Intl.ListFormat("en", { type: "conjunction" }).format(base);
}

export function cannotUndoWords(paths: string[]): string {
  return `Undo cannot put back ${names(paths)}: ${paths.length === 1 ? "it is" : "they are"} outside the folder or ignored by git.`;
}

/** What the question says: which files changed after the turn. */
export function confirmMessage(paths: string[]): string {
  return `${names(paths)} changed again after this turn. Undo puts ${paths.length === 1 ? "it" : "them"} back as before the turn, and the later changes go too.`;
}

/** The card's line once undone. */
export function undoneWords(undo: TurnUndo): string {
  const n = undo.putBack.length;
  return n === 1 ? "Undone: 1 file is back as it was before this turn." : `Undone: ${n} files are back as they were before this turn.`;
}

export function undoRefusal(error: unknown): string {
  if (error instanceof CallFailed) return error.code === -32601 ? "This Mac’s Agents is too old to undo. Update it." : error.message;
  return "The Mac can’t be reached. Try again when it is.";
}
