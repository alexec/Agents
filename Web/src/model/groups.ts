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

/** Whether somebody has to do something about this outcome (WorkOutcome.needsAPerson): only a question (#1916). */
export function outcomeNeedsAPerson(outcome: WorkOutcome): boolean {
  return outcome === "needs_answer";
}

/** A waiting report whose block has not cleared (WorkReport.isOpenBlock). */
export function isOpenBlock(report: WorkReport | undefined): boolean {
  return report?.outcome === "waiting" && report.block?.clearedAt === undefined;
}

/** An open block the app clears by itself: it names agents, or a time (WorkReport.resumesByItself). */
export function resumesByItself(report: WorkReport | undefined): boolean {
  if (!isOpenBlock(report) || !report?.block) return false;
  return report.block.waits.length > 0 || report.block.checkAgainAt !== undefined;
}

const pausedEndings: readonly (EndedReason | undefined)[] = ["cancelled", "stoppedByAgent", "stoppedByAdmin"];

/** Agent.asksToArchive: an agent asked the person to archive it, and it is not archived yet (#584). */
export function asksToArchive(agent: Agent): boolean {
  return agent.archiveRequest !== undefined && "requested" in agent.archiveRequest && agent.state !== "archived";
}

/** Agent.isWaiting: the app will carry it on by itself. */
export function isWaiting(agent: Agent): boolean {
  return (agent.eventWait !== undefined && agent.eventWait.ending === undefined) || resumesByItself(agent.report);
}

/**
 * Whether only the connected person can carry this open wait on, given its filter
 * (#3051): review.requested or issue.assigned today, a PR comment by them once #2838 lands.
 */
export function waitingForPerson(agent: Agent): boolean {
  return agent.eventWait !== undefined && agent.eventWait.ending === undefined && agent.eventWait.forPerson === true;
}

/** Agent.showsUnread: a finished turn nobody has opened since. A mark on the row, never a group (#70). */
export function showsUnread(agent: Agent): boolean {
  return agent.state === "finished" && agent.isUnread === true;
}

/** Agent.drawsUnread: the row's bold title (#1323), only in Done; the counts go by showsUnread. */
export function drawsUnread(agent: Agent): boolean {
  return showsUnread(agent) && groupOf(agent) === "finished";
}

/** Agent.needsAPerson: it asked for an answer, or waits on something only they can settle (#3051). */
export function needsAPerson(agent: Agent): boolean {
  return agent.state === "waitingOnUser"
    || (agent.state === "finished"
      && ((agent.report !== undefined && outcomeNeedsAPerson(agent.report.outcome)) || waitingForPerson(agent)));
}

/** Agent.endingIsUnaccountedFor: ended cleanly, was asked how it went, said nothing. */
export function endingIsUnaccountedFor(agent: Agent): boolean {
  return agent.state === "finished" && agent.endedReason === "endTurn" && agent.report === undefined
    && agent.outcomeAsked === true;
}

function settled(wantsAPerson: boolean, report: WorkReport | undefined, waitingOnEvents: boolean): AgentGroup {
  if (wantsAPerson) return "needsAttention";
  if (resumesByItself(report) || waitingOnEvents) return "waiting";
  // A block the app will not clear (an old record's) is done, not Needs you (#1916).
  return "finished";
}

/** Agent.group(). A shown file is never a group (#1057). */
export function groupOf(agent: Agent): AgentGroup {
  const report = agent.report;
  // A wait only the connected person can settle (#3051) needs them too, as a question does.
  const wantsAnswer = (report !== undefined && outcomeNeedsAPerson(report.outcome)) || waitingForPerson(agent);
  const outcomeAsked = agent.outcomeAsked === true;
  const waitingOnEvents = agent.eventWait !== undefined && agent.eventWait.ending === undefined;
  switch (agent.state) {
    case "starting": return "running";
    case "waitingOnUser": return "needsAttention";
    case "running":
      if (outcomeAsked) return settled(wantsAnswer || report === undefined, report, waitingOnEvents);
      return "running";
    case "finished":
      return settled(wantsAnswer || (outcomeAsked && report === undefined), report, waitingOnEvents);
    case "stopped":
      // Waiting for its allowance to carry on (#1859), as the Mac's "waiting for an allowance" arm.
      if (agent.continueWhenBack) return "waiting";
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

/** A folder without its trailing slash, so a folder and its agents compare equal. */
export function folderKey(url: string): string {
  return url.replace(/\/+$/, "");
}

/** The folder an agent counts under: its worktree's folder, else where it runs (Agent.folderPath); an
 *  empty folder, left by #2617 (#2650), counts as none. */
export function folderPath(agent: Agent): string {
  return folderKey(agent.worktree?.folder || agent.cwd);
}

/**
 * FolderShelf.byArchived: newest archived first, then by id (#2153); a record from before
 * archivedAt goes by its last activity.
 */
export function byArchived(a: Agent, b: Agent): number {
  return (b.archivedAt ?? b.lastActivityAt) - (a.archivedAt ?? a.lastActivityAt) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

/** How long ago a session may have been archived and still be Recently archived (#2868), in seconds. */
export const recentArchivedWithin = 24 * 60 * 60;

/**
 * SidebarFolderFold.recentArchived(now:): the first `shown` of the archived, newest first, of those
 * archived in the last 24 hours (#2868). An older one is not recent, so none is shown in its place.
 */
export function recentlyArchived(archived: readonly Agent[], shown: number, now: number): Agent[] {
  const since = now - recentArchivedWithin;
  const recent = archived.slice(0, shown);
  const old = recent.findIndex((a) => (a.archivedAt ?? a.lastActivityAt) < since);
  return old < 0 ? recent : recent.slice(0, old);
}

/**
 * FolderShelf.byStart: newest started first, then by id (#182). A working agent's activity
 * changes with every line, so a live group ordered by it shuffled; when it started never changes.
 */
export function byStart(a: Agent, b: Agent): number {
  return b.createdAt - a.createdAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

/** AgentsModel.agents(in:group:): newest started first; under Archived newest archived first, as the host pages them. */
export function agentsIn(agents: readonly Agent[], folder: string, group: AgentGroup): Agent[] {
  const wanted = folderKey(folder);
  const found = agents.filter((agent) => folderPath(agent) === wanted && groupOf(agent) === group);
  return found.sort(group === "archived" ? byArchived : byStart);
}

/** The column's headings in order, empty ones left out. */
export function headings(agents: readonly Agent[], folder: string): Heading[] {
  return liveGroups.flatMap((group) => {
    const found = agentsIn(agents, folder, group);
    return found.length ? [{ group, title: groupTitles[group], agents: found }] : [];
  });
}

/** AgentsModel.counts(in:): how many sessions of one folder are in each group. */
export function counts(agents: readonly Agent[], folder: string): Partial<Record<AgentGroup, number>> {
  const wanted = folderKey(folder);
  const result: Partial<Record<AgentGroup, number>> = {};
  for (const agent of agents) {
    if (folderPath(agent) !== wanted) continue;
    const group = groupOf(agent);
    result[group] = (result[group] ?? 0) + 1;
  }
  return result;
}

/** AgentsModel.attentionCount(in:): Needs you or Blocked, not unread (#1565): what the badge and the title count. */
export function attentionCount(agents: readonly Agent[], folder: string): number {
  const wanted = folderKey(folder);
  return agents.filter((a) => {
    if (folderPath(a) !== wanted) return false;
    const group = groupOf(a);
    return group === "needsAttention" || group === "blocked";
  }).length;
}

/**
 * What a folder row says under its name (FolderRow.subtitle): Needs you first, with unread
 * beside it; else working and unread; else complete and stopped; else nothing.
 */
export function folderSubtitle(agents: readonly Agent[], folder: string): string | null {
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
  return agents.filter((a) => folderPath(a) === wanted && a.state === "finished" && a.isUnread === true).length;
}

/** What one folder's row and fold draw from its agents, worked out once per change to them (#170). */
export interface FolderView {
  headings: Heading[];
  archived: Agent[];
  needsYou: boolean;
  /** Something under Working: with needsYou, the favicon's mood (#1317). */
  working: boolean;
  /** Needs you, Blocked and unread: what the tab's title counts. */
  attention: number;
  subtitle: string | null;
}

/** One folder's view, from that folder's agents alone. */
export function folderView(agents: readonly Agent[], folder: string): FolderView {
  const shown = headings(agents, folder);
  return {
    headings: shown,
    archived: agentsIn(agents, folder, "archived"),
    needsYou: shown.some((h) => h.group === "needsAttention"),
    working: shown.some((h) => h.group === "running"),
    attention: attentionCount(agents, folder),
    subtitle: folderSubtitle(agents, folder),
  };
}
