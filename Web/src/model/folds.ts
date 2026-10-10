// Which projects in the sidebar are unfolded (#151) and which of its smart groups (#495) are
// open, kept across visits in localStorage, as the window keeps them in defaults
// (SidebarFolds.swift). A project's fold is named by host and folder, so the same folder on two
// hosts folds apart; a smart group's by its name. Archived projects, the one fold under no
// project, is kept on its own, as the window's `showsArchivedProjects` (#343), and so is
// Activity, as its `showsActivity`.
import { signal } from "@preact/signals";
import { folderKey } from "./groups";
import { smartStartsOpen, type SmartRow } from "./sidebar";

const storageKey = "agents.sidebar.folds";
/** The smart groups that start open and have been closed (#495). */
const closedKey = "agents.sidebar.folded";
/** Whether Archived projects is open; closed until opened (#343). */
const archivedProjectsKey = "agents.sidebar.archivedProjects";
/** Whether Activity is open; open until folded. */
const activityKey = "agents.sidebar.activity";

function read(storage: Storage | undefined, key: string): Set<string> {
  try {
    const stored = JSON.parse(storage?.getItem(key) ?? "[]");
    return new Set(Array.isArray(stored) ? stored.filter((name) => typeof name === "string") : []);
  } catch {
    return new Set();
  }
}

export function foldName(host: string, folder: string): string {
  return `${host}|${folderKey(folder)}`;
}

function smartName(row: SmartRow): string {
  return `smart:${row}`;
}

export class Folds {
  readonly open;
  readonly closed;
  readonly showsArchivedProjects;
  readonly showsActivity;

  constructor(private readonly storage: Storage | undefined) {
    this.open = signal(read(storage, storageKey));
    this.closed = signal(read(storage, closedKey));
    let shows = false;
    let showsActivity = true;
    try {
      shows = storage?.getItem(archivedProjectsKey) === "true";
      showsActivity = storage?.getItem(activityKey) !== "false";
    } catch {
      // Unreadable storage leaves Archived projects closed and Activity open.
    }
    this.showsArchivedProjects = signal(shows);
    this.showsActivity = signal(showsActivity);
  }

  setShowsArchivedProjects(isOpen: boolean): void {
    if (this.showsArchivedProjects.peek() === isOpen) return;
    this.showsArchivedProjects.value = isOpen;
    this.keep(archivedProjectsKey, isOpen);
  }

  setShowsActivity(isOpen: boolean): void {
    if (this.showsActivity.peek() === isOpen) return;
    this.showsActivity.value = isOpen;
    this.keep(activityKey, isOpen);
  }

  private keep(key: string, isOpen: boolean): void {
    try {
      this.storage?.setItem(key, String(isOpen));
    } catch {
      // A private window may refuse to store; the fold still holds for this visit.
    }
  }

  isOpen(host: string, folder: string): boolean {
    return this.open.value.has(foldName(host, folder));
  }

  set(host: string, folder: string, isOpen: boolean): void {
    this.change(this.open, storageKey, foldName(host, folder), isOpen);
  }

  /** Pinned and Needs You open until folded; Working and Unread folded until opened (#495). */
  isSmartOpen(row: SmartRow): boolean {
    return smartStartsOpen(row) ? !this.closed.value.has(smartName(row)) : this.open.value.has(smartName(row));
  }

  setSmart(row: SmartRow, isOpen: boolean): void {
    if (smartStartsOpen(row)) this.change(this.closed, closedKey, smartName(row), !isOpen);
    else this.change(this.open, storageKey, smartName(row), isOpen);
  }

  private change(kept: typeof this.open, key: string, name: string, has: boolean): void {
    if (kept.peek().has(name) === has) return;
    const next = new Set(kept.peek());
    if (has) next.add(name); else next.delete(name);
    kept.value = next;
    try {
      this.storage?.setItem(key, JSON.stringify([...next].sort()));
    } catch {
      // A private window may refuse to store; the folds still hold for this visit.
    }
  }
}

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
export const folds = new Folds(globalThis.window?.localStorage);
