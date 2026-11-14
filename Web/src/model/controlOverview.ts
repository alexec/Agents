// Settings ▸ Control plane ▸ Overview on the page this Mac serves (#4252), as the window's: Serve Agents to browsers
// on this Mac with what the control plane says of it (071 R3), and the control plane's row with Restart.
import type { WebRemoteStatus, WireDate } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export const overviewWords = {
  serve: "Serve Agent Loops to browsers on this Mac",
  restart: "Restart",
  restarting: "Restarting…",
  tryAgain: "Try Again",
  thisMac: "This Mac",
  // Off closes the listener only: this page keeps its connection until it is closed or reloaded.
  offHere: "This page stays connected until you close or reload it. Then open Agent Loops on this Mac to turn it on again.",
  restartHint: "Every window, device and machine connects again by itself.",
} as const;

// Without its scheme: the page names no address but its own origin's (test/lint.mjs).
const address = (web: WebRemoteStatus) => `localhost:${web.port}`;

/** Whether the person turned it off (reason off). */
export const isOff = (web: WebRemoteStatus | undefined) => !!web && !web.served && web.reason === "off";

/** The switch's line: what the control plane says, as WebRemoteStatus.summary, never an address it isn't serving. */
export function serveLine(web: WebRemoteStatus): string {
  if (web.served) return `At ${address(web)}, for a browser on this Mac only.`;
  switch (web.reason) {
    case "off": return `Off. Turn it on to use Agent Loops at ${address(web)}, in a browser on this Mac only.`;
    case "portInUse": return `Not serving: port ${web.port} is in use by another app.`;
    case "build": return "Not serving: this copy of the Agent Loops web app is damaged or missing.";
    default: return `Not serving: port ${web.port} couldn’t be opened${web.detail ? ` (${web.detail})` : ""}.`;
  }
}

/** Try Again is there while it is on and not serving. */
export const canTryAgain = (web: WebRemoteStatus | undefined) => !!web && !web.served && !isOff(web);

/** The control plane's row, as the window's: its version and since when it runs. */
export function runningLine(version: string | undefined, startedAt: WireDate | undefined): string {
  const parts = version ? [`agents-control ${version}`] : [];
  if (startedAt !== undefined) {
    const at = fromWireDate(startedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    parts.push(`running since ${at}`);
  }
  return parts.join(" · ");
}
