// Settings ▸ Control plane ▸ Clients (#4253), as the window's: Pair a Device… (a QR code the Remote scans),
// Pair a Mac… and Add a Browser… (a code to paste), each a one-use code from clients/startPairing.
import { encode } from "uqr";
import type { WebRemoteStatus } from "../protocol/generated";
import { serveLine } from "./controlOverview";

export type PairPurpose = "device" | "mac" | "browser";

export const pairPurposes: readonly PairPurpose[] = ["device", "mac", "browser"];

export const pairWords = {
  heading: "Clients",
  hint: "Each code works once, for one client. That client can then do all this page can.",
  button: (purpose: PairPurpose) => `${pairWords.title(purpose)}…`,
  title: (purpose: PairPurpose) => (purpose === "device" ? "Pair a Device" : purpose === "mac" ? "Pair a Mac" : "Add a Browser"),
  making: "Making a code…",
  scan: "Open Agent Loops on your iPhone or iPad and scan this code.",
  paired: (name: string) => `${name} is paired`,
  pairedNote: "It reaches your agents through the control plane, as a Device.",
  joined: (name: string) => `${name} joined with this code. It can’t be used again.`,
} as const;

/** The device code's countdown, as the window's sheet says it. */
export function remainingLine(expires: number, now: number): string {
  const seconds = Math.max(0, Math.floor((expires - now) / 1000));
  if (seconds === 0) return "This code has run out. Close this and pair again.";
  return `Good for ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/** What to do with a Mac's or a browser's code, and for how long it works. */
export function codeInstructions(purpose: "mac" | "browser", expires: number, now: number,
  web: WebRemoteStatus | undefined, publicWeb: string | undefined): string {
  const left = Math.max(0, Math.floor((expires - now) / 1000));
  const time = left === 0 ? "It has run out; close this and ask again."
    : `It works once, for ${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}.`;
  if (purpose === "mac") {
    return `On the other Mac, open Agent Loops, choose Connect to a control plane and paste this. That Mac can then do all this page can. ${time}`;
  }
  return `${browserWhere(web, publicWeb)} That browser can then do all this page can. ${time}`;
}

/** Where to paste a browser's code (#1459): the page on the control plane's own domain, and the page on its Mac. */
function browserWhere(web: WebRemoteStatus | undefined, publicWeb: string | undefined): string {
  const anywhere = publicWeb ? `In any browser, open ${publicWeb} and paste it in.` : null;
  if (!web || (!web.served && web.reason === "off")) {
    return anywhere ?? "Turn on Serve Agent Loops to browsers on this Mac in Settings ▸ Control plane first.";
  }
  // Without its scheme, as the Overview says it (test/lint.mjs).
  const address = `localhost:${web.port}`;
  const here = web.served ? `On this Mac, open ${address} and paste it in.`
    : `${serveLine(web)} Press Try Again in Settings ▸ Control plane ▸ Overview, then open ${address} on this Mac and paste it in.`;
  return anywhere ? `${anywhere} ${here}` : here;
}

/** The QR code's dark modules, one rect each as `x,y`, with a border of one, at correction M as the window's. */
export function qrModules(text: string): { size: number; dark: [number, number][] } {
  const qr = encode(text, { ecc: "M", border: 1 });
  const dark: [number, number][] = [];
  qr.data.forEach((row, y) => { row.forEach((on, x) => { if (on) dark.push([x, y]); }); });
  return { size: qr.size, dark };
}
