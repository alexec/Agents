// Where a session sits in the sessions column: AgentGroup (Model/AgentGroup.swift), ported by
// hand and held to Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/web/groups (research R7).
import type { Agent, AgentGroup, EndedReason, WorkOutcome, WorkReport } from "../protocol/generated";

export const groupTitles: Record<AgentGroup, string> = {
  needsAttention: "Needs you",
  blocked: "Blocked",
  waiting: "Waiting",
  running: "Working",
  finished: "Done",
  stopped: "Paused",
  archived: "Archived",
};

/**
 * The groups shown in the column, in order. Archived is folded under them; Blocked is never assigned.
 * Parked went in #584: a request to archive is a mark on the row, not a group.
 */
export const liveGroups: readonly AgentGroup[] = ["needsAttention", "waiting", "running", "finished", "stopped"];

/** Whether somebody has to do something about this outcome (WorkOutcome.needsAPerson). */
export function outcomeNeedsAPerson(outcome: WorkOutcome): boolean {
  return outcome === "needs_answer" || outcome === "partly_done" || outcome === "stuck";
}

/** A blocked report whose block has not cleared (WorkReport.isOpenBlock). */
export function isOpenBlock(report: WorkReport | undefined): boolean {
  return report?.outcome === "blocked" && report.block?.clearedAt === undefined;
}

/** An open block the app clears by itself: it names agents, or a time (WorkReport.resumesByItself). */
export function resumesByItself(report: WorkReport | undefined): boolean {
  if (!isOpenBlock(report) || !report?.block) return false;
  return report.block.waits.length > 0 || report.block.checkAgainAt !== undefined;
}

const pausedEndings: readonly (EndedReason | undefined)[] = ["cancelled", "stoppedByAgent", "allowanceSpent"];

/** Agent.asksToArchive: an agent asked the person to archive it, and it is not archived yet (#584). */
export function asksToArchive(agent: Agent): boolean {
  return agent.archiveRequest !== undefined && "requested" in agent.archiveRequest && agent.state !== "archived";
}

/** Agent.isWaiting: the app will carry it on by itself. */
export function isWaiting(agent: Agent): boolean {
  return (agent.eventWait !== undefined && agent.eventWait.ending === undefined) || resumesByItself(agent.report);
}

/** Agent.showsUnread: a finished turn nobody has opened since. A mark on the row, never a group (#70). */
export function showsUnread(agent: Agent): boolean {
  return agent.state === "finished" && agent.isUnread === true;
}

/** Agent.needsAPerson: it asked for an answer. */
export function needsAPerson(agent: Agent): boolean {
  return agent.state === "waitingOnUser"
    || (agent.state === "finished" && agent.report !== undefined && outcomeNeedsAPerson(agent.report.outcome));
}

/** Agent.endingIsUnaccountedFor: ended cleanly, was asked how it went, said nothing. */
export function endingIsUnaccountedFor(agent: Agent): boolean {
  return agent.state === "finished" && agent.endedReason === "endTurn" && agent.report === undefined
    && agent.outcomeAsked === true;
}

function settled(wantsAPerson: boolean, report: WorkReport | undefined, waitingOnEvents: boolean): AgentGroup {
  if (wantsAPerson) return "needsAttention";
  if (resumesByItself(report) || waitingOnEvents) return "waiting";
  if (isOpenBlock(report)) return "needsAttention";
  return "finished";
}

/**
 * Agent.group(wantsEyes:). `wantsEyes` is the window's own fact (a file it was asked to show);
 * the web remote is not a window, so it passes false, which is honest from anything else.
 */
export function groupOf(agent: Agent, wantsEyes = false): AgentGroup {
  const report = agent.report;
  const wantsAnswer = report !== undefined && outcomeNeedsAPerson(report.outcome);
  const outcomeAsked = agent.outcomeAsked === true;
  const waitingOnEvents = agent.eventWait !== undefined && agent.eventWait.ending === undefined;
  switch (agent.state) {
    case "starting": return "running";
    case "waitingOnUser": return "needsAttention";
    case "running":
      if (outcomeAsked) return settled(wantsEyes || wantsAnswer || report === undefined, report, waitingOnEvents);
      return wantsEyes ? "needsAttention" : "running";
    case "finished":
      return settled(wantsEyes || wantsAnswer || (outcomeAsked && report === undefined), report, waitingOnEvents);
    case "stopped":
      // The daemon never sends allowanceWait, so the Mac's "waiting for an allowance" arm is absent.
      return pausedEndings.includes(agent.endedReason) ? "stopped" : "needsAttention";
    case "archived": return "archived";
    // Starts by itself when a place frees (#362): nobody has to do anything.
    case "queued": return "waiting";
  }
}

export interface Heading {
  group: AgentGroup;
  title: string;
  agents: Agent[];
}

/** A folder without its trailing slash, so a project and its agents compare equal. */
export function folderKey(url: string): string {
  return url.replace(/\/+$/, "");
}

/** The folder an agent counts under: its worktree's project, else where it runs (Agent.projectFolder). */
export function projectFolder(agent: Agent): string {
  return folderKey(agent.worktree?.project ?? agent.cwd);
}

/** ProjectShelf.byActivity: newest activity first, then by id. */
function byActivity(a: Agent, b: Agent): number {
  return b.lastActivityAt - a.lastActivityAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

/**
 * ProjectShelf.byStart: newest started first, then by id (#182). A working agent's activity
 * changes with every line, so a live group ordered by it shuffled; when it started never changes.
 */
export function byStart(a: Agent, b: Agent): number {
  return b.createdAt - a.createdAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

/** AgentsModel.agents(in:group:): newest started first; under Archived newest activity first, as the host pages them. */
export function agentsIn(agents: readonly Agent[], folder: string, group: AgentGroup): Agent[] {
  const wanted = folderKey(folder);
  const found = agents.filter((agent) => projectFolder(agent) === wanted && groupOf(agent) === group);
  return found.sort(group === "archived" ? byActivity : byStart);
}

/** The column's headings in order, empty ones left out. */
export function headings(agents: readonly Agent[], folder: string): Heading[] {
  return liveGroups.flatMap((group) => {
    const found = agentsIn(agents, folder, group);
    return found.length ? [{ group, title: groupTitles[group], agents: found }] : [];
  });
}

/** AgentsModel.counts(in:): how many sessions of one project are in each group. */
export function counts(agents: readonly Agent[], folder: string): Partial<Record<AgentGroup, number>> {
  const wanted = folderKey(folder);
  const result: Partial<Record<AgentGroup, number>> = {};
  for (const agent of agents) {
    if (projectFolder(agent) !== wanted) continue;
    const group = groupOf(agent);
    result[group] = (result[group] ?? 0) + 1;
  }
  return result;
}

/** AgentsModel.attentionCount(in:): Needs you, Blocked, or unread: what the badge and the title count. */
export function attentionCount(agents: readonly Agent[], folder: string): number {
  const wanted = folderKey(folder);
  return agents.filter((a) => {
    if (projectFolder(a) !== wanted) return false;
    if (showsUnread(a)) return true;
    const group = groupOf(a);
    return group === "needsAttention" || group === "blocked";
  }).length;
}

/**
 * What a project row says under its name (ProjectRow.subtitle): Needs you first, with unread
 * beside it; else working and unread; else complete and stopped; else nothing.
 */
export function projectSubtitle(agents: readonly Agent[], folder: string): string | null {
  const c = counts(agents, folder);
  const unread = unreadCount(agents, folder);
  if ((c.needsAttention ?? 0) > 0) return unread > 0 ? `Needs you · ${unread} unread` : "Needs you";
  const parts: string[] = [];
  if ((c.running ?? 0) > 0) parts.push(`${c.running} working`);
  if (unread > 0) parts.push(`${unread} unread`);
  if (!parts.length) {
    if ((c.finished ?? 0) > 0) parts.push(`${c.finished} complete`);
    if ((c.stopped ?? 0) > 0) parts.push(`${c.stopped} stopped`);
  }
  return parts.length ? parts.join(" · ") : null;
}

/** AgentsModel.unreadCount(in:): finished chats nobody has looked at since. */
export function unreadCount(agents: readonly Agent[], folder: string): number {
  const wanted = folderKey(folder);
  return agents.filter((a) => projectFolder(a) === wanted && a.state === "finished" && a.isUnread === true).length;
}

/** What one project's row and fold draw from its agents, worked out once per change to them (#170). */
export interface ProjectView {
  headings: Heading[];
  archived: Agent[];
  needsYou: boolean;
  /** Needs you, Blocked and unread: what the tab's title counts. */
  attention: number;
  subtitle: string | null;
}

/** One project's view, from that project's agents alone. */
export function projectView(agents: readonly Agent[], folder: string): ProjectView {
  const shown = headings(agents, folder);
  return {
    headings: shown,
    archived: agentsIn(agents, folder, "archived"),
    needsYou: shown.some((h) => h.group === "needsAttention"),
    attention: attentionCount(agents, folder),
    subtitle: projectSubtitle(agents, folder),
  };
}
