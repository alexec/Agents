// The shape and words beside a session's title: StatusShape (UI/StatusShape.swift) as the Mac's
// sessions list draws it, ported by hand and held to Fixtures/web/status (research R7).
import type { Agent, AgentState, EndedReason, WorkOutcome } from "../protocol/generated";
import { endingIsUnaccountedFor, isParked, isWaiting, outcomeNeedsAPerson } from "./groups";

/** Working is a spinner; the rest are drawn. Only needsYou is ever in colour. */
export type StatusShape = "working" | "needsYou" | "waiting" | "done" | "stopped";

export const outcomeHeadings: Record<WorkOutcome, string> = {
  done: "Complete",
  nothing_to_do: "Nothing to do",
  needs_answer: "Waiting on your answer",
  partly_done: "Partly done",
  stuck: "Stuck",
  blocked: "Blocked",
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
};

export const comingBackDescription = "Coming back after a restart";
export const waitingLabel = "Waiting";
export const startingLabel = "Starting";

const pausedEndings: readonly (EndedReason | undefined)[] = ["cancelled", "stoppedByAgent", "allowanceSpent"];

/** StatusShape(row:isComingBack:). */
export function shapeOf(agent: Agent, isComingBack = false): StatusShape {
  if (isComingBack) return "working";
  const outcome = agent.report?.outcome;
  switch (agent.state) {
    case "starting":
    case "running": return "working";
    case "waitingOnUser": return "needsYou";
    case "finished":
      if (agent.isUnread === true || endingIsUnaccountedFor(agent)) return "needsYou";
      if (outcome !== undefined && outcomeNeedsAPerson(outcome)) return "needsYou";
      if (isWaiting(agent)) return "waiting";
      if (outcome === "blocked") return "needsYou";
      return "done";
    case "stopped":
      return pausedEndings.includes(agent.endedReason) ? "stopped" : "needsYou";
    case "archived": return "stopped";
  }
}

/** StatusShape.isTinted: wants a person, and not parked. */
export function isTinted(shape: StatusShape, parked: boolean): boolean {
  return shape === "needsYou" && !parked;
}

/** StatusShape.words(row:isComingBack:): the tooltip and what a screen reader hears. */
export function statusWords(agent: Agent, isComingBack = false): string {
  const state: AgentState = agent.state;
  const outcome = agent.report?.outcome;
  if (isComingBack) return comingBackDescription;
  if (agent.isUnread === true && state === "finished") return `Unread · ${outcome ? outcomeHeadings[outcome] : "Finished"}`;
  if (shapeOf(agent, isComingBack) === "waiting") return waitingLabel;
  if (state === "finished" && outcome) return outcomeHeadings[outcome];
  if (endingIsUnaccountedFor(agent)) return "Finished without saying how it went";
  switch (state) {
    case "running": return "Working";
    case "starting": return startingLabel;
    case "waitingOnUser": return "Waiting on you";
    case "finished": return "Finished";
    case "stopped": return (agent.endedReason && endingSummaries[agent.endedReason]) ?? "Stopped";
    case "archived": return "Archived";
  }
}

/** Everything a row says about its state at once. */
export function rowStatus(agent: Agent, isComingBack = false): { shape: StatusShape; tinted: boolean; words: string } {
  const shape = shapeOf(agent, isComingBack);
  return { shape, tinted: isTinted(shape, isParked(agent)), words: statusWords(agent, isComingBack) };
}
