// Browser and Desktop control: Ask, Always Approve or Off (#4264), in the window's words, DriveApprovalWords
// (Packages/AgentsKit/Sources/AgentsKitCore/Model/DesktopControl.swift).
import type { DesktopControlSettings, DriveApproval } from "../protocol/generated";

/** The picker's choices, in order, in the approval words of #4263. */
export const driveApprovals: { mode: DriveApproval; label: string }[] = [
  { mode: "ask", label: "Ask" }, { mode: "always", label: "Always Approve" }, { mode: "off", label: "Off" },
];

export const screenLabel = "Agents drive apps on this Mac";
export const browserLabel = "Agents use the browser";

/** Desktop control's setting as the picker shows it: a host before #4264 says only enabled. */
export function shownMode(settings: DesktopControlSettings): DriveApproval {
  return settings.mode ?? (settings.enabled ? "always" : "off");
}

export function screenFooter(mode: DriveApproval): string {
  switch (mode) {
    case "ask": return "Before an agent drives the screen, it asks you in Needs you: Approve, Approve for This Session, Always Approve or Deny. macOS asks you to grant Agent Loops the Accessibility permission the first time.";
    case "always": return "An agent can click, type and read the screen of any app on this Mac, not only the sandboxed browser, and does not ask first. macOS asks you to grant Agent Loops the Accessibility permission the first time an agent tries.";
    case "off": return "An agent cannot click, type or read the screen of any other app.";
  }
}

export function browserFooter(mode: DriveApproval): string {
  switch (mode) {
    case "ask": return "Before an agent uses this browser and the sign-ins it keeps, it asks you in Needs you: Approve, Approve for This Session, Always Approve or Deny.";
    case "always": return "An agent can use this browser and the sign-ins it keeps, and does not ask first.";
    case "off": return "No agent can use this browser. Agents do not get the browser tools.";
  }
}
