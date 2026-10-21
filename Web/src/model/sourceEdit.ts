// A file that changed on disk while something typed waited to be saved (#1858): SourceEditorWords
// (Shared/UI/Page/SourceEditor.swift), said the same here. Nothing is saved over it: the editor asks,
// with Compare, Keep Mine and Take Theirs, and Undo after Take Theirs gives the typing back.

export const sourceWords = {
  changed: "This file changed on disk while you were typing. Nothing was saved over it.",
  compare: "Compare",
  hideCompare: "Hide Comparison",
  keepMine: "Keep Mine",
  takeTheirs: "Take Theirs",
  tookTheirs: "You took the version on disk.",
  undo: "Undo",
};

/** ArtifactWriteRequest.base: a text's SHA-256 in lower-case hex, as the host works it out. */
export async function textDigest(text: string): Promise<string> {
  const sum = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return Array.from(sum, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** What a save that checks the file first answers. */
export type SaveOutcome = "saved" | "changedOnDisk" | "failed";

/**
 * Where the editor stands when the file on disk is read again (the window's onChange(of: text)):
 * taken in place while nothing typed waits, asked about while something does.
 */
export function onDiskChange(disk: string, draft: string, saved: string):
  { draft: string; saved: string; theirs: string | null } | { theirs: string } | null {
  if (disk === saved) return null;
  if (draft === saved) return { draft: disk, saved: disk, theirs: null };
  if (draft === disk) return { draft, saved: disk, theirs: null };
  return { theirs: disk };
}
