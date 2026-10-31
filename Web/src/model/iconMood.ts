// The Blob's mood on the tab's favicon (#1317), as the window draws it on its Dock tile
// (IconMood.swift): quizzical while a question waits, happy while an agent works, asleep with
// neither. The images are design/logo/blob/final/make.sh's. Always on: no switch (#2156).

export type IconMood = "asleep" | "happy" | "quizzical";

/** What a folder's view says for the mood: Needs you, and Working. */
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
