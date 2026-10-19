// Up and Down in the prompt bar (#1551): PromptHistory (Model/PromptHistory.swift), ported by
// hand and held to Fixtures/web/prompt/history.json.
import type { TranscriptEntry, TurnSummary } from "../protocol/generated";
import { fields } from "./turns";

/**
 * What the prompt bar shows after Up or Down, and how far back that is (0 is the newest prompt
 * sent; null is the bar's own text again). Null when the key is not history's: Up takes an empty
 * prompt, or one recalled and left as it was; Down takes a recalled one left as it was.
 */
export function recall(direction: "up" | "down", text: string, sent: readonly string[], at: number | null):
  { text: string; at: number | null } | null {
  // The one recalled, if the prompt bar still shows it as it was given back.
  const unchanged = at !== null && at < sent.length && sent[sent.length - 1 - at] === text ? at : null;
  if (direction === "up") {
    const next = unchanged !== null ? unchanged + 1 : text === "" ? 0 : null;
    if (next === null || next >= sent.length) return null;
    return { text: sent[sent.length - 1 - next]!, at: next };
  }
  if (unchanged === null) return null;
  return unchanged === 0 ? { text: "", at: null } : { text: sent[sent.length - unchanged]!, at: unchanged - 1 };
}

/** The prompts the person sent, oldest first: not another agent's (#560), nor the app's question. One sent twice in a row is one. */
export function sentPrompts(turns: readonly TurnSummary[], entries: readonly TranscriptEntry[]): string[] {
  const sent: string[] = [];
  for (const entry of [...turns.flatMap((turn) => turn.ask ? [turn.ask] : []), ...entries]) {
    const message = fields(entry, "userMessage");
    if (!message || (message.from ?? "person") !== "person" || !message._0 || sent[sent.length - 1] === message._0) continue;
    sent.push(message._0);
  }
  return sent;
}
