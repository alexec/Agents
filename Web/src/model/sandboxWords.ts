// SandboxWords' card (064 FR-007, #253): what a runtime's sandbox that could not start says, in
// the window's and the Remote's words.
import type { SandboxFailureRecord } from "../protocol/generated";
import { runtimeName } from "./switchNote";

export const continueWithout = "Continue without sandbox";
export const keepStopped = "Keep stopped";
export const noRecovery = "The app cannot turn this runtime’s sandbox off.";
const foldersStillApply = "The app’s own folder and tool rules still apply.";

/** cardTitle, cardBody, and cardOffer or noRecovery. */
export function sandboxCard(record: SandboxFailureRecord): { title: string; body: string; offer: string } {
  const name = runtimeName(record.runtimeID);
  const body = record.hang
    ? `${name} did not answer when started. Its own sandbox is probably turned on, and it cannot start that way when the app runs it.`
    : `${name} could not isolate commands on this computer, so they did not run.`;
  const access = record.runtimeID === "codex"
    ? "This sets this agent to Full access: Codex approval prompts are off too."
    : `This turns ${name}’s sandbox off for this agent only; its commands run with your own access.`;
  const resend = record.completedToolCalls > 0
    ? "Some commands already ran, so the app asks it to carry on rather than repeating your prompt."
    : "Your prompt is sent again.";
  return { title: `${name}’s sandbox could not start`, body,
    offer: record.recoveryOffered ? `${access} ${resend} ${foldersStillApply}` : noRecovery };
}
