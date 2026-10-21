// Mute Notifications (#2003), in the words of MuteWords.swift, which the window and the Remote
// hold. A muted session still goes under Needs You and still counts in the badge; its host sends
// no push, no Mac notification and no banner for it. A muted workflow's runs are muted sessions.
import type { Agent, WorkflowSummary } from "../protocol/generated";

export const muteLabel = "Mute Notifications";
export const unmuteLabel = "Unmute Notifications";
/** The row's mark, a bell with a slash, drawn as text as the row's other marks are. */
export const muteMark = "🔕︎";
export const mutedWords = "Notifications muted";

export const isMuted = (agent: Agent): boolean => agent.isMuted === true;
export const isWorkflowMuted = (summary: WorkflowSummary): boolean => summary.workflow.muted === true;

export function muteHelp(muted: boolean): string {
  return muted ? "Send notifications for this session again"
    : "Send no notifications for this session. It still shows under Needs You";
}

export function workflowMuteHelp(muted: boolean): string {
  return muted ? "Send notifications for this workflow's runs again. Takes muted: true out of its file"
    : "Send no notifications for this workflow's runs. They still show under Needs You. Writes muted: true into its file";
}
