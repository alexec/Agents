// What the Things-style sidebar (#495, #499) gathers and in what order, as the window's and the
// Remote's `SidebarSmartRow` and `SidebarProjectFold` (AgentsKitCore/Sidebar) work it out: the
// smart groups at the top across every project (Pinned, Needs You, Working, Unread), and each
// project's sessions as one list, newest started first, the state the row's mark.
import type { Agent, WorkflowSummary } from "../protocol/generated";
import { byStart, folderKey, groupOf, showsUnread } from "./groups";
import { queryMatches, type LabelQuery } from "./labels";

export type SmartRow = "pinned" | "needsYou" | "working" | "unread";

/** In the sidebar's order: Pinned first, then by what they want. */
export const smartRows: readonly SmartRow[] = ["pinned", "needsYou", "working", "unread"];

export const smartTitles: Record<SmartRow, string> = {
  pinned: "Pinned", needsYou: "Needs You", working: "Working", unread: "Unread",
};

/** Pinned and Needs You start open, so the first thing the page says is who is waiting; the others start folded. */
export function smartStartsOpen(row: SmartRow): boolean {
  return row === "pinned" || row === "needsYou";
}

/** Whether a live session belongs under Needs You, Working or Unread (never Pinned: that is by pin). */
export function inSmartRow(row: Exclude<SmartRow, "pinned">, agent: Agent): boolean {
  const group = groupOf(agent);
  switch (row) {
    case "needsYou": return group === "needsAttention" || group === "blocked";
    case "working": return group === "running";
    case "unread": return group !== "archived" && showsUnread(agent);
  }
}

/** The mark a session's row carries in the sidebar (#495): what it wants, or null for its own status mark. */
export type SessionMark = "needsYou" | "working" | "unread" | "read";

export function sessionMark(agent: Agent): SessionMark | null {
  switch (groupOf(agent)) {
    case "needsAttention": case "blocked": return "needsYou";
    case "running": return "working";
    case "finished": return showsUnread(agent) ? "unread" : "read";
    default: return null;
  }
}

/** One project's pinned sessions, held and not archived, in the order they were put in, as a search leaves them. */
export function pinnedSessions(live: readonly Agent[], pins: readonly string[], query?: LabelQuery): Agent[] {
  const pinned = pins.flatMap((id) => live.filter((a) => a.id === id && a.state !== "archived"));
  return query ? pinned.filter((a) => queryMatches(query, a)) : pinned;
}

/** One project's pinned workflows held and not archived (#432), in their order. */
export function pinnedWorkflows(held: readonly WorkflowSummary[], pins: readonly string[]): WorkflowSummary[] {
  return pins.flatMap((id) => held.filter((w) => w.workflow.workflowID === id && !w.isArchived));
}

/**
 * A project's live sessions as one list (#495), the pinned left out: newest started first, not
 * by last activity, so a working session does not climb past the pointer with every line (#357).
 */
export function projectSessions(live: readonly Agent[], pins: readonly string[], query?: LabelQuery): Agent[] {
  const pinned = new Set(pins);
  return live.filter((a) => !pinned.has(a.id) && (!query || queryMatches(query, a))).sort(byStart);
}

/** What a smart group (not Pinned) gathers from the projects' live sessions: newest started first. */
export function smartAgents(row: Exclude<SmartRow, "pinned">, live: readonly Agent[], query?: LabelQuery): Agent[] {
  return live.filter((a) => inSmartRow(row, a) && (!query || queryMatches(query, a))).sort(byStart);
}

/**
 * Unread keeps the session opened from it (#495), read now, in its place until another is
 * opened, as a read message stays in Mail's Unread while it is selected; its count has dropped.
 */
export function withKept(agents: readonly Agent[], kept: Agent | undefined): Agent[] {
  if (!kept || agents.some((a) => a.id === kept.id)) return [...agents];
  const at = agents.findIndex((a) => byStart(a, kept) > 0);
  const shown = [...agents];
  shown.splice(at < 0 ? shown.length : at, 0, kept);
  return shown;
}

export interface ProjectKey { host: string; folder: string }

function sameProject(a: ProjectKey, b: ProjectKey): boolean {
  return a.host === b.host && folderKey(a.folder) === folderKey(b.folder);
}

/**
 * The project New Session at the top of the sidebar starts in (#495): the last one a new session
 * was opened in, while it is still a live project; otherwise the one open; otherwise the first.
 */
export function newSessionProject(live: readonly ProjectKey[], remembered: ProjectKey | undefined,
  open: ProjectKey | undefined): ProjectKey | undefined {
  if (remembered && live.some((p) => sameProject(p, remembered))) return live.find((p) => sameProject(p, remembered));
  if (open && live.some((p) => sameProject(p, open))) return live.find((p) => sameProject(p, open));
  return live[0];
}

const rememberedKey = "agents.sidebar.newSessionProject";

/** The project New Session last opened in, kept in localStorage as the window keeps it in defaults. */
export function rememberedProject(storage: Storage | undefined): ProjectKey | undefined {
  try {
    const stored = JSON.parse(storage?.getItem(rememberedKey) ?? "null");
    return stored && typeof stored.host === "string" && typeof stored.folder === "string"
      ? { host: stored.host, folder: stored.folder } : undefined;
  } catch {
    return undefined;
  }
}

export function rememberProject(storage: Storage | undefined, project: ProjectKey): void {
  try {
    const was = rememberedProject(storage);
    if (was && sameProject(was, project)) return;
    storage?.setItem(rememberedKey, JSON.stringify({ host: project.host, folder: project.folder }));
  } catch {
    // A private window may refuse to store; the first project stands in.
  }
}
