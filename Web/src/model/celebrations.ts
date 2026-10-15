// The Blob's celebrations (#986): the page's half of `Celebration` in Swift. A pull request the
// host's hourly count found landed hops the Blob in the corner, with confetti for the day's first
// and for a milestone earned while the page looked. On by default; the switch is this browser's
// alone, kept in its localStorage as the window keeps it in its own defaults.
import { signal } from "@preact/signals";

export interface Celebration { id: number; confetti: boolean }

/** One still waiting merges with the next: one Blob, with confetti if either had it. */
export function celebrate(held: Celebration | null, confetti: boolean): Celebration {
  return { id: (held?.id ?? 0) + 1, confetti: confetti || held?.confetti === true };
}

/** Whether `next` earned more than `before` said: none when there was no before (a first look). */
export function earnedMore(before: { earned: unknown[] } | undefined, next: { earned: unknown[] }): boolean {
  return before !== undefined && next.earned.length > before.earned.length;
}

const storageKey = "agents.celebrations";
// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
const storage = globalThis.window?.localStorage;

function read(): boolean {
  try {
    return storage?.getItem(storageKey) !== "off";
  } catch {
    return true;
  }
}

export const celebrationsOn = signal<boolean>(read());

export function setCelebrations(on: boolean): void {
  celebrationsOn.value = on;
  try {
    if (on) storage?.removeItem(storageKey);
    else storage?.setItem(storageKey, "off");
  } catch {
    // A browser that keeps nothing (private, full) still keeps the choice for this visit.
  }
}
