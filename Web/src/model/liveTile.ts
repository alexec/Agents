// The live tile (#3004, #4138, #4140): what to draw from the latest live/frame of each source an
// agent drives (the screen, the agent browser, a simulator), as the window's and the Remote's
// LiveTile.swift draws it. The host sends frames while the agent drives a source and stops 10
// seconds after its last call, so a source heard from for none of staleAfterMs drops out, and with
// none left the tile goes away. Counted from when this page heard the frame, on its own clock:
// capturedAt is the host's. A frame is never kept past the next of its source (FR-016).
import type { DesktopControlLiveFrame, LiveFrame, LiveSource } from "../protocol/generated";

/** DesktopControlLiveFrame.staleAfter, in milliseconds. */
export const staleAfterMs = 15_000;

/** The latest frame of a source, with when this page heard it (ms, Date.now()). */
export interface HeardLiveFrame {
  host: string;
  frame: LiveFrame;
  heardAt: number;
}

/** A screen frame from a host before live/frame (desktopControl/liveFrame). */
export function fromDesktopControl(frame: DesktopControlLiveFrame): LiveFrame {
  return { ...frame, source: "screen" };
}

/** The fresh frames of the agent `agentID` on `host` at `now` (ms), the newest first. */
export function freshFrames(frames: Partial<Record<LiveSource, HeardLiveFrame>>, host: string, agentID: string,
  now: number): HeardLiveFrame[] {
  return Object.values(frames)
    .filter((h): h is HeardLiveFrame => !!h && h.host === host && h.frame.agentID === agentID && now - h.heardAt < staleAfterMs)
    .sort((a, b) => b.heardAt - a.heardAt);
}

/** The frame in front: the person's choice while it is fresh, else the newest. */
export function shownFrame(fresh: HeardLiveFrame[], chosen: LiveSource | null | undefined): HeardLiveFrame | undefined {
  return fresh.find((h) => h.frame.source === chosen) ?? fresh[0];
}

export type TileState =
  | { kind: "locked"; narration?: string | undefined }
  | { kind: "picture"; src: string; narration?: string | undefined }
  | { kind: "waiting"; narration?: string | undefined };

/** What the tile draws for one frame: never a picture while the screen is locked (FR-012). */
export function tileState(frame: LiveFrame): TileState {
  const narration = frame.narration;
  if (frame.locked) return { kind: "locked", narration };
  if (frame.image) return { kind: "picture", src: `data:image/jpeg;base64,${frame.image}`, narration };
  return { kind: "waiting", narration };
}
