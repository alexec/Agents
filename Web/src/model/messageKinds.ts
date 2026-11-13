// The message kinds of the design system (docs/reference/design-system.md, "Messages"; #4737, #4740):
// what each tone draws and announces, how long a toast stays, and the words of an alert's buttons.
// No DOM here, so the tests read it.

/** A message's tone: neutral is a status, attention is "a person is needed", failure is "it failed",
 *  warning is "something is wrong or nearly so" (the orange, never a request; #5016), success is an ending
 *  the app can vouch for. */
export type Tone = "neutral" | "attention" | "warning" | "failure" | "success";

/** The icon beside the words: a tone is never colour alone. */
export const toneGlyph: Record<Tone, string> = { neutral: "ⓘ", attention: "⚠︎", warning: "⛔", failure: "✕", success: "✓" };

/** The ARIA role a banner, a sheet note or a toast has: an alert for a failure, a status for the rest. */
export function toneRole(tone: Tone): "alert" | "status" {
  return tone === "failure" ? "alert" : "status";
}

/** A success goes after 4 seconds, a toast with Undo after 8, a failure stays until it is closed. */
export const successMillis = 4000;
export const undoToastMillis = 8000;

/** How long a toast stays before it goes by itself, or null when it stays until it is closed. */
export function toastMillis(tone: Tone, hasUndo: boolean): number | null {
  if (tone === "failure") return null;
  return hasUndo ? undoToastMillis : successMillis;
}

/** An alert's question, as `window.confirm` had it: a title, then a blank line and the detail. With no blank
 *  line, the title ends at the first question mark ("Remove Acme? Its keys go." → "Remove Acme?" and "Its keys
 *  go."); with neither, it is a title alone. */
export function alertParts(text: string): { title: string; detail: string | null } {
  const blank = text.indexOf("\n\n");
  const asked = text.search(/\?(\s|$)/);
  const at = blank >= 0 ? blank : asked >= 0 ? asked + 1 : -1;
  if (at < 0) return { title: text.trim(), detail: null };
  return { title: text.slice(0, at).trim(), detail: text.slice(at).trim() || null };
}

/** The verbs whose question an alert's button repeats ("Remove Fix the parser?" → Remove), with the
 *  ones that take something away drawn as destructive. */
const verbs: Record<string, { label: string; destructive: boolean }> = {
  remove: { label: "Remove", destructive: true },
  delete: { label: "Delete", destructive: true },
  revoke: { label: "Revoke", destructive: true },
  disconnect: { label: "Disconnect", destructive: true },
  unlink: { label: "Unlink", destructive: true },
  stop: { label: "Stop", destructive: true },
  shut: { label: "Shut Down", destructive: true },
  replace: { label: "Replace", destructive: true },
  archive: { label: "Archive", destructive: false },
  move: { label: "Move", destructive: false },
  make: { label: "Make", destructive: false },
  restore: { label: "Restore", destructive: false },
  clear: { label: "Clear", destructive: true },
  take: { label: "Take Back", destructive: true },
  save: { label: "Save", destructive: false },
  resume: { label: "Resume", destructive: false },
  keep: { label: "Keep", destructive: true },
  require: { label: "Require", destructive: false },
  start: { label: "Start", destructive: false },
};

/** The confirm button of an alert: its question's first verb, or Continue; destructive for a verb that
 *  takes something away. "Move … to the Trash?" is Move to Trash. */
export function alertButton(title: string): { label: string; destructive: boolean } {
  const first = title.trim().split(/\s+/)[0]?.toLowerCase().replace(/[^a-z]/g, "") ?? "";
  if (first === "move" && /\bto the trash\b/i.test(title)) return { label: "Move to Trash", destructive: true };
  return verbs[first] ?? { label: "Continue", destructive: false };
}
