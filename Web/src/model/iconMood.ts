// The Blob's mood on the tab's favicon (#1317), as the window draws it on its Dock tile
// (IconMood.swift): quizzical while a question waits, happy while an agent works, asleep with
// neither. The images are design/logo/blob/final/make.sh's. Whether the favicon shows the mood is
// this browser's own choice, kept in localStorage: on unless turned off.

import { signal } from "@preact/signals";

export type IconMood = "asleep" | "happy" | "quizzical";

/** What a project's view says for the mood: Needs you, and Working. */
export interface MoodCounts {
  needsYou: boolean;
  working: boolean;
}

/** IconMood(counts:): a waiting question wins, then a working agent. */
export function iconMood(views: Iterable<MoodCounts>): IconMood {
  let working = false;
  for (const view of views) {
    if (view.needsYou) return "quizzical";
    if (view.working) working = true;
  }
  return working ? "happy" : "asleep";
}

export const faviconFor: Record<IconMood, string> = {
  happy: "/assets/favicon.png",
  asleep: "/assets/favicon-asleep.png",
  quizzical: "/assets/favicon-quizzical.png",
};

const key = "iconShowsMood";
// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
const storage = globalThis.window?.localStorage;

/** Settings ▸ Appearance ▸ the icon's mood: off draws the happy Blob always. */
export const iconShowsMood = signal(storage?.getItem(key) !== "false");

export function setIconShowsMood(on: boolean): void {
  iconShowsMood.value = on;
  storage?.setItem(key, String(on));
}
