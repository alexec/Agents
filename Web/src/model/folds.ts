// Which projects in the sidebar are unfolded, which of their Archived folds are open (#151), and
// which of their session groups and Workflows are folded (#181), kept across visits in
// localStorage, as the window keeps them in defaults (SidebarFolds.swift). A fold is named by
// host and folder, so the same folder on two hosts folds apart.
import { signal } from "@preact/signals";
import type { AgentGroup } from "../protocol/generated";
import { folderKey } from "./groups";

export type Fold = "project" | "archivedSessions" | "archivedWorkflows" | "workflows" | `group.${AgentGroup}`;

const storageKey = "agents.sidebar.folds";
/** The folds that start open and have been closed: the groups and Workflows (#181). */
const closedKey = "agents.sidebar.folded";

/** A project and the Archived folds start folded; the groups and Workflows start open. */
export function startsOpen(fold: Fold): boolean {
  return fold === "workflows" || fold.startsWith("group.");
}

function read(storage: Storage | undefined, key: string): Set<string> {
  try {
    const stored = JSON.parse(storage?.getItem(key) ?? "[]");
    return new Set(Array.isArray(stored) ? stored.filter((name) => typeof name === "string") : []);
  } catch {
    return new Set();
  }
}

export function foldName(host: string, folder: string, fold: Fold = "project"): string {
  const project = `${host}|${folderKey(folder)}`;
  return fold === "project" ? project : `${fold}:${project}`;
}

export class Folds {
  readonly open;
  readonly closed;

  constructor(private readonly storage: Storage | undefined) {
    this.open = signal(read(storage, storageKey));
    this.closed = signal(read(storage, closedKey));
  }

  isOpen(host: string, folder: string, fold: Fold = "project"): boolean {
    const name = foldName(host, folder, fold);
    return startsOpen(fold) ? !this.closed.value.has(name) : this.open.value.has(name);
  }

  set(host: string, folder: string, isOpen: boolean, fold: Fold = "project"): void {
    const name = foldName(host, folder, fold);
    const kept = startsOpen(fold) ? this.closed : this.open;
    const has = startsOpen(fold) ? !isOpen : isOpen;
    if (kept.peek().has(name) === has) return;
    const next = new Set(kept.peek());
    if (has) next.add(name); else next.delete(name);
    kept.value = next;
    try {
      this.storage?.setItem(startsOpen(fold) ? closedKey : storageKey, JSON.stringify([...next].sort()));
    } catch {
      // A private window may refuse to store; the folds still hold for this visit.
    }
  }
}

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
export const folds = new Folds(globalThis.window?.localStorage);
