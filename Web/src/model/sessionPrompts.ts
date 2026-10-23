// The Prompts list (#1658): SessionPrompts (Model/SessionPrompts.swift), ported by hand and held to
// Fixtures/web/prompts.
import type { Cost, TranscriptEntry, TurnSummary, WireDate } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { months, parts } from "./activity";
import { money } from "./limits";
import { timeWords } from "./time";
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
 * may overlap the last turn). `isRunning` is whether the last turn is still going. `earlier` is how
 * many of the person's prompts come before the turns: the first is numbered after them (#1862).
 */
export function sessionPrompts(turns: readonly TurnSummary[], entries: readonly TranscriptEntry[], isRunning: boolean, earlier = 0): SessionPrompt[] {
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
      id: turn.ask.id, number: earlier + prompts.length + 1, text: message._0, title: titleOf(message._0), at: turn.ask.at,
      cost: turn.cost,
      seconds: going || turn.lastAt === null ? null : Math.max(0, Math.round(turn.lastAt - turn.ask.at)),
      ending: going ? null : turn.ending,
    });
  });
  return prompts;
}

/** How many of the person's prompts these turns start with: what the chat lets go of when it trims its oldest turns. */
export function personPrompts(turns: readonly TurnSummary[]): number {
  return turns.filter((turn) => {
    const message = turn.ask && fields(turn.ask, "userMessage");
    return !!message && (message.from ?? "person") === "person";
  }).length;
}

/** The prompts whose words hold `query`, whatever their case; all of them for none. */
export function filteredPrompts(prompts: readonly SessionPrompt[], query: string): SessionPrompt[] {
  const wanted = query.trim().toLowerCase();
  return wanted ? prompts.filter((prompt) => prompt.text.toLowerCase().includes(wanted)) : [...prompts];
}

/** The mark's words on a row whose turn did not end as asked: what a screen reader says. */
export function endingLabel(ending: PromptEnding): string {
  return ending === "stopped" ? "Stopped" : "Failed";
}

/**
 * A row's grey line: "$0.12 · 3m · 14:05", each part left out when it is not known. The time is
 * the hour alone on the day it was sent, with the day before it on another day, and the year in
 * another year.
 */
export function promptLine(prompt: SessionPrompt, now = new Date(), timeZone?: string): string {
  const found: string[] = [];
  if (prompt.cost) found.push(money(prompt.cost.amount, prompt.cost.currency));
  if (prompt.seconds !== null) found.push(timeWords(prompt.seconds));
  found.push(sentWords(fromWireDate(prompt.at as WireDate), now, timeZone));
  return found.join(" \u00B7 ");
}

/** "14:05" today, "3 Oct 14:05" this year, "3 Oct 2025 14:05" before. */
function sentWords(date: Date, now: Date, timeZone?: string): string {
  const at = parts(date, timeZone);
  const today = parts(now, timeZone);
  const time = `${String(at.hour).padStart(2, "0")}:${String(at.minute).padStart(2, "0")}`;
  if (at.year === today.year && at.month === today.month && at.day === today.day) return time;
  const day = `${at.day} ${months[at.month - 1]}`;
  return at.year === today.year ? `${day} ${time}` : `${day} ${at.year} ${time}`;
}

/** Up or Down from `at` in a list of `count`, held at its ends; the last row when none is chosen. */
export function movedTo(at: number | null, count: number, down: boolean): number | null {
  if (count === 0) return null;
  if (at === null) return count - 1;
  return Math.max(0, Math.min(count - 1, at + (down ? 1 : -1)));
}

function titleOf(text: string): string {
  return text.split(/\r\n|[\n\r\v\f\u0085\u2028\u2029]/).map((line) => line.trim()).find((line) => line !== "") ?? "";
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
      if (reason === "cancelled" || reason === "stoppedByAgent" || reason === "stoppedByAdmin" || reason === "costLimit") return "stopped";
      if (reason === undefined || reason === "endTurn" || reason === "daemonGone") return null;
      return "failed";
    }
    if (state?._0 === "finished") return null;
    if (kindOf(entry) === "sandboxFailure") return "failed";
  }
  return null;
}
