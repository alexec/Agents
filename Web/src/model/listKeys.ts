// The session list's single keys (#4796, spec `specs/4777-fast/spec.md`, pattern 4), as the window's ListKey
// (Packages/AgentsKit/Sources/AgentsKitCore/Model/ListKey.swift): j and k to the next and the previous session,
// e to archive it and open the next, l to put its request in Later, r to rename it. With no modifier, and only
// when no field has the keys. Work's own j and k stay: the list's keys are on the Sessions page alone.
import type { Later } from "./later";

export type ListKey = "next" | "previous" | "archive" | "later" | "rename";

const byLetter: Record<string, ListKey> = { j: "next", k: "previous", e: "archive", l: "later", r: "rename" };

/** As a menu shows it: `E`. */
export const listKeyGlyph: Record<ListKey, string> = { next: "J", previous: "K", archive: "E", later: "L", rename: "R" };

/** The time l puts a request in Later for: the first of Later's times. Later again, from the row's menu, moves it. */
export const laterTime: Later = "hour";

/** The key for a press, or undefined: any modifier, a field, or a dialog over the page keeps the letter. */
export function listKeyOf(e: { key: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean; isComposing?: boolean },
                          inField: boolean): ListKey | undefined {
  if (inField || e.isComposing || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return undefined;
  return Object.hasOwn(byLetter, e.key) ? byLetter[e.key] : undefined;
}

/** Where j or k goes from `current`, in the list's order. It stops at the ends; with nothing open, j goes to the first and k to the last. */
export function stepFrom<T>(current: T | undefined, list: readonly T[], forward: boolean): T | undefined {
  const at = current === undefined ? -1 : list.indexOf(current);
  if (at < 0) return forward ? list[0] : list[list.length - 1];
  return list[at + (forward ? 1 : -1)];
}

/** What to open after e archives `archived`: the next one, or the one before it at the end; undefined when it was alone. */
export function afterArchiving<T>(archived: T, list: readonly T[]): T | undefined {
  const at = list.indexOf(archived);
  if (at < 0) return undefined;
  return at + 1 < list.length ? list[at + 1] : list[at - 1];
}
