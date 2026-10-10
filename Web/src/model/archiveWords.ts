// An agent's request to archive a session (#584, which replaced parking): the mark and its
// buttons in the window's words, ArchiveRequestWords (Shared/UI/ArchiveRequestWords.swift).
import type { Agent } from "../protocol/generated";
import { asksToArchive } from "./groups";

export const archiveMark = "Asks to archive";
export const archiveLabel = "Archive";
export const archiveAllLabel = "Archive All";
export const archiveHelp = "The agent is done with this session: archive it";

/** ArchiveRequestWords.archiveAllHelp. */
export function archiveAllHelp(count: number): string {
  return count === 1 ? "Archive the session that asks to be archived" : `Archive the ${count} sessions that ask to be archived`;
}

/** ArchiveRequestWords.line: "Asks to archive", or null for a session that does not. */
export function archiveLine(agent: Agent): string | null {
  return asksToArchive(agent) ? archiveMark : null;
}
