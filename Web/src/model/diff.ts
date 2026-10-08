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
