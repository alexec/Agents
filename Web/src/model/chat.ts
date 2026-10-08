// The chat project (#229): `~/.agents/chat`, which each host makes for itself and marks `isChat`
// in its project list. New Chat opens its new-session form, as the window's File ▸ New Chat does
// (AppModel.newChat); with none, the host says why (`projects/chatState`).
import type { ChatProjectState, ProjectSummary } from "../protocol/generated";

/** The host's chat project, when it has one that is not archived. */
export function chatProject(projects: ProjectSummary[] | undefined): ProjectSummary | undefined {
  return projects?.find((p) => p.isChat === true && p.project.archivedAt === undefined);
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
