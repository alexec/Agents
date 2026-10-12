// The chat project (#229): `~/.agents/chat`, which each host makes for itself and marks `isChat`
// in its project list. New Chat opens its new-session form, as the window's File ▸ New Chat does
// (AppModel.newChat); with none, the host says why (`projects/chatState`).
import type { ChatProjectState, ProjectSummary } from "../protocol/generated";

/** The host's chat project, when it has one that is not archived. */
export function chatProject(projects: ProjectSummary[] | undefined): ProjectSummary | undefined {
  return projects?.find((p) => p.isChat === true && p.project.archivedAt === undefined);
}

/**
 * The host's chat project is archived, as the window's Settings ▸ General ▸ Chat project switch leaves
 * it when off (#694): New Chat is not offered. False when it has none at all, so New Chat can say why.
 */
export function chatSwitchedOff(projects: ProjectSummary[] | undefined): boolean {
  const chats = projects?.filter((p) => p.isChat === true) ?? [];
  return chats.length > 0 && chats.every((p) => p.project.archivedAt !== undefined);
}

/** Why New Chat could not open one, in the window's words; null when the host says it is ready. */
export function chatProblem(state: ChatProjectState | null, host: string): string | null {
  if (state === null) return `${host} has no chat project.`;
  if ("ready" in state) return null;
  if ("archived" in state) return `The chat project on ${host === "This Mac" ? "this Mac" : host} is archived.`;
  if ("noPersonalHome" in state) {
    return `${host} has no personal home folder, so it has no chat project. A copy started on a scratch root needs AGENTS_PERSONAL_HOME.`;
  }
  return state.failed.message;
}
