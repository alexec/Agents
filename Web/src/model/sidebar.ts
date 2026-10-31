// What the Things-style sidebar (#495, #499) gathers and in what order, as the window's and the
// Remote's `SidebarSmartRow` and `SidebarFolderFold` (AgentsKitCore/Sidebar) work it out: the
// smart groups at the top across every folder (Pinned, Needs You, Working, Unread), and each
// folder's sessions as one list, newest started first, the state the row's mark. Each session is
// listed once, in its first group (#587). Needs You holds everything waiting for the person (#773):
// sessions asking or blocked, sessions asking to be archived (#584, #649, once a group of their own),
// and each folder's approvals as rows of their own.
import type { Agent, Approval, WorkflowSummary } from "../protocol/generated";
import { asksToArchive, byStart, folderKey, groupOf, showsUnread } from "./groups";
import { queryMatches, type LabelQuery } from "./labels";
import { isSessionApproval, kindWords } from "./approvals";

export type SmartRow = "pinned" | "needsYou" | "working" | "unread";

/** In the sidebar's order: Pinned first, then by what they want. */
export const smartRows: readonly SmartRow[] = ["pinned", "needsYou", "working", "unread"];

export const smartTitles: Record<SmartRow, string> = {
  pinned: "Pinned", needsYou: "Needs You", working: "Working", unread: "Unread",
};

/** Every group, on: as each browser starts until one is turned off (#846). */
export const allSmartRows: ReadonlySet<SmartRow> = new Set(smartRows);

/** Pinned and Needs You start open, so the first thing the page says is who is waiting; the others start folded. */
export function smartStartsOpen(row: SmartRow): boolean {
  return row === "pinned" || row === "needsYou";
}

/**
 * Where a live session is listed (#587), as `SidebarSmartRow.home`: once, in the first of the smart
 * groups it belongs to (Pinned, Needs You (asking, blocked, or asking to be archived, #773), Working,
 * Unread), or, in none of them, under its folder (null). A group turned off (#846) is passed over:
 * its sessions go to the next one they fit, so one unread that asks to be archived goes to Unread
 * with Needs You off.
 */
export function home(agent: Agent, isPinned: boolean, on: ReadonlySet<SmartRow> = allSmartRows): SmartRow | null {
  const group = groupOf(agent);
  if (group === "archived") return null;
  if (isPinned && on.has("pinned")) return "pinned";
  const waits = group === "needsAttention" || group === "blocked" || (group !== "running" && asksToArchive(agent));
  if (waits && on.has("needsYou")) return "needsYou";
  if (group === "running" && on.has("working")) return "working";
  return showsUnread(agent) && on.has("unread") ? "unread" : null;
}

/** The mark a session's row carries in the sidebar (#495): what it wants, or null for its own status mark. */
export type SessionMark = "needsYou" | "working" | "tool" | "queued" | "waiting" | "paused" | "done" | "asksToArchive";

/** The tool a working session runs now (#1902, RunningToolWords.tool), or null while it thinks. */
export function runningTool(agent: Agent): string | null {
  return agent.state === "running" ? agent.runningTool ?? null : null;
}

/** RunningToolWords.label: "Running: swift test". */
export function runningToolLabel(tool: string): string {
  return `Running: ${tool}`;
}

export function sessionMark(agent: Agent): SessionMark | null {
  switch (groupOf(agent)) {
    case "needsAttention": case "blocked": return "needsYou";
    // A wrench in the spinner's place while it runs a tool (#1902); thinking keeps the spinner.
    case "running": return runningTool(agent) !== null ? "tool" : "working";
    // Waiting and paused in the accent as the rest, not the grey status mark (#630).
    // A queued helper waits for a free place, not on anything it asked for.
    case "waiting": return agent.state === "queued" ? "queued" : "waiting";
    // Asking to be archived (#584) is what the person has left to do with it, as the window's mark says.
    // Read or unread, one tick (#1323, #2363): the bold title alone says unread.
    case "finished": return asksToArchive(agent) ? "asksToArchive" : "done";
    case "stopped": return asksToArchive(agent) ? "asksToArchive" : "paused";
    default: return null;
  }
}

/** One folder's pinned sessions, held and not archived, in the order they were put in, as a search leaves them. */
export function pinnedSessions(live: readonly Agent[], pins: readonly string[], query?: LabelQuery): Agent[] {
  const pinned = pins.flatMap((id) => live.filter((a) => a.id === id && a.state !== "archived"));
  return query ? pinned.filter((a) => queryMatches(query, a)) : pinned;
}

/** One folder's pinned workflows held and not archived (#432), in their order. */
export function pinnedWorkflows(held: readonly WorkflowSummary[], pins: readonly string[]): WorkflowSummary[] {
  return pins.flatMap((id) => held.filter((w) => w.workflow.workflowID === id && !w.isArchived));
}

/**
 * A folder's live sessions as one list (#495), those a smart group lists left out, as each is
 * listed once (#587): newest started first, not by last activity, so a working session does not
 * climb past the pointer with every line (#357). `kept` is the session Unread keeps while it is
 * open, listed there and not here (#689). `on` is the smart groups turned on (#846): with Pinned
 * off, the pinned are listed here as any other.
 */
export function folderSessions(live: readonly Agent[], pins: readonly string[], query?: LabelQuery,
  kept?: string, on: ReadonlySet<SmartRow> = allSmartRows): Agent[] {
  const pinned = new Set(pins);
  return live.filter((a) => home(a, pinned.has(a.id), on) === null && a.id !== kept && (!query || queryMatches(query, a)))
    .sort(byStart);
}

/**
 * Whether Unread keeps the session opened from it (#495), as `SidebarSmartRow.keptInUnread`: not
 * once it belongs elsewhere (archived, pinned, waiting, working or asking to be archived). Only
 * while Unread is on, and pinned only counts while Pinned is on (#846).
 */
export function keepsInUnread(agent: Agent, pins: readonly string[], on: ReadonlySet<SmartRow> = allSmartRows): boolean {
  if (!on.has("unread") || agent.state === "archived" || (on.has("pinned") && pins.includes(agent.id))) return false;
  const at = home(agent, false, on);
  return at === null || at === "unread";
}

/**
 * What a smart group (not Pinned) gathers from the folders' live sessions, the pinned left out
 * as they are listed in Pinned (#587): newest started first. With a group off (#846), each goes
 * where `home` puts it, the pinned too while Pinned is off; a group off gathers nothing.
 */
export function smartAgents(row: Exclude<SmartRow, "pinned">, live: readonly Agent[], query?: LabelQuery,
  pins: readonly string[] = [], on: ReadonlySet<SmartRow> = allSmartRows): Agent[] {
  const pinned = new Set(pins);
  return live.filter((a) => home(a, pinned.has(a.id), on) === row && (!query || queryMatches(query, a))).sort(byStart);
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

/**
 * What waits for an OK across the folders named, each with its folder (#773), as
 * `SidebarSmartRow.approvals`: only Needs You lists them, after its sessions, oldest waiting first
 * (one with no time first of all). A session's archive request is its own row, not one of these. A
 * search matches the title, the kind and the grey line.
 */
export function smartApprovals<P>(folders: readonly { folder: P; approvals?: readonly Approval[] | undefined }[],
  query = ""): { folder: P; approval: Approval }[] {
  const words = query.trim().toLowerCase();
  return folders.flatMap(({ folder, approvals }) => (approvals ?? [])
    .filter((a) => !isSessionApproval(a)
      && (!words || `${a.title} ${kindWords[a.kind]} ${a.line}`.toLowerCase().includes(words)))
    .map((approval) => ({ folder, approval })))
    .sort((a, b) => sinceOf(a.approval) - sinceOf(b.approval));
}

/** When it began waiting, the unknown first: a stable sort keeps those in their folders' order. */
function sinceOf(approval: Approval): number {
  return approval.since ?? Number.MIN_SAFE_INTEGER;
}

export interface FolderKey { host: string; folder: string }

function sameFolder(a: FolderKey, b: FolderKey): boolean {
  return a.host === b.host && folderKey(a.folder) === folderKey(b.folder);
}

/**
 * The folder New Session at the top of the sidebar starts in (#495): the last one a new session
 * was opened in, while it is still a live folder; otherwise the one open; otherwise the first.
 */
export function newSessionFolder(live: readonly FolderKey[], remembered: FolderKey | undefined,
  open: FolderKey | undefined): FolderKey | undefined {
  if (remembered && live.some((p) => sameFolder(p, remembered))) return live.find((p) => sameFolder(p, remembered));
  if (open && live.some((p) => sameFolder(p, open))) return live.find((p) => sameFolder(p, open));
  return live[0];
}

const rememberedKey = "agents.sidebar.newSessionFolder";

/** The folder New Session last opened in, kept in localStorage as the window keeps it in defaults. */
export function rememberedFolder(storage: Storage | undefined): FolderKey | undefined {
  try {
    const stored = JSON.parse(storage?.getItem(rememberedKey) ?? "null");
    return stored && typeof stored.host === "string" && typeof stored.folder === "string"
      ? { host: stored.host, folder: stored.folder } : undefined;
  } catch {
    return undefined;
  }
}

export function rememberFolder(storage: Storage | undefined, folder: FolderKey): void {
  try {
    const was = rememberedFolder(storage);
    if (was && sameFolder(was, folder)) return;
    storage?.setItem(rememberedKey, JSON.stringify({ host: folder.host, folder: folder.folder }));
  } catch {
    // A private window may refuse to store; the first folder stands in.
  }
}
