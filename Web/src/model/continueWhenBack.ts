// A chat paused by a spent allowance that can carry on by itself (#1859): ContinueWhenBackWords
// (Shared/UI/ContinueWhenBackWords.swift), said the same here. Paused, the chat offers "Continue at
// 07:00"; waiting, it says "Continues at 07:00" in the chat and on its row, with Cancel. The daemon
// keeps the wait on agent.continueWhenBack.
import type { Agent, RuntimeAllowances } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { switchTime } from "./switchNote";

export const continueCancelLabel = "Cancel";
export const continueHelp = "Sends “continue” in this chat when the allowance is back, or sooner if a turn on this runtime works.";

/** Whether the chat offers the button: paused by a spent allowance, and not waiting yet. */
export function offersContinue(agent: Agent): boolean {
  return agent.state === "stopped" && agent.endedReason === "allowanceSpent" && !agent.continueWhenBack;
}

/** The button: the provider's reset time when the page knows it. */
export function continueButton(resetsAt: Date | null, now = new Date()): string {
  if (!resetsAt || resetsAt <= now) return "Continue when it is back";
  return `Continue at ${switchTime(resetsAt, now)}`;
}

/** "Continues at 07:00", or null for a chat that is not waiting. Also the row's grey line. */
export function continueLine(agent: Agent, now = new Date()): string | null {
  const wait = agent.continueWhenBack;
  if (!wait) return null;
  const time = switchTime(fromWireDate(wait.at), now);
  return wait.resetKnown ? `Continues at ${time}` : `Continues when it is back · tries at ${time}`;
}

/** The workflow page's switch (#1918), writing `continue-when-back:`. */
export const workflowContinueSwitch = "Continue when the allowance is back";

/** What the switch means for this workflow's runs. */
export function workflowContinueSentence(on: boolean): string {
  return on ? "A run whose allowance is spent waits, and carries on when it is back."
    : "A run whose allowance is spent stops until somebody chooses Continue.";
}

/** RuntimeAllowances.resetsAt: when the provider said this runtime's allowance resets. */
export function resetsAt(allowances: RuntimeAllowances | undefined, runtimeID: string): Date | null {
  const row = allowances?.rows.find((r) => r.credentialKey.split(":", 1)[0] === runtimeID && "out" in r.state.status);
  const out = row && "out" in row.state.status ? row.state.status.out : undefined;
  return out?.until !== undefined ? fromWireDate(out.until) : null;
}
