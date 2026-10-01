// Where a session sits in the sessions column: AgentGroup (Model/AgentGroup.swift), ported by
// hand and held to Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/web/groups (research R7).
import type { Agent, AgentGroup, EndedReason, WireDate, WorkOutcome, WorkReport } from "../protocol/generated";

export const groupTitles: Record<AgentGroup, string> = {
  needsAttention: "Needs you",
  blocked: "Blocked",
  waiting: "Waiting",
  running: "Working",
  finished: "Done",
  stopped: "Paused",
  parked: "Parked",
  archived: "Archived",
};

/** The groups shown in the column, in order. Archived is folded under them; Blocked is never assigned. */
export const liveGroups: readonly AgentGroup[] = ["needsAttention", "waiting", "running", "finished", "stopped", "parked"];

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

export function isParked(agent: Agent): boolean {
  return agent.parking !== undefined && "parked" in agent.parking;
}

export function parkedAt(agent: Agent): WireDate | undefined {
  return agent.parking && "parked" in agent.parking ? agent.parking.parked.at : undefined;
}

/** Agent.isWaiting: the app will carry it on by itself. */
export function isWaiting(agent: Agent): boolean {
  return (agent.eventWait !== undefined && agent.eventWait.ending === undefined) || resumesByItself(agent.report);
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
  const isUnread = agent.isUnread === true;
  if (isParked(agent) && agent.state !== "archived" && agent.state !== "waitingOnUser") return "parked";
  switch (agent.state) {
    case "starting": return "running";
    case "waitingOnUser": return "needsAttention";
    case "running":
      if (outcomeAsked) return settled(wantsEyes || wantsAnswer || isUnread || report === undefined, report, waitingOnEvents);
      return wantsEyes ? "needsAttention" : "running";
    case "finished":
      return settled(wantsEyes || wantsAnswer || isUnread || (outcomeAsked && report === undefined), report, waitingOnEvents);
    case "stopped":
      // The daemon never sends allowanceWait, so the Mac's "waiting for an allowance" arm is absent.
      return pausedEndings.includes(agent.endedReason) ? "stopped" : "needsAttention";
    case "archived": return "archived";
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

/** AgentsModel.agents(in:group:): newest activity first, or under Parked most recently parked first. */
export function agentsIn(agents: readonly Agent[], folder: string, group: AgentGroup): Agent[] {
  const wanted = folderKey(folder);
  const found = agents.filter((agent) => projectFolder(agent) === wanted && groupOf(agent) === group)
    .sort((a, b) => b.lastActivityAt - a.lastActivityAt);
  if (group !== "parked") return found;
  return found.sort((a, b) => (parkedAt(b) ?? -Infinity) - (parkedAt(a) ?? -Infinity));
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

/** AgentsModel.unreadCount(in:): finished chats nobody has looked at since. */
export function unreadCount(agents: readonly Agent[], folder: string): number {
  const wanted = folderKey(folder);
  return agents.filter((a) => projectFolder(a) === wanted && a.state === "finished" && a.isUnread === true).length;
}
