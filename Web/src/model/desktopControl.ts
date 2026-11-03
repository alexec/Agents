// The live tile (#3004, US4, FR-011): what to draw from the latest desktopControl/liveFrame, as the
// window's and the Remote's DesktopControlTile.swift draws it. The host sends a frame at least every
// 5 seconds while the agent holds the screen lease, so none heard for staleAfterMs means the lease
// was let go and the tile goes away. Counted from when this page heard the frame, on its own clock:
// capturedAt is the Mac's. A frame is never kept past the next one (FR-016).
import type { DesktopControlLiveFrame } from "../protocol/generated";

/** DesktopControlLiveFrame.staleAfter, in milliseconds. */
export const staleAfterMs = 15_000;

/** The latest frame, with when this page heard it (ms, Date.now()). */
export interface HeardLiveFrame {
  host: string;
  frame: DesktopControlLiveFrame;
  heardAt: number;
}

export type TileState =
  | { kind: "hidden" }
  | { kind: "locked"; narration?: string | undefined }
  | { kind: "picture"; src: string; narration?: string | undefined }
  | { kind: "waiting"; narration?: string | undefined };

/**
 * What the tile shows for the agent `agentID` on `host` at `now` (ms): nothing for another agent or
 * once stale, and never a picture while the screen is locked (FR-012).
 */
export function tileState(heard: HeardLiveFrame | null | undefined, host: string, agentID: string, now: number): TileState {
  if (!heard || heard.host !== host || heard.frame.agentID !== agentID || now - heard.heardAt >= staleAfterMs) {
    return { kind: "hidden" };
  }
  const { frame } = heard;
  const narration = frame.narration;
  if (frame.locked) return { kind: "locked", narration };
  if (frame.image) return { kind: "picture", src: `data:image/jpeg;base64,${frame.image}`, narration };
  return { kind: "waiting", narration };
}
