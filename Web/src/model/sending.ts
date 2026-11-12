// A prompt on its way (#4814): the person's bubble drawn in the chat at once, before its host has
// the prompt, until the host's own entry for it lands. One that did not go is taken away, and the
// prompt bar gives its words back. The window's and the Remote's are AgentsModel's `sending`.
import type { Agent, TranscriptEntry } from "../protocol/generated";
import { fields } from "./turns";

export type Sending = {
  id: string;
  text: string;
  /** The host said it has it: the next entry it sends for this agent is the prompt's own. */
  answered: boolean;
};

/** PromptWords.willQueue: whether a prompt sent now waits for the turn to end rather than go. */
export function willQueue(agent: Agent): boolean {
  return agent.state === "starting" || agent.state === "running" || agent.state === "waitingOnUser"
    || agent.state === "queued" || (agent.queuedPrompts ?? []).length > 0;
}

/**
 * The prompts still on their way once `entry` has landed: the person's prompt with the same words
 * takes its bubble away, and any other entry takes the oldest one the host already answered.
 */
export function landed(going: readonly Sending[], entry: TranscriptEntry): Sending[] {
  if (going.length === 0) return [...going];
  const message = fields(entry, "userMessage");
  if (message && (message.from ?? "person") === "person") {
    const words = message._0.trim();
    const at = going.findIndex((s) => s.text.trim() === words);
    if (at >= 0) return going.filter((_, i) => i !== at);
  }
  const answered = going.findIndex((s) => s.answered);
  return answered >= 0 ? going.filter((_, i) => i !== answered) : [...going];
}
