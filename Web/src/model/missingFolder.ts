// An agent whose folder has gone (#119), as AgentsKitCore's MissingFolderWords says it, so the
// page says what the window and the Remote say.
import type { Agent, Attachment } from "../protocol/generated";

export const missingFolderLabel = "Folder is missing";
export const continueInProjectLabel = "Continue in the project folder";
export const recreateWorktreeLabel = "Recreate the worktree";

/** Marked by the host, which looks on its heartbeat and before every send. */
export function folderIsMissing(agent: Agent): boolean {
  return !!agent.missingFolder && agent.state !== "archived";
}

/** Recreate the worktree is offered: it was one, and its branch is still there. */
export function mayRecreateWorktree(agent: Agent): boolean {
  return !!agent.worktree?.branch && agent.missingFolder?.branchKept === true;
}

/** The folder, as a path: the host's own, which the page can't shorten. */
export function folderPath(agent: Agent): string {
  try {
    return decodeURIComponent(new URL(agent.cwd).pathname).replace(/\/$/, "");
  } catch {
    return agent.cwd;
  }
}

/** A send refused because the folder has gone: what the host said, and what was typed. */
export interface FolderGoneAsk {
  host: string;
  agentID: string;
  message: string;
  text: string;
  attachments: Attachment[];
}
