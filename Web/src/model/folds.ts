// Which folders in the sidebar are unfolded (#151) and which of its smart groups (#495) are
// open, and which folders' Workflows folds (#885) and Sessions folds (#2312) are open, kept across
// visits in localStorage, as the window keeps them in defaults (SidebarFolds.swift). A folder's
// fold is named by host and folder, so the same folder on two hosts folds apart; its Workflows fold
// the same, after `workflows:`, and its Sessions fold after `sessions:`; a smart group's by its
// name. Archived folders (#343), Status (#915), Usage and whether sessions go under a Sessions
// row (#2312) are the person's, kept on their Mac with the other display choices (#1033).
import { computed, signal } from "@preact/signals";
import { boolPreference, preferenceKeys, setPreferences } from "./preferences";
import { folderKey } from "./groups";
import { smartStartsOpen, type SmartRow } from "./sidebar";

const storageKey = "agents.sidebar.folds";
/** The smart groups that start open and have been closed (#495). */
const closedKey = "agents.sidebar.folded";
/** The sessions whose children are shown (#835), the last opened last. */
const sessionsKey = "agents.sidebar.openSessions";
/** How many of those are kept, as `SidebarFolds.sessionsKept`, so the list stays small. */
export const sessionsKept = 200;

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
  readonly openSessions;

  constructor(private readonly storage: Storage | undefined) {
    this.open = signal(read(storage, storageKey));
    this.closed = signal(read(storage, closedKey));
    this.openSessions = signal([...read(storage, sessionsKey)]);
  }

  // Archived folders, Status and Usage are the person's display choices, kept on their Mac
  // (#1033) as the window's showsArchivedFolders, showsActivity and showsUsage.
  readonly showsArchivedFolders = computed(() => boolPreference(preferenceKeys.showsArchivedFolders) ?? false);
  readonly showsStatus = computed(() => boolPreference(preferenceKeys.showsActivity) ?? true);
  readonly showsUsage = computed(() => boolPreference(preferenceKeys.showsUsage) ?? true);
  setShowsArchivedFolders(isOpen: boolean): void {
    if (this.showsArchivedFolders.peek() === isOpen) return;
    setPreferences({ [preferenceKeys.showsArchivedFolders]: isOpen });
  }

  setShowsStatus(isOpen: boolean): void {
    if (this.showsStatus.peek() === isOpen) return;
    setPreferences({ [preferenceKeys.showsActivity]: isOpen });
  }

  setShowsUsage(isOpen: boolean): void {
    if (this.showsUsage.peek() === isOpen) return;
    setPreferences({ [preferenceKeys.showsUsage]: isOpen });
  }

  isOpen(host: string, folder: string): boolean {
    return this.open.value.has(foldName(host, folder));
  }

  set(host: string, folder: string, isOpen: boolean): void {
    this.change(this.open, storageKey, foldName(host, folder), isOpen);
  }

  /** Whether a folder's Workflows fold is open (#885): folded until opened. */
  isWorkflowsOpen(host: string, folder: string): boolean {
    return this.open.value.has(`workflows:${foldName(host, folder)}`);
  }

  setWorkflows(host: string, folder: string, isOpen: boolean): void {
    this.change(this.open, storageKey, `workflows:${foldName(host, folder)}`, isOpen);
  }

  /** Whether a folder's Sessions fold is open (#2312): open until folded. */
  isSessionsOpen(host: string, folder: string): boolean {
    return !this.closed.value.has(`sessions:${foldName(host, folder)}`);
  }

  setSessions(host: string, folder: string, isOpen: boolean): void {
    this.change(this.closed, closedKey, `sessions:${foldName(host, folder)}`, !isOpen);
  }

  /** Whether a project's Recently archived sessions fold is open: open until folded. */
  isRecentArchivedSessionsOpen(host: string, folder: string): boolean {
    return !this.closed.value.has(`recentArchivedSessions:${foldName(host, folder)}`);
  }

  setRecentArchivedSessions(host: string, folder: string, isOpen: boolean): void {
    this.change(this.closed, closedKey, `recentArchivedSessions:${foldName(host, folder)}`, !isOpen);
  }

  /** Whether a session's children are shown under it (#835): folded until opened. */
  isSessionOpen(id: string): boolean {
    return this.openSessions.value.includes(id);
  }

  setSession(id: string, isOpen: boolean): void {
    const now = this.openSessions.peek();
    if (now.includes(id) === isOpen) return;
    const next = isOpen ? [...now, id].slice(-sessionsKept) : now.filter((kept) => kept !== id);
    this.openSessions.value = next;
    try {
      this.storage?.setItem(sessionsKey, JSON.stringify(next));
    } catch {
      // A private window may refuse to store; the fold still holds for this visit.
    }
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
