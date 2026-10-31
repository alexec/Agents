// A file an agent showed that the person has not looked at (#1802): FileToSeeWords
// (Shared/UI/FileToSeeWords.swift), said the same here. A mark on the row, as unread is:
// never a group, never in the tab's title. The daemon clears agent.fileToSee once it is read.
import { computed } from "@preact/signals";
import type { Agent } from "../protocol/generated";
import { boolPreference, preferenceKeys, setPreferences } from "./preferences";
import { continueLine } from "./continueWhenBack";

/** "File to see: report.md", or null for a session with nothing to see. */
export function fileToSeeLine(agent: Agent): string | null {
  const path = agent.fileToSee?.path;
  if (!path) return null;
  return `File to see: ${path.split("/").pop() ?? path}`;
}

/**
 * The row's grey line in the report's place (FileToSeeWords.reportLine): the file to see while it
 * is unseen, then when a paused chat continues (#1859), then the report. In words, because a touch screen has no hover for the mark's title (#1873).
 */
export function reportLine(agent: Agent): string | null {
  return fileToSeeLine(agent) ?? continueLine(agent) ?? agent.report?.message ?? null;
}

/**
 * Settings ▸ Finished chats (#1802): whether a chat the person started may archive itself, kept
 * on the Mac's host with the other display choices (DisplayPreference.agentsMayArchiveMyChats).
 */
export const mayArchiveMyChats = computed(() => boolPreference(preferenceKeys.agentsMayArchiveMyChats) ?? true);

export function setMayArchiveMyChats(on: boolean): void {
  setPreferences({ [preferenceKeys.agentsMayArchiveMyChats]: on });
}

export const mayArchiveMyChatsFooter = "On, a chat you started that asks to be archived is archived when its turn ends "
  + "Complete or Nothing to do, unless it showed you a file. Off, it waits for you to approve it. "
  + "Archived chats come back with Unarchive. "
  // Each host reads its own preferences (#1872): the docs' sentence.
  + "Another machine does not read this switch, so a chat in a folder on another machine may still archive itself.";
