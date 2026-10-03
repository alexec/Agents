// Which projects in the sidebar are unfolded, and which of their Archived folds are open (#151),
// kept across visits in localStorage, as the window keeps them in defaults (SidebarFolds.swift).
// A fold is named by host and folder, so the same folder on two hosts folds apart.
import { signal } from "@preact/signals";
import { folderKey } from "./groups";

export type Fold = "project" | "archivedSessions" | "archivedWorkflows";

const storageKey = "agents.sidebar.folds";

function read(storage: Storage | undefined): Set<string> {
  try {
    const stored = JSON.parse(storage?.getItem(storageKey) ?? "[]");
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

  constructor(private readonly storage: Storage | undefined) {
    this.open = signal(read(storage));
  }

  isOpen(host: string, folder: string, fold: Fold = "project"): boolean {
    return this.open.value.has(foldName(host, folder, fold));
  }

  set(host: string, folder: string, isOpen: boolean, fold: Fold = "project"): void {
    const name = foldName(host, folder, fold);
    if (this.open.peek().has(name) === isOpen) return;
    const next = new Set(this.open.peek());
    if (isOpen) next.add(name); else next.delete(name);
    this.open.value = next;
    try {
      this.storage?.setItem(storageKey, JSON.stringify([...next].sort()));
    } catch {
      // A private window may refuse to store; the folds still hold for this visit.
    }
  }
}

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
export const folds = new Folds(globalThis.window?.localStorage);
