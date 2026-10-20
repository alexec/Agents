// The Prompts list (#1658): SessionPrompts (Model/SessionPrompts.swift), ported by hand and held to
// Fixtures/web/prompts.
import type { Cost, TranscriptEntry, TurnSummary } from "../protocol/generated";
import { fields, kindOf } from "./turns";

/** How a turn ended that did not end as asked: the mark on its row. */
export type PromptEnding = "stopped" | "failed";

/** One row of the Prompts list: a prompt the person sent, and how its turn went. */
export interface SessionPrompt {
  /** The prompt's entry: where the transcript scrolls to, and what Branch from here names. */
  id: string;
  /** Its place among the person's prompts, from 1. */
  number: number;
  text: string;
  /** The first line with words on it: what a row shows. */
  title: string;
  at: number;
  /** What its turn cost, as its runtime reported it. Null when none was reported. */
  cost: Cost | null;
  /** From the prompt to the last thing its turn did. Null while the turn is going. */
  seconds: number | null;
  ending: PromptEnding | null;
}

interface Turn { ask: TranscriptEntry; cost: Cost | null; lastAt: number | null; ending: PromptEnding | null }

/**
 * The person's prompts, oldest first, from the stored turns and the entries held after them (which
 * may overlap the last turn). `isRunning` is whether the last turn is still going.
 */
export function sessionPrompts(turns: readonly TurnSummary[], entries: readonly TranscriptEntry[], isRunning: boolean): SessionPrompt[] {
  // A turn for each ask, in order; a held copy of a turn replaces its stored one.
  const byAsk = new Map<string, Turn>();
  const keep = (turn: Turn) => { byAsk.set(turn.ask.id, turn); };
  for (const turn of turns) {
    if (!turn.ask) continue;
    const outcome = turn.outcome ?? [];
    const lastAt = outcome.length ? Math.max(...outcome.map((entry) => entry.at)) : null;
    keep({ ask: turn.ask, cost: turn.usage?.cost ?? null, lastAt, ending: ending(outcome) });
  }
  // The held entries cut at each ask: the person's, or another agent's (#560), not the app's.
  let chunk: TranscriptEntry[] = [];
  const close = () => {
    const ask = chunk[0];
    if (!ask || !isAsk(ask)) return;
    let cost: Cost | null = null;
    for (const entry of chunk) {
      const more = fields(entry, "usageRecorded")?._0.cost;
      if (more) cost = cost ? (cost.currency === more.currency ? { amount: cost.amount + more.amount, currency: cost.currency } : cost) : more;
    }
    keep({ ask, cost, lastAt: chunk.length > 1 ? chunk[chunk.length - 1]!.at : null, ending: ending(chunk) });
  };
  for (const entry of entries) {
    if (isAsk(entry)) {
      close();
      chunk = [];
    }
    chunk.push(entry);
  }
  close();
  const order = [...byAsk.values()];
  const prompts: SessionPrompt[] = [];
  order.forEach((turn, index) => {
    const message = fields(turn.ask, "userMessage");
    if (!message || (message.from ?? "person") !== "person") return;
    const going = isRunning && index === order.length - 1;
    prompts.push({
      id: turn.ask.id, number: prompts.length + 1, text: message._0, title: titleOf(message._0), at: turn.ask.at,
      cost: turn.cost,
      seconds: going || turn.lastAt === null ? null : Math.max(0, Math.round(turn.lastAt - turn.ask.at)),
      ending: going ? null : turn.ending,
    });
  });
  return prompts;
}

/** The prompts whose words hold `query`, whatever their case; all of them for none. */
export function filteredPrompts(prompts: readonly SessionPrompt[], query: string): SessionPrompt[] {
  const wanted = query.trim().toLowerCase();
  return wanted ? prompts.filter((prompt) => prompt.text.toLowerCase().includes(wanted)) : [...prompts];
}

function titleOf(text: string): string {
  return text.split(/\r\n|[\n\r\u000b\u000c\u0085\u2028\u2029]/).map((line) => line.trim()).find((line) => line !== "") ?? "";
}

function isAsk(entry: TranscriptEntry): boolean {
  const message = fields(entry, "userMessage");
  return !!message && message.from !== "app";
}

/** How a turn's entries say it ended, the latest that says: a stop, a sandbox that did not start, or a finish. */
function ending(entries: readonly TranscriptEntry[]): PromptEnding | null {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i]!;
    const state = fields(entry, "stateChanged");
    if (state?._0 === "stopped") {
      const reason = state.reason;
      if (reason === "cancelled" || reason === "stoppedByAgent" || reason === "costLimit") return "stopped";
      if (reason === undefined || reason === "endTurn" || reason === "daemonGone") return null;
      return "failed";
    }
    if (state?._0 === "finished") return null;
    if (kindOf(entry) === "sandboxFailure") return "failed";
  }
  return null;
}
