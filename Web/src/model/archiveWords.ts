// An agent's archive_session that waits for approval (#584, #649): the mark and its
// buttons in the window's words, ArchiveRequestWords (Shared/UI/ArchiveRequestWords.swift).
import type { Agent } from "../protocol/generated";
import { asksToArchive } from "./groups";

export const archiveMark = "Archiving needs approval";
/** The card's head at the end of the chat (#827). */
export const archiveQuestion = "The agent asks to archive this session";
/** Under the head when the agent said nothing of its own. */
export const noReport = "The agent says its work is done.";
export const archiveLabel = "Approve";
export const archiveHelp = "The agent is done with this session: approve archiving it";
/** Deny (#773): the request goes, and the session stays where it is. */
export const keepLabel = "Keep Session";

/** ArchiveRequestWords.line: "Archiving needs approval", or null for a session that does not. */
export function archiveLine(agent: Agent): string | null {
  return asksToArchive(agent) ? archiveMark : null;
}
