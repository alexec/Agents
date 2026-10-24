// What waits for the person's OK in a folder (#773), as its host lists it on the folder's summary:
// a folder MCP server, a workflow, a plugin, a guarded `.agents` file, or a session asking to be
// archived; and a workflow that failed (#989), to fix or dismiss. The words are the window's and the Remote's, Approval (AgentsKitCore/Model/Approval.swift).
import type { Approval, ApprovalAction, ApprovalKind } from "../protocol/generated";

/** Approval.id: one item within its folder. */
export function approvalID(approval: Approval): string {
  return `${approval.kind}:${approval.key}`;
}

/** Approval.kindWord: the kind in a person's words, as a row's grey line leads with it. */
export const kindWords: Record<ApprovalKind, string> = {
  mcpServer: "Connector", workflow: "Workflow", plugin: "Plugin", file: "File", archive: "Archive",
  workflowFailed: "Workflow",
};

/** Approval.word(for:): each action's button, for this kind. */
export function actionWord(kind: ApprovalKind, action: ApprovalAction): string {
  switch (action) {
    case "approve": return kind === "file" ? "Keep" : kind === "archive" ? "Archive" : "Approve";
    case "deny": return kind === "file" ? "Undo" : kind === "archive" ? "Keep Session" : "Deny";
    case "requestChanges": return "Request Changes";
    case "dismiss": return "Dismiss";
  }
}

/** Approval.explanation: what Approve and Deny do, under the buttons. */
export const explanations: Record<ApprovalKind, string> = {
  mcpServer: "No session here is given this server until you approve it. Deny leaves it off until its entry in "
    + ".agents/mcp.json changes again.",
  workflow: "The workflow does not run until you approve it. Deny leaves it off on this machine until its file "
    + "changes again.",
  plugin: "Nothing from this plugin reaches a session until you approve it. Deny leaves it out until its folder "
    + "changes again.",
  file: "The app goes on using the copy you last approved until you choose. Keep uses the change from now "
    + "on; Undo puts the approved copy back in the file.",
  archive: "The session asked to be archived. Keep Session takes the request away and leaves it where it is.",
  workflowFailed: "The workflow has stopped working. It leaves Needs You when the cause is gone; Dismiss takes it out "
    + "until it fails again.",
};

/** The row's one grey line: "Connector · New with the last pull". */
export function approvalLine(approval: Approval): string {
  return `${kindWords[approval.kind]} · ${approval.line}`;
}

/**
 * Approval.isSession: an archive request is drawn by the session's own row, with its mark, and not
 * as a row of its own.
 */
export function isSessionApproval(approval: Approval): boolean {
  return approval.kind === "archive";
}

/**
 * Approval.opensItsSubject: a failed workflow's row (#989) opens the run's agent, or the workflow,
 * rather than a sheet to read.
 */
export function opensItsSubject(approval: Approval): boolean {
  return approval.kind === "workflowFailed";
}

/**
 * SidebarSmartRow.failedRuns: the agents of a folder's failed workflow runs (#989). Needs You
 * lists each as its workflow's row, which opens it, and not as a session too.
 */
export function failedRuns(approvals: readonly Approval[] | undefined): Set<string> {
  return new Set((approvals ?? []).filter((a) => a.kind === "workflowFailed" && a.agentID !== undefined)
    .map((a) => a.agentID as unknown as string));
}

/** The Request Changes note's placeholder, and its button. */
export const notePlaceholder = "What to change, for the agent that made it";
export const sendNoteLabel = "Send to the Agent";
