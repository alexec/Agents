// What a blocked agent waits on (039, #152), as AgentsKitCore's Block words and
// AgentsModel.blockLines say it under the Mac's row and on the Remote's card, held to
// Fixtures/web/block (#157).
import type { Agent, Block, Wait, WaitEnding } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { isOpenBlock, isWaiting } from "./groups";
import { endingSummaries, outcomeHeadings } from "./status";

/** AgentsModel.openBlock: a finished agent's wait that has not cleared, or an empty one for an event wait. Only a
 *  wait the app clears by itself (#1916): an old record's block with nothing to wait on is done. */
export function openBlock(agent: Agent): Block | null {
  if (agent.state !== "finished" || !isOpenBlock(agent.report) || !isWaiting(agent)) return null;
  return agent.report?.block ?? { waits: [] };
}

/** WaitEnding.summary: how a waited-on agent ended, without its message. */
export function endingSummary(ending: WaitEnding): string {
  const how = ending.how;
  if ("finished" in how) {
    const outcome = how.finished.outcome;
    return outcome ? `finished: ${outcomeHeadings[outcome].toLowerCase()}` : "finished without saying how it went";
  }
  if ("stopped" in how) {
    const reason = how.stopped._0;
    if (!reason) return "stopped";
    // A reason from a newer host reads as unrecognised, as Swift decodes it.
    const summary = reason in endingSummaries ? endingSummaries[reason] : endingSummaries.unrecognised;
    return summary?.toLowerCase() ?? "stopped";
  }
  if ("archived" in how) return "archived";
  return "gone";
}

/** Block.waitLine: "Build — still working", or "Build — finished: complete". */
export function waitLine(name: string, ending: WaitEnding | undefined): string {
  return ending ? `${name} — ${endingSummary(ending)}` : `${name} — still working`;
}

/** Block.wakeLine: above the wait lines when there is more than one. */
export function wakeLine(block: Block): string | null {
  if (block.clearedAt !== undefined || block.waits.length < 2) return null;
  return block.wakeOn === "any" ? "Carries on when any of these finishes" : "Carries on when all of these have finished";
}

/** Block.checkAgainLine: when it will look again, in the reader's own time. */
export function checkAgainLine(block: Block): string | null {
  if (block.clearedAt !== undefined || block.checkAgainAt === undefined) return null;
  const at = fromWireDate(block.checkAgainAt);
  return `Checks again at ${at.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}`;
}

/** Block.cardTitle: the heading of its card at the foot of the chat (#2750). */
export function cardTitle(block: Block): string {
  return block.waits.length === 0 ? "Waiting to check again" : block.waits.length === 1 ? "Waiting for a session" : "Waiting for sessions";
}

/** AgentsModel.waitName: its title now, or the one it had when the block was made. */
export function waitName(wait: Wait, agents: readonly Agent[]): string {
  const title = agents.find((a) => a.id === wait.agentID)?.title?.trim();
  return title ? title : wait.nameAtReport;
}

/** AgentsModel.blockLines: any of or all of, one line an agent waited on, and when it checks again. */
export function blockLines(agent: Agent, agents: readonly Agent[]): string[] {
  const block = openBlock(agent);
  if (!block) return [];
  const lines = block.waits.map((wait) => waitLine(waitName(wait, agents), wait.ending));
  const wake = wakeLine(block);
  const check = checkAgainLine(block);
  return [...(wake ? [wake] : []), ...lines, ...(check ? [check] : [])];
}

/** The agents an open block still waits on by name in quotes, as AgentsModel.waitMark names them (#582). */
export function blockWaitNames(agent: Agent, agents: readonly Agent[]): string[] {
  const waits = openBlock(agent)?.waits ?? [];
  const working = waits.filter((wait) => wait.ending === undefined);
  return (working.length > 0 ? working : waits).map((wait) => `“${waitName(wait, agents)}”`);
}

/** AgentsModel.carryOnLabel and Block.carryOnPrompt: what Carry on says, and sends as the person. */
export const carryOnLabel = "Carry on";
export const carryOnPrompt = "I've cleared the block you were waiting on. Carry on.";

/** AgentsModel.carryOnHelp: only a wait has Carry on (#1916). */
export function carryOnHelp(_agent: Agent): string {
  return "Stop waiting and carry on now";
}
