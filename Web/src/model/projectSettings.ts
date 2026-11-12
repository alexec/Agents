// Project Settings and Folder Settings (#3280, specs/3273-project-unit), as the window's
// App/Sources/Folders/ProjectSettingsSheet.swift and FolderSettingsSheet.swift: what every folder
// of a project shares (it is in the repository's .agents and travels with Git), and what is one
// folder's alone. The defaults are HelperLimit's and DiskThresholds' in Packages/AgentsKit.
import type { DiskThresholds, HelperLimits } from "../protocol/generated";

export const projectSettingsWords = {
  title: "Project Settings",
  menuItem: "Project Settings…",
  folderTitle: "Folder Settings",
  folderMenuItem: "Folder Settings…",
  addOnAnotherMachine: "Add on Another Machine…",
  notConnected: "not connected",
  noControlPlane: "Connect to a control plane to see the project's folders on your other machines.",
  removeFromProject: "Remove…",
  removeHelp: "Remove from Project: give this folder a project of its own",
  notCommittedNote: "What in this folder's .agents Git ignores. It stays on this machine: the project's other folders do not get it.",
  notARepository: "This folder is not in a Git repository, so nothing in its .agents is committed.",
  nothingIgnored: "Git ignores nothing in this folder's .agents.",
} as const;

/** Remove from Project…'s question (#3448): the folder gets a project of its own. */
export function removeQuestion(path: string): string {
  return `Remove ${path} from this project?\n\nIt gets a project of its own, named after it. Its sessions stay with it. `
    + "To put it back, choose this project in its Folder Settings.";
}

/** The name of that project: the folder's, or with " 2", " 3", … when a project has it, as the control plane names one it adopts. */
export function freeProjectName(name: string, projects: readonly { name: string }[]): string {
  const taken = new Set(projects.map((p) => p.name.toLowerCase()));
  const base = name.trim() || "Project";
  let free = base;
  for (let n = 2; taken.has(free.toLowerCase()); n++) free = `${base} ${n}`;
  return free;
}

/** The panes of Project Settings, in the window's order. Agent Configuration's files open in their own dialog. */
export const projectPanes = [
  { id: "general", title: "General" },
  { id: "tools", title: "Tools" },
  { id: "workAtOnce", title: "Work at Once" },
  { id: "sessions", title: "Sessions" },
  { id: "policy", title: "Policy" },
  { id: "agentConfiguration", title: "Agent Configuration" },
] as const;
export type ProjectPane = (typeof projectPanes)[number]["id"];

/** The panes of Folder Settings. */
export const folderPanes = [
  { id: "general", title: "General" },
  { id: "diskSpace", title: "Disk Space" },
  { id: "notCommitted", title: "Not Committed" },
] as const;
export type FolderPane = (typeof folderPanes)[number]["id"];

/** Under each Project Settings pane: which folder keeps them, and what to do so the other folders get them. */
export function writtenIn(path: string, machine: string): string {
  return `Written in ${path} on ${machine}. Commit .agents so that the project's other folders get it.`;
}

export const helperDefaults = { running: 3, notArchived: 5, queued: 5, agentsMayArchive: true, archiveWhenMerged: true } as const;
/** DiskThresholds' defaults: each line a percent of the disk, so one setting fits a laptop and a server. */
export const diskDefaults = { lowPercent: 10, criticalPercent: 1, lowChoices: [5, 10, 20, 30, 50], criticalChoices: [1, 2, 5, 10] } as const;

/** Under the Helpers line: HelperLimitWords.helpersNote, the window's words. */
export const helpersNote = "Set in Agents ▸ Policy, or for this project in Policy. Running counts sessions in a turn: "
  + "one that waits for an event holds no place, and runs again when it wakes. A start past running waits in the queue; "
  + "a start past queued or total is refused. They count across all the project's folders, on every machine. "
  + "A lead doesn't count; the sessions it starts do.";

/** Project Settings ▸ Work at once's Helpers line (#4377): the project's own policy layer, or the defaults, as
 * HelperLimitWords.helpersNow says it in the window. */
export function helpersNow(limits: HelperLimits | undefined): string {
  return `${limits?.running ?? helperDefaults.running} running, ${limits?.queued ?? helperDefaults.queued} queued, `
    + `${limits?.notArchived ?? helperDefaults.notArchived} in total`;
}

/** A disk line's percents, with one set by hand. */
export function diskChoices(choices: readonly number[], current: number): number[] {
  return [...new Set([...choices, current])].sort((a, b) => a - b);
}

/** The limits with one value changed, the default kept as no value, as the window keeps them. */
export function withLimit<K extends keyof HelperLimits>(kept: HelperLimits | undefined, key: K,
  value: HelperLimits[K], standard: HelperLimits[K]): HelperLimits {
  const next: HelperLimits = { ...(kept ?? {}) };
  if (value === standard || value === undefined) delete next[key];
  else next[key] = value;
  return next;
}

/** The disk lines with one changed, the default kept as no value. */
export function withDiskLine(kept: DiskThresholds | undefined, key: "lowPercent" | "criticalPercent", value: number,
  standard: number): DiskThresholds {
  const next: DiskThresholds = { ...(kept ?? {}) };
  if (value === standard) delete next[key];
  else next[key] = value;
  return next;
}

/** A folder as a person reads it: its path from the wire's file URL. */
export function folderPathOf(folder: string): string {
  try {
    return decodeURIComponent(new URL(folder).pathname).replace(/\/$/, "");
  } catch {
    return folder;
  }
}
