// The shape and words beside a session's title: StatusShape (UI/StatusShape.swift) as the Mac's
// sessions list draws it, ported by hand and held to Fixtures/web/status (research R7).
import type { Agent, AgentState, EndedReason, WorkOutcome } from "../protocol/generated";
import { endingIsUnaccountedFor, isWaiting, outcomeNeedsAPerson, personLine, waitingForPerson, folderPath } from "./groups";
import { runningToolLabel } from "./sidebar";

/** Working is a spinner; the rest are drawn. Only needsYou is ever in colour. */
export type StatusShape = "working" | "needsYou" | "waiting" | "done" | "stopped";

export const outcomeHeadings: Record<WorkOutcome, string> = {
  done: "Complete",
  nothing_to_do: "Nothing to do",
  needs_answer: "Waiting on your answer",
  waiting: "Waiting",
};

/** EndedReason.summary: why it stopped, in the window's words. */
export const endingSummaries: Record<EndedReason, string | null> = {
  endTurn: null,
  maxTokens: "Ran out of room",
  maxTurnRequests: "Hit its limit",
  refusal: "Refused",
  cancelled: "Stopped by you",
  processDied: "The runtime crashed",
  daemonGone: "Stopped with the daemon",
  costLimit: "Reached its cost limit",
  unrecognised: "Stopped for a reason we do not know",
  stoppedByAgent: "Stopped by the agent that started it",
  signInRefused: "Its sign-in was refused",
  runtimeError: "The runtime reported an error",
  allowanceSpent: "Its allowance ran out",
  rateLimited: "Rate limited, and still limited after retrying",
  sandboxFailed: "Its sandbox could not start",
  imported: "Imported from another set-up, so not run here",
  stoppedByAdmin: "Stopped by an admin in the Console",
};

export const comingBackDescription = "Coming back after a restart";
export const waitingLabel = "Waiting";
export const startingLabel = "Starting";

const pausedEndings: readonly (EndedReason | undefined)[] = ["cancelled", "stoppedByAgent", "stoppedByAdmin"];

/** StatusShape(row:isComingBack:). */
export function shapeOf(agent: Agent, isComingBack = false): StatusShape {
  if (isComingBack) return "working";
  const outcome = agent.report?.outcome;
  switch (agent.state) {
    case "starting":
    case "running": return "working";
    case "waitingOnUser": return "needsYou";
    case "finished":
      // Unread is the row's mark, not a need (#70).
      if (endingIsUnaccountedFor(agent)) return "needsYou";
      if (outcome !== undefined && outcomeNeedsAPerson(outcome)) return "needsYou";
      // A wait only the connected person can settle (#3051) needs them too.
      if (waitingForPerson(agent)) return "needsYou";
      if (isWaiting(agent)) return "waiting";
      // Only a question needs the person (#1916).
      return "done";
    case "stopped":
      if (agent.continueWhenBack) return "waiting";
      return pausedEndings.includes(agent.endedReason) ? "stopped" : "needsYou";
    case "archived": return "stopped";
    // Starts by itself when a place frees (#362).
    case "queued": return "waiting";
  }
}

/** StatusShape.isTinted: wants a person. */
export function isTinted(shape: StatusShape): boolean {
  return shape === "needsYou";
}

/** StatusShape.words(row:isComingBack:): the tooltip and what a screen reader hears. */
export function statusWords(agent: Agent, isComingBack = false): string {
  const state: AgentState = agent.state;
  const outcome = agent.report?.outcome;
  if (isComingBack) return comingBackDescription;
  // A wait only the person can settle says what it asks of them (#3147), where an outcome's
  // heading would say Finished. A question's own heading still wins.
  const asks = personAsked(agent, isComingBack);
  if (asks) return agent.isUnread === true ? `Unread · ${asks}` : asks;
  if (agent.isUnread === true && state === "finished") return `Unread · ${outcome ? outcomeHeadings[outcome] : "Finished"}`;
  if (agent.continueWhenBack) return "Waiting for an allowance";
  if (state === "queued") return queuedLabel(null);
  if (shapeOf(agent, isComingBack) === "waiting") return waitingLabel;
  if (state === "finished" && outcome) return outcomeHeadings[outcome];
  if (endingIsUnaccountedFor(agent)) return "Finished without saying how it went";
  switch (state) {
    // A running tool is named, as the cog draws it (#2261).
    case "running": return agent.runningTool ? runningToolLabel(agent.runningTool) : "Working";
    case "starting": return startingLabel;
    case "waitingOnUser": return "Waiting on you";
    case "finished": return "Finished";
    case "stopped": return (agent.endedReason && endingSummaries[agent.endedReason]) ?? "Stopped";
    case "archived": return "Archived";
  }
}

/** What the chat's foot says to a screen reader (#2391): the words of the working line, as text in
 * one status node that stays put. Empty when idle. */
export function footStatusWords(agent: Agent, isComingBack = false): string {
  if (isComingBack) return comingBackDescription;
  if (agent.state === "running") return agent.runningTool ? runningToolLabel(agent.runningTool) : "Working";
  if (agent.state === "starting") return "Working";
  return "";
}

/** HelperLimit.ordinal: 1st, 2nd, 3rd, 4th, 11th, 21st. */
export function ordinal(n: number): string {
  const tens = n % 100;
  const suffix = tens >= 11 && tens <= 13 ? "th" : ({ 1: "st", 2: "nd", 3: "rd" } as Record<number, string>)[n % 10] ?? "th";
  return `${n}${suffix}`;
}

/** HelperLimit.queuedLabel: "Queued", or with its place in the queue (#362). */
export function queuedLabel(position: number | null): string {
  return position === null ? "Queued" : `Queued, ${ordinal(position)}`;
}

/**
 * AgentsModel.queuedLine: a queued helper's place in its folder's queue, first in first
 * (HelperLimit.queue: oldest started, then by id), among the agents of its host. Null otherwise.
 */
export function queuedLine(agent: Agent, among: readonly Agent[]): string | null {
  if (agent.state !== "queued") return null;
  const folder = folderPath(agent);
  const queue = among.filter((a) => a.state === "queued" && folderPath(a) === folder)
    .sort((a, b) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const index = queue.findIndex((a) => a.id === agent.id);
  return queuedLabel(index < 0 ? null : index + 1);
}

/** Everything a row says about its state at once. */
export function rowStatus(agent: Agent, isComingBack = false): { shape: StatusShape; tinted: boolean; words: string } {
  const shape = shapeOf(agent, isComingBack);
  return { shape, tinted: isTinted(shape), words: statusWords(agent, isComingBack) };
}

/** The sidebar's one grey line while a session needs you (#1324). */
export function needsYouLine(agent: Agent, question?: string | null, isComingBack = false): string | null {
  if (shapeOf(agent, isComingBack) !== "needsYou") return null;
  if ((agent.state === "waitingOnUser" || agent.report?.outcome === "needs_answer") && question) {
    const first = question.split(/\r?\n/, 1)[0]?.trim();
    if (first) return first;
  }
  if (agent.state === "stopped" && agent.endedReason) return endingSummaries[agent.endedReason];
  if (endingIsUnaccountedFor(agent)) return "Finished without saying how it went";
  return personAsked(agent, isComingBack);
}

/** What puts a finished session under Needs you when it is a wait for the person (#3147), in words. */
function personAsked(agent: Agent, isComingBack: boolean): string | null {
  if (agent.state !== "finished" || shapeOf(agent, isComingBack) !== "needsYou" || endingIsUnaccountedFor(agent)) return null;
  if (agent.report !== undefined && outcomeNeedsAPerson(agent.report.outcome)) return null;
  return personLine(agent);
}
