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

/** Undo after Archive (#1534): how long Undo is offered, in milliseconds (ArchiveUndo.seconds). */
export const undoMillis = 5000;
export const undoLabel = "Undo";

/** ArchiveUndo.line: "Archived “Fix the parser”", and that it stays stopped when Archive stopped it. */
export function undoLine(title: string | undefined | null, stopped: boolean): string {
  const shown = title?.trim() || "Untitled";
  return stopped ? `Archived “${shown}” and stopped it. Undo does not start it again.` : `Archived “${shown}”`;
}
