// What a blocked agent waits on (039, #152), as AgentsKitCore's Block words and
// AgentsModel.blockLines say it under the Mac's row and on the Remote's card, held to
// Fixtures/web/block (#157).
import type { Agent, Block, Wait, WaitEnding } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { isOpenBlock, isWaiting } from "./groups";
import { endingSummaries, outcomeHeadings } from "./status";

/** AgentsModel.openBlock: a finished agent's block that has not cleared, or an empty one for a block that named nothing. */
export function openBlock(agent: Agent): Block | null {
  if (agent.state !== "finished" || !isOpenBlock(agent.report)) return null;
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

/** AgentsModel.carryOnLabel and Block.carryOnPrompt: what Carry on says, and sends as the person. */
export const carryOnLabel = "Carry on";
export const carryOnPrompt = "I've cleared the block you were waiting on. Carry on.";

/** AgentsModel.carryOnHelp: Waiting (the app would carry it on by itself) or Blocked (only the person can). */
export function carryOnHelp(agent: Agent): string {
  return isWaiting(agent) ? "Stop waiting and carry on now" : "Tell it the block has cleared, and let it carry on";
}
