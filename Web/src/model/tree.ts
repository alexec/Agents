// Sessions under the session that started them (#835), as the window's and the Remote's
// `SidebarTree` (AgentsKitCore/Sidebar) works it out. One indent whatever the depth: a lane's
// helpers sit under the lead with the lane, oldest first. Folded by default, the fold kept per
// row. A folded parent's mark is the most urgent of its own and its live descendants'. A tree in
// each list: a session is still listed once (#587), under its parent only when the same list holds
// the parent, otherwise as a row of its own with the started-by mark.
import type { Agent } from "../protocol/generated";
import { asksToArchive, groupOf, isOpenBlock, showsUnread } from "./groups";

/** One row as the list draws it. */
export interface TreeRow {
  agent: Agent;
  /** Under the session at the top of its chain: drawn one indent in. */
  isChild: boolean;
  /** For a row at the top, how many of the list's rows are under it; none for a child. */
  children: number;
  /** For a parent, whether its children are shown. */
  isUnfolded: boolean;
}

/**
 * `list`, in its order, each session put under the highest of its starters the list also holds,
 * oldest started first. `starter` says who started a session the list does not hold, so a chain is
 * followed through one listed elsewhere.
 */
export function nest(list: readonly Agent[], starter: (id: string) => string | undefined)
  : { agent: Agent; children: Agent[] }[] {
  const listed = new Map<string, Agent>(list.map((a) => [a.id, a]));
  const topOf = new Map<string, string>();
  for (const agent of list) {
    let top: string = agent.id;
    const seen = new Set<string>([agent.id]);
    let next: string | undefined = agent.startedByAgent;
    while (next !== undefined) {
      // A chain that comes back on itself is no chain: the session stands alone.
      if (seen.has(next)) { top = agent.id; break; }
      seen.add(next);
      if (listed.has(next)) top = next;
      next = listed.get(next)?.startedByAgent ?? starter(next);
    }
    topOf.set(agent.id, top);
  }
  const children = new Map<string, Agent[]>();
  for (const agent of list) {
    const top = topOf.get(agent.id)!;
    if (top !== agent.id) children.set(top, [...(children.get(top) ?? []), agent]);
  }
  return list.filter((a) => topOf.get(a.id) === a.id).map((agent) => ({
    agent, children: (children.get(agent.id) ?? []).sort((a, b) => a.createdAt - b.createdAt),
  }));
}

/** The rows to draw: each parent, then its children while it is unfolded. */
export function treeRows(list: readonly Agent[], starter: (id: string) => string | undefined,
  isOpen: (id: string) => boolean): TreeRow[] {
  return nest(list, starter).flatMap(({ agent, children }) => {
    const open = children.length > 0 && isOpen(agent.id);
    const top: TreeRow = { agent, isChild: false, children: children.length, isUnfolded: open };
    return open ? [top, ...children.map((child) => ({ agent: child, isChild: true, children: 0, isUnfolded: false }))] : [top];
  });
}

/** Who started each of a host's sessions, by id: the `starter` for `nest`. */
export function startersOf(all: readonly Agent[]): (id: string) => string | undefined {
  const by = new Map<string, string | undefined>(all.map((a) => [a.id, a.startedByAgent]));
  return (id) => by.get(id);
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
