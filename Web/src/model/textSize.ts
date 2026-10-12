// The person's text size (#750): Default, Large or Larger, kept in this browser's
// localStorage as the window keeps it in its own defaults (Shared/UI/TypeScale.swift). It is
// this browser's alone and travels nowhere. Set on the page's root as `data-text-size`, which
// theme/paper.css turns into the one `--text-scale` every font-size is multiplied by.
import { signal } from "@preact/signals";

export type TextSize = "default" | "large" | "larger";

export const textSizes: readonly { size: TextSize; title: string }[] = [
  { size: "default", title: "Default" },
  { size: "large", title: "Large" },
  { size: "larger", title: "Larger" },
];

const storageKey = "agents.textSize";

/** A stored value read back, or Default for anything that is not one of the three. */
export function parseTextSize(value: string | null | undefined): TextSize {
  return value === "large" || value === "larger" ? value : "default";
}

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
const storage = globalThis.window?.localStorage;

function read(): TextSize {
  try {
    return parseTextSize(storage?.getItem(storageKey));
  } catch {
    return "default";
  }
}

export const textSize = signal<TextSize>(read());

/** Puts the size on the page's root; Default leaves no attribute, so the stylesheet's own 1 holds. */
export function applyTextSize(size: TextSize = textSize.peek()): void {
  const root = globalThis.document?.documentElement;
  if (!root) return;
  if (size === "default") delete root.dataset.textSize;
  else root.dataset.textSize = size;
}

/** The person's choice: kept, and drawn at once. */
export function chooseTextSize(size: TextSize): void {
  textSize.value = size;
  try {
    if (size === "default") storage?.removeItem(storageKey);
    else storage?.setItem(storageKey, size);
  } catch {
    // A browser that keeps nothing (private, full) still draws the size for this visit.
  }
  applyTextSize(size);
}
