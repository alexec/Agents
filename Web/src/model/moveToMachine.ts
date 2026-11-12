// Move to Machine… (#3790), as the window's: a session goes on on another of the person's
// machines, as an agent's move_session does (#3717). Its host stops the turn if one runs, sends
// the branch with its uncommitted changes to the folder there, and that machine takes the session
// with its id, labels and transcript; this host then lets it go.
import type { ControlMachine } from "../protocol/generated";
import { bytesInWords } from "./artifacts";
import { hostAnswers } from "./capabilities";

/** The machines a session on `host` can move to: the others that are online now, by name. */
export function moveTargets(hosts: readonly ControlMachine[], host: string): ControlMachine[] {
  return hosts.filter((h) => h.id !== host && hostAnswers(h.state))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
}

/** What the sheet says goes, with the window's words. */
export function whatGoes(stops: boolean): string {
  const line = "Its branch goes there with its uncommitted changes, and the session goes on there with this conversation.";
  return stops ? `${line} Its turn stops here, and it carries on there.` : line;
}

/**
 * A move under way, on the session's row (#4641), as the window's: the branch's bytes once there
 * are a megabyte or more of them, then the session itself.
 */
export function movingLine(machine: string, sent: number, total: number, branchSent: boolean): string {
  if (branchSent) return `Moving to ${machine}: sending the session…`;
  if (total < 1_000_000) return `Moving to ${machine}: sending its branch…`;
  return `Moving to ${machine}: sending its branch, ${bytesInWords(sent)} of ${bytesInWords(total)}…`;
}

export const folderHelp = "Leave the folder empty to use this project’s folder on that machine, or give an absolute path, such as /home/me/project.";
export const noTargets = "No other machine is online. Start one under Machines in the sidebar, then try again.";
