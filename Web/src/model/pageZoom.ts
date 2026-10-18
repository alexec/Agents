// How large a Markdown page's text is drawn (#1419), as PageZoom.swift has it for the window and
// the Remote: one level for every page in this browser, not one per file, kept in localStorage.
// ⌘+, ⌘− and ⌘0 (Ctrl off a Mac) zoom the page while one is shown, and leave the browser's own
// zoom to the rest of the time, so the sidebar and the chat stay their size.

import { signal } from "@preact/signals";

export const zoomSteps = [0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2] as const;
export const actualSize = 1;

/** The step nearest to a level. */
export function snapped(level: number): number {
  if (!Number.isFinite(level)) return actualSize;
  return zoomSteps.reduce((best, step) => (Math.abs(step - level) < Math.abs(best - level) ? step : best), actualSize);
}

/** One step larger, or the largest step. */
export function larger(level: number): number {
  const current = snapped(level);
  return zoomSteps.find((step) => step > current) ?? zoomSteps[zoomSteps.length - 1]!;
}

/** One step smaller, or the smallest step. */
export function smaller(level: number): number {
  const current = snapped(level);
  return [...zoomSteps].reverse().find((step) => step < current) ?? zoomSteps[0];
}

/** What a key does to the level, or null when it is not one of the zoom keys. */
export function zoomForKey(level: number, key: { key: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean }): number | null {
  if (!(key.metaKey || key.ctrlKey) || key.altKey) return null;
  switch (key.key) {
    case "+": case "=": return larger(level);
    case "-": case "_": return smaller(level);
    case "0": return actualSize;
    default: return null;
  }
}

const key = "pageTextZoom";
// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
const storage = globalThis.window?.localStorage;

export const pageZoom = signal(snapped(Number(storage?.getItem(key) ?? actualSize)));

export function setPageZoom(level: number): void {
  pageZoom.value = snapped(level);
  storage?.setItem(key, String(pageZoom.value));
}
