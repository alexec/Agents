/**
 * An agent's hand_to_person (#3529), as the window's and the Remote's HandOffCard answer it:
 * Done, or Can't do it with what stopped the person. The host names the choice `outcome` and
 * the line beside it `outcome_note`, as ask_question names a choice and its note.
 */
import type { JSONValue } from "../protocol/generated";

export function handOffAnswer(done: boolean, note = ""): Record<string, JSONValue> {
  if (done) return { outcome: "done" };
  const said = note.trim();
  return said ? { outcome: "cannot", outcome_note: said } : { outcome: "cannot" };
}
