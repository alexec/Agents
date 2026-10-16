// The launcher home (#1090): Settings ▸ Sidebar ▸ Home window chooses All projects (the sidebar of
// every project) or Launcher (a page of project cards, each project in a tab of its own, #1089). A
// display choice, kept on the person's Mac with the others and the same on every client (#1033):
// HomeWindow and LauncherCard in AgentsKitCore.
import { computed } from "@preact/signals";
import { preferenceKeys, setPreferences, stringPreference } from "./preferences";

export type HomeWindow = "allProjects" | "launcher";

export const homeWindowTitles: Record<HomeWindow, string> = { allProjects: "All projects", launcher: "Launcher" };

/** What is kept, read back; anything else is the first state, All projects. */
export function homeWindowOf(stored: string | undefined): HomeWindow {
  return stored === "launcher" ? "launcher" : "allProjects";
}

export const homeWindow = computed<HomeWindow>(() => homeWindowOf(stringPreference(preferenceKeys.homeWindow)));

export function setHomeWindow(home: HomeWindow): void {
  setPreferences({ [preferenceKeys.homeWindow]: home });
}

/** A project card's grey line, as the window's: "3 working · 1 needs you · 2 unread", or "idle". */
export function launcherLine(working: number, needsYou: number, unread: number): string {
  const parts: string[] = [];
  if (working > 0) parts.push(`${working} working`);
  if (needsYou > 0) parts.push(`${needsYou} needs you`);
  if (unread > 0) parts.push(`${unread} unread`);
  return parts.length ? parts.join(" · ") : "idle";
}
