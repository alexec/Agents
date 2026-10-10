// PromptWords (Shared/UI/Chat/PromptPieces.swift), for the page's prompt bar (#254): what the
// empty field says, whether what is typed will wait, and Send's words.
import type { Agent } from "../protocol/generated";

/** AgentState.hasTurnInFlight. */
export function hasTurnInFlight(agent: Agent): boolean {
  return agent.state === "starting" || agent.state === "running" || agent.state === "waitingOnUser";
}

export const askPlaceholder = "What do you want to do?";

/** PromptWords.placeholder: while it works, what happens to what is typed. */
export function promptPlaceholder(agent: Agent | undefined): string {
  if (!agent) return askPlaceholder;
  if (hasTurnInFlight(agent)) return "What do you want to do next?";
  // What is typed waits with it, and goes when it starts (#362).
  if (agent.state === "queued") return "Queued: what you type goes when it starts";
  return agent.state === "archived" ? "Say what next, and this comes back" : askPlaceholder;
}

/** PromptWords.willQueue: what is typed now will wait rather than go. */
export function willQueue(agent: Agent | undefined): boolean {
  return !!agent && (hasTurnInFlight(agent) || agent.state === "queued" || (agent.queuedPrompts ?? []).length > 0);
}

export const stopHelp = "Stop this agent and stay on the chat";
/** OptionsNote's nothingOffered: the runtime named, as the window says it. */
export const nothingToAdjust = (runtime: string | undefined) => `${runtime ?? "This runtime"} has nothing to adjust.`;
export const sendLabel = (queues: boolean) => (queues ? "Queue" : "Send");
export const sendHelp = (queues: boolean) => (queues ? "Queue this, to go when the turn ends" : "Send");

/** PromptReturn (AgentsKitCore), the same rule in every client (#377): Return and Shift-Return
 * send, and only Option-Return is a line break. On a touch screen it is the Remote's on-screen
 * keyboard instead (#543): with no Option key, Return is a line break and Send is the button. */
export function returnAction(key: { altKey: boolean }, touch = onTouchScreen()): "send" | "lineBreak" {
  return touch || key.altKey ? "lineBreak" : "send";
}

/** A finger is the page's main pointer: a phone or tablet, likely with only the on-screen keyboard. */
export function onTouchScreen(): boolean {
  return typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;
}
