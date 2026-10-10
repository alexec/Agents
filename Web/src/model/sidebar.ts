// What the Things-style sidebar (#495, #499) gathers and in what order, as the window's and the
// Remote's `SidebarSmartRow` and `SidebarProjectFold` (AgentsKitCore/Sidebar) work it out: the
// smart groups at the top across every project (Pinned, Needs You, Working, Unread, To Archive), and
// each project's sessions as one list, newest started first, the state the row's mark. Each session
// is listed once, in its first group (#587).
import type { Agent, WorkflowSummary } from "../protocol/generated";
import { asksToArchive, byStart, folderKey, groupOf, showsUnread } from "./groups";
import { queryMatches, type LabelQuery } from "./labels";

export type SmartRow = "pinned" | "needsYou" | "working" | "unread" | "toArchive";

/** In the sidebar's order: Pinned first, then by what they want, then what asks to be archived (#584). */
export const smartRows: readonly SmartRow[] = ["pinned", "needsYou", "working", "unread", "toArchive"];

export const smartTitles: Record<SmartRow, string> = {
  pinned: "Pinned", needsYou: "Needs You", working: "Working", unread: "Unread", toArchive: "To Archive",
};

/** Pinned and Needs You start open, so the first thing the page says is who is waiting; the others start folded. */
export function smartStartsOpen(row: SmartRow): boolean {
  return row === "pinned" || row === "needsYou";
}

/**
 * Where a live session is listed (#587), as `SidebarSmartRow.home`: once, in the first of the smart
 * groups it belongs to (Pinned, Needs You, Working, To Archive (#584), Unread), or, in none of them,
 * under its project (null). To Archive comes before Unread though it is drawn after it, so Archive
 * All reaches every session that asks.
 */
export function home(agent: Agent, isPinned: boolean): SmartRow | null {
  if (isPinned) return "pinned";
  switch (groupOf(agent)) {
    case "needsAttention": case "blocked": return "needsYou";
    case "running": return "working";
    case "archived": return null;
    default: return asksToArchive(agent) ? "toArchive" : showsUnread(agent) ? "unread" : null;
  }
}

/** Whether a live session, not pinned, is listed under Needs You, Working, Unread or To Archive. */
export function inSmartRow(row: Exclude<SmartRow, "pinned">, agent: Agent): boolean {
  return home(agent, false) === row;
}

/** The mark a session's row carries in the sidebar (#495): what it wants, or null for its own status mark. */
export type SessionMark = "needsYou" | "working" | "unread" | "read" | "asksToArchive";

export function sessionMark(agent: Agent): SessionMark | null {
  switch (groupOf(agent)) {
    case "needsAttention": case "blocked": return "needsYou";
    case "running": return "working";
    // Asking to be archived (#584) is what the person has left to do with it, as the window's mark says.
    case "finished": return asksToArchive(agent) ? "asksToArchive" : showsUnread(agent) ? "unread" : "read";
    case "stopped": return asksToArchive(agent) ? "asksToArchive" : null;
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
 * A project's live sessions as one list (#495), those a smart group lists left out, as each is
 * listed once (#587): newest started first, not by last activity, so a working session does not
 * climb past the pointer with every line (#357).
 */
export function projectSessions(live: readonly Agent[], pins: readonly string[], query?: LabelQuery): Agent[] {
  const pinned = new Set(pins);
  return live.filter((a) => home(a, pinned.has(a.id)) === null && (!query || queryMatches(query, a))).sort(byStart);
}

/** How many sessions a project's own group lists, folded or not (#587), as `SidebarProjectFold.ownCount`. */
export function ownCount(live: readonly Agent[], pins: readonly string[]): number {
  return projectSessions(live, pins).length;
}

/**
 * What a smart group (not Pinned) gathers from the projects' live sessions, the pinned left out
 * as they are listed in Pinned (#587): newest started first.
 */
export function smartAgents(row: Exclude<SmartRow, "pinned">, live: readonly Agent[], query?: LabelQuery,
  pins: readonly string[] = []): Agent[] {
  const pinned = new Set(pins);
  return live.filter((a) => !pinned.has(a.id) && inSmartRow(row, a) && (!query || queryMatches(query, a))).sort(byStart);
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
