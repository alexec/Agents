// The live tile's words (#3004, #4140), LiveTileWords (Shared/UI/Chat/LiveTile.swift).
import type { LiveFrame, LiveSource } from "../protocol/generated";

export const tileScreen = "Screen";
export const tileBrowser = "Agent Browser";
export const tileSimulator = "Simulator";
export const tileLocked = "Mac is locked";
export const tileLockedBody = "The agent keeps working. No picture is shown while the screen is locked.";
export const tileOpen = "Open";
export const tileSwitch = "Show";

/** The source's own name, for the switch between two. */
export function tileKind(source: LiveSource): string {
  return source === "screen" ? tileScreen : source === "browser" ? tileBrowser : tileSimulator;
}

/** The tile's head: "Screen", the page's title, or the simulator's name. */
export function tileName(frame: LiveFrame): string {
  return frame.source !== "screen" && frame.title ? frame.title : tileKind(frame.source);
}

export function tileWaiting(source: LiveSource): string {
  return source === "screen" ? "Waiting for the first look at the screen…"
    : source === "browser" ? "Waiting for the first look at the page…"
    : "Waiting for the first look at the simulator…";
}

export function tileOpenHelp(source: LiveSource): string {
  return source === "simulator" ? "Use the simulator yourself." : "Use the page yourself.";
}
