// Sessions under the session that started them (#835), as the window's and the Remote's
// `SidebarTree` (AgentsKitCore/Sidebar) works it out. Each session under the nearest of its
// starters the list holds, at every depth, one more indent a level up to `maxIndent` (#3553).
// Folded by default, the fold kept per row. A folded parent's mark is the most urgent of its own
// and its live descendants'. A tree in each list: a session is still listed once (#587), under its
// parent only when the same list holds the parent, otherwise as a row of its own with the
// started-by mark.
import type { Agent } from "../protocol/generated";
import { asksToArchive, groupOf, isOpenBlock, showsUnread } from "./groups";

/** SidebarTree.maxIndent: the deepest indent drawn, so the sidebar keeps its width. */
export const maxIndent = 3;

/** One row as the list draws it. */
export interface TreeRow {
  agent: Agent;
  /** How many parents it sits under in the list: 0 at the top. */
  depth: number;
  /** Under another row of the list. */
  isChild: boolean;
  /** How many indents in it is drawn. */
  indent: number;
  /** How many of the list's rows it started itself: the rows its fold shows. */
  children: number;
  /** For a parent, whether its children are shown. */
  isUnfolded: boolean;
}

/**
 * `list`, in its order, each session put under the nearest of its starters the list also holds,
 * oldest started first: the rows at the top, and each parent's own children. `starter` says who
 * started a session the list does not hold, so a chain is followed through one listed elsewhere.
 */
export function nest(list: readonly Agent[], starter: (id: string) => string | undefined)
  : { tops: Agent[]; children: Map<string, Agent[]> } {
  const listed = new Map<string, Agent>(list.map((a) => [a.id, a]));
  const parentOf = new Map<string, string>();
  for (const agent of list) {
    let parent: string | undefined;
    const seen = new Set<string>([agent.id]);
    let next: string | undefined = agent.startedByAgent;
    while (next !== undefined) {
      // A chain that comes back on itself is no chain: the session stands alone.
      if (seen.has(next)) { parent = undefined; break; }
      seen.add(next);
      if (parent === undefined && listed.has(next)) parent = next;
      next = listed.get(next)?.startedByAgent ?? starter(next);
    }
    if (parent !== undefined) parentOf.set(agent.id, parent);
  }
  const children = new Map<string, Agent[]>();
  for (const agent of list) {
    const parent = parentOf.get(agent.id);
    if (parent !== undefined) children.set(parent, [...(children.get(parent) ?? []), agent]);
  }
  for (const own of children.values()) own.sort((a, b) => a.createdAt - b.createdAt);
  return { tops: list.filter((a) => !parentOf.has(a.id)), children };
}

/** The rows to draw: each parent, then, while it is unfolded, each of its children with that child's own rows under it. */
export function treeRows(list: readonly Agent[], starter: (id: string) => string | undefined,
  isOpen: (id: string) => boolean): TreeRow[] {
  const { tops, children } = nest(list, starter);
  const rows = (agent: Agent, depth: number): TreeRow[] => {
    const own = children.get(agent.id) ?? [];
    const open = own.length > 0 && isOpen(agent.id);
    const row: TreeRow = { agent, depth, isChild: depth > 0, indent: Math.min(depth, maxIndent),
      children: own.length, isUnfolded: open };
    return open ? [row, ...own.flatMap((child) => rows(child, depth + 1))] : [row];
  };
  return tops.flatMap((agent) => rows(agent, 0));
}

/** AgentsModel.liveDescendants: the sessions it started, and theirs, at every level, not archived; oldest first. */
export function liveDescendants(all: readonly Agent[], id: string): Agent[] {
  const started = new Map<string, Agent[]>();
  for (const agent of all) {
    if (agent.startedByAgent !== undefined) started.set(agent.startedByAgent, [...(started.get(agent.startedByAgent) ?? []), agent]);
  }
  const found: Agent[] = [];
  const seen = new Set<string>([id]);
  const next = [...(started.get(id) ?? [])];
  for (let child = next.pop(); child; child = next.pop()) {
    if (seen.has(child.id)) continue;
    seen.add(child.id);
    if (child.state !== "archived") found.push(child);
    next.push(...(started.get(child.id) ?? []));
  }
  return found.sort((a, b) => a.createdAt - b.createdAt);
}

/** SidebarTree.urgency: how urgent a session's mark is, the most urgent lowest. */
export function urgency(agent: Agent): number {
  const group = groupOf(agent);
  if (group === "needsAttention" || group === "blocked") return 0;
  if (asksToArchive(agent)) return 1;
  switch (group) {
    case "running": return 2;
    case "waiting": return 3;
    case "finished": return showsUnread(agent) ? 4 : 6;
    case "stopped": return 5;
    default: return 7;
  }
}

/** SidebarTree.markAgent: the session whose mark a folded parent shows, the parent on a tie. */
export function markAgentOf(parent: Agent, descendants: readonly Agent[]): Agent {
  let shown = parent;
  for (const child of descendants) if (urgency(child) < urgency(shown)) shown = child;
  return shown;
}

/** AgentsModel.canStop, as the menu's Stop has it: it holds a runtime or an open block, or is queued. */
export function canStop(agent: Agent): boolean {
  return agent.state === "starting" || agent.state === "running" || agent.state === "waitingOnUser"
    || agent.state === "queued" || (agent.state === "finished" && isOpenBlock(agent.report));
}
