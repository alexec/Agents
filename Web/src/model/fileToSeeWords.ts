// A file an agent showed that the person has not looked at (#1802): FileToSeeWords
// (Shared/UI/FileToSeeWords.swift), said the same here. A mark on the row, as unread is:
// never a group, never in the tab's title. The daemon clears agent.fileToSee once it is read.
import type { Agent } from "../protocol/generated";
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

