// An agent driving the Mac's screen (#3004, US4, FR-011), as a tile at the end of the transcript:
// the latest still of the screen, or "Mac is locked" with no picture (FR-012), and the agent's last
// action in words. The window and the Remote draw DesktopControlTile.swift.
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../model/store";
import { tileState } from "../model/desktopControl";
import { tileLocked, tileLockedBody, tileTitle, tileWaiting } from "../model/desktopControlWords";

export function DesktopControlTile({ store, host, agentID }: { store: Store; host: string; agentID: string }) {
  // Once a second, so a tile whose frames stopped takes itself away.
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  const state = tileState(store.liveFrame.value, host, agentID, now);
  if (state.kind === "hidden") return null;
  const label = [tileTitle, state.kind === "locked" ? tileLocked : state.narration].filter(Boolean).join(": ");
  return (
    <div class="cards">
      <div class="card desktop-tile" role="img" aria-label={label}>
        <p class="quiet strong">{tileTitle}</p>
        {state.kind === "picture" ? (
          <img class="desktop-tile-picture" src={state.src} alt="" />
        ) : (
          <div class="desktop-tile-placeholder">
            <p class="strong">{state.kind === "locked" ? tileLocked : tileWaiting}</p>
            {state.kind === "locked" && <p class="quiet">{tileLockedBody}</p>}
          </div>
        )}
        {state.narration && <p class="desktop-tile-narration">{state.narration}</p>}
      </div>
    </div>
  );
}
