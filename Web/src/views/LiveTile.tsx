// What an agent drives (#3004, #4138, #4140), as one tile at the end of the transcript: the newest
// frame of the screen, the agent browser or a simulator, its source by name, and the agent's last
// action in words; "Mac is locked" and no picture while the screen is locked (FR-012). With two
// sources at once, a small switch picks one. Open, on the browser or a simulator, is the person's
// own use of it. The window and the Remote draw LiveTile.swift.
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../model/store";
import type { LiveSource } from "../protocol/generated";
import { freshFrames, shownFrame, tileState } from "../model/liveTile";
import { tileKind, tileLocked, tileLockedBody, tileName, tileOpen, tileOpenHelp, tileSwitch, tileWaiting } from "../model/liveTileWords";
import { nowDriving, nowWorking } from "../model/nowWords";
import { NowHead, useNowOpen } from "./Now";
import { WorkingMark } from "./SessionRow";

// The window's SF Symbols, display, globe and iphone, drawn plain.
function SourceIcon({ source }: { source: LiveSource }) {
  return (
    <svg class="live-tile-icon" viewBox="0 0 16 16" aria-hidden="true">
      {source === "screen" ? <><rect x="1.5" y="2.5" width="13" height="9" rx="1.5" /><path d="M5.5 14h5M8 11.5V14" /></>
        : source === "browser" ? <><circle cx="8" cy="8" r="6.5" /><path d="M1.5 8h13M8 1.5c-2.2 2.4-2.2 10.6 0 13M8 1.5c2.2 2.4 2.2 10.6 0 13" /></>
        : <><rect x="4" y="1.5" width="8" height="13" rx="2" /><path d="M7 12.5h2" /></>}
    </svg>
  );
}

export function LiveTile({ store, host, agentID, open }: {
  store: Store; host: string; agentID: string; open: (source: LiveSource) => void;
}) {
  // Once a second, so a source whose frames stopped drops out.
  const [now, setNow] = useState(Date.now());
  const [chosen, setChosen] = useState<LiveSource | null>(null);
  const isOpen = useNowOpen();
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  const fresh = freshFrames(store.liveFrames.value, host, agentID, now);
  const shown = shownFrame(fresh, chosen);
  // Its frames stopped: the Now card's working line, until the agent is done.
  if (!shown) return <NowHead mark={<WorkingMark tool="drive" />} title={nowWorking} />;
  const { frame } = shown;
  const state = tileState(frame);
  const name = tileName(frame);
  const label = [name, state.kind === "locked" ? tileLocked : state.narration].filter(Boolean).join(": ");
  const sources = fresh.map((h) => h.frame.source).sort();
  // A part of the Now card (#5033): "Driving the browser · what it did last", and while the card is
  // open (it opens with a picture) the picture, the switch and Open.
  return (
    <div class="now-part desktop-tile live-tile">
      <NowHead mark={<SourceIcon source={frame.source} />} title={nowDriving(frame.source)}
        detail={state.kind === "locked" ? tileLocked : state.narration} />
      {isOpen && <>
        <div role="img" aria-label={label}>
          {state.kind === "picture" ? (
            <img class="desktop-tile-picture" src={state.src} alt="" />
          ) : (
            <div class="desktop-tile-placeholder">
              <p class="strong">{state.kind === "locked" ? tileLocked : tileWaiting(frame.source)}</p>
              {state.kind === "locked" && <p class="quiet">{tileLockedBody}</p>}
            </div>
          )}
        </div>
        {(sources.length > 1 || frame.source !== "screen") && (
          <div class="live-tile-head">
            <p class="quiet live-tile-name">{name}</p>
            {sources.length > 1 && (
              <div class="diff-choice live-tile-switch" role="group" aria-label={tileSwitch}>
                {sources.map((source) => (
                  <button type="button" key={source} aria-pressed={source === frame.source} title={tileKind(source)}
                    aria-label={tileKind(source)} onClick={() => setChosen(source)}><SourceIcon source={source} /></button>
                ))}
              </div>
            )}
            {frame.source !== "screen" && (
              <button type="button" title={tileOpenHelp(frame.source)} onClick={() => open(frame.source)}>{tileOpen}</button>
            )}
          </div>
        )}
      </>}
    </div>
  );
}
