// The words of a project's Connectors set-up and the one Connect sheet (#1336), ported from
// ConnectorSetupWords in AgentsKitCore so the Mac, the Remote and the page say the same.
import type {
  Connection, ConnectionSignIn, ConnectorEvents, ConnectorProof, ConnectorSetup, ConnectorSlot, ConnectorSlotKind,
} from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export const connectTitle = "Connect GitHub once: issues, pull requests and Actions.";
export const connectNote = "Your connection, for every project. You choose on github.com which repositories Agents can see.";
export const connectButton = "Connect GitHub…";
export const abilities = [
  "Read and write issues",
  "Read and write pull requests and reviews",
  "Read checks and Actions runs",
  "Read and push code",
];
export const sheetSubtitle = "For you, in every project. Agents talks to GitHub's API directly.";
export const sheetChoose = "On github.com you choose which repositories. You can take it back there, or with Disconnect on Your Connectors.";
export const sheetFoot = "The token is kept by the host, never in a log.";
export const continueButton = "Continue on github.com";
export const otherProvidersElsewhere = "Other providers are set up on the Mac.";
export const disconnectNote = "Disconnect deletes the host's tokens. Every project's GitHub slots wait for a connection again. To revoke the App too, go to github.com ▸ Settings ▸ Applications.";

export function intro(project: string, repository: string | undefined): string {
  if (!repository) return `What agents in ${project} can reach. It has no GitHub remote.`;
  return `What agents in ${project} can reach. Repository github.com/${repository}, from its git remote.`;
}

export function connected(c: Connection): string {
  return c.state === "signInAgain" ? "GitHub asks you to sign in again" : `Connected to GitHub as ${c.login ?? "you"}`;
}

export function connectedNote(setup: ConnectorSetup): string {
  const parts = ["Your connection, for every project"];
  if (setup.repositories != null) parts.push(setup.repositories === 1 ? "sees 1 repository" : `sees ${setup.repositories} repositories`);
  return parts.join(" · ");
}

export function notInstalled(repository: string): string {
  return `The Agents app is not installed on ${repository}, so agents can't write there.`;
}

export function setUpHeading(setup: ConnectorSetup): string {
  return `Set up · ${setup.done} of ${setup.slots.length}`;
}

export function heading(kind: ConnectorSlotKind): string {
  return { tasks: "Tasks", codeReview: "Code review", ci: "CI", workspace: "Where agents run" }[kind];
}

export function title(slot: ConnectorSlot): string {
  if (slot.state === "skipped") return "Skipped";
  if (slot.state === "noRemote" && slot.slot === "tasks") return "Choose a tracker";
  return slot.choice;
}

export function line(slot: ConnectorSlot, project: string, repository: string | undefined, onMac: boolean): string {
  const repo = repository ?? project;
  switch (slot.state) {
    case "skipped":
      return {
        tasks: "Agents won't use issues here. Nothing is turned on.",
        codeReview: "Agents won't use pull requests here. Nothing is turned on.",
        ci: "Agents won't wait on checks here. Nothing is turned on.",
        workspace: "Agents run on this Mac.",
      }[slot.slot];
    case "noRemote":
      return `${project} has no GitHub remote, so ${slot.choice} can't be read for it.`;
    case "failed":
    case "refused":
      return slot.message ?? "The read didn't work.";
    case "notRead":
      return "Reading…";
    case "read":
      return {
        tasks: `No issues yet in ${repo}.`,
        codeReview: `No pull requests yet in ${repo}.`,
        ci: `No workflow runs yet in ${repo}.`,
        workspace: onMac ? "Nothing to set up. Other places are set up in Providers." : otherProvidersElsewhere,
      }[slot.slot];
    case "notConnected":
      return {
        tasks: `Agents read, file and close issues in ${repo}. Comes with the GitHub connection.`,
        codeReview: "Agents open pull requests and answer reviews. Comes with the GitHub connection.",
        ci: "Agents see checks pass and fail, and wait on them. Comes with the GitHub connection.",
        workspace: "Nothing to set up.",
      }[slot.slot];
  }
}

export function proofLead(kind: ConnectorSlotKind): string {
  return kind === "ci" ? "Last run" : "Newest";
}

export function ago(at: Date, now: Date = new Date()): string {
  const seconds = Math.max(0, (now.getTime() - at.getTime()) / 1000);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86_400) {
    const h = Math.floor(seconds / 3600);
    return h === 1 ? "1 hour ago" : `${h} hours ago`;
  }
  const d = Math.floor(seconds / 86_400);
  return d === 1 ? "yesterday" : `${d} days ago`;
}

export function proofText(proof: ConnectorProof, now: Date = new Date()): string {
  let text = proof.title;
  if (proof.outcome) text += `, ${proof.outcome}`;
  if (proof.number == null && proof.at != null) text += ` ${ago(fromWireDate(proof.at as never), now)}`;
  return text;
}

export function proof(slot: ConnectorSlot, now: Date = new Date()): string | undefined {
  if (!slot.proof) return undefined;
  const number = slot.proof.number != null ? `#${slot.proof.number} ` : "";
  return `${proofLead(slot.slot)}: ${number}${proofText(slot.proof, now)}`;
}

export function eventsLead(events: ConnectorEvents): string {
  switch (events.state) {
    case "on": return "On for Agents:";
    case "off": return "Off. They go on once a slot has read from GitHub.";
    default: return events.message ?? "Not turned on.";
  }
}

export function eventNouns(names: string[]): string[] {
  const nouns: string[] = [];
  for (const name of names) {
    const noun = `${name.split(".")[0]}.*`;
    if (!nouns.includes(noun)) nouns.push(noun);
  }
  return nouns;
}

export function workflowsLead(events: ConnectorEvents): string {
  return events.workflows.length === 0 ? "No workflow here starts on them yet." : "Now usable by";
}

export function connectionTitle(c: Connection): string {
  return c.login ? `GitHub · ${c.login}` : "GitHub";
}

export function connectionNote(c: Connection): string {
  return c.state === "signInAgain" ? "GitHub refused the renewal: sign in again" : "OAuth · renews by itself";
}

export function projectLine(setup: ConnectorSetup): string {
  if (!setup.repository) return "No GitHub remote";
  const used = setup.slots.filter((s) => s.state === "read").map((s) => s.choice);
  return used.length === 0 ? "Not set up" : used.join(", ");
}

export function sheetStatus(s: ConnectionSignIn): string {
  switch (s.status) {
    case "waiting": return "Waiting for github.com… Type the code there, then approve.";
    case "connected": return "Connected.";
    case "expired": return s.message ?? "The code expired before it was approved. Try again.";
    case "denied": return s.message ?? "The sign-in was cancelled on GitHub.";
    case "cancelled": return "Cancelled.";
    case "failed": return s.message ?? "The sign-in didn't work.";
  }
}

export function isDone(slot: ConnectorSlot): boolean {
  return slot.state === "read" || slot.state === "skipped";
}
