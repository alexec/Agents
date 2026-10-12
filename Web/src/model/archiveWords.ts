// An agent's archive_session that waits for approval (#584, #649): the mark and its
// buttons in the window's words, ArchiveRequestWords (Shared/UI/ArchiveRequestWords.swift).
import type { Agent } from "../protocol/generated";
import { asksToArchive } from "./groups";

export const archiveMark = "Archiving needs approval";
export const archiveLabel = "Approve";
export const archiveHelp = "The agent is done with this session: approve archiving it";

/** ArchiveRequestWords.line: "Archiving needs approval", or null for a session that does not. */
export function archiveLine(agent: Agent): string | null {
  return asksToArchive(agent) ? archiveMark : null;
}
