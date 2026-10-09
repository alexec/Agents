// Which projects in the sidebar are unfolded, which of their Archived folds are open (#151), and
// which of their session groups and Workflows are folded (#181), kept across visits in
// localStorage, as the window keeps them in defaults (SidebarFolds.swift). A fold is named by
// host and folder, so the same folder on two hosts folds apart. Archived projects, the one fold
// under no project, is kept on its own, as the window's `showsArchivedProjects` (#343), and so is
// Activity, as its `showsActivity`.
import { signal } from "@preact/signals";
import type { AgentGroup } from "../protocol/generated";
import { folderKey } from "./groups";

export type Fold = "project" | "archivedSessions" | "archivedWorkflows" | "workflows" | "pinned" | `group.${AgentGroup}`;

const storageKey = "agents.sidebar.folds";
/** The folds that start open and have been closed: the groups and Workflows (#181). */
const closedKey = "agents.sidebar.folded";
/** Whether Archived projects is open; closed until opened (#343). */
const archivedProjectsKey = "agents.sidebar.archivedProjects";
/** Whether Activity is open; open until folded. */
const activityKey = "agents.sidebar.activity";

/** A project and the Archived folds start folded; the groups, Pinned (#180) and Workflows start open. */
export function startsOpen(fold: Fold): boolean {
  return fold === "workflows" || fold === "pinned" || fold.startsWith("group.");
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
