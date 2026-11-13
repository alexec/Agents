// The "Last update 5 min ago" line (#5139, #5141): the words of model/lastUpdate.ts, drawn again on
// one timer that every line on the page shares.
import { signal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import { lastUpdateLine, lastUpdateSpoken } from "../model/lastUpdate";

/** The page's clock for every line, moved on each 10 s while any line is drawn. */
const clock = signal(Date.now());
let lines = 0;
let timer: ReturnType<typeof setInterval> | null = null;

function drawn(): () => void {
  if (lines++ === 0) {
    clock.value = Date.now();
    timer = setInterval(() => { clock.value = Date.now(); }, 10_000);
  }
  return () => {
    if (--lines === 0 && timer) { clearInterval(timer); timer = null; }
  };
}

/** The line, after a banner's words or at the top of a pane (`last-update`): a status line, not a control. */
export function LastUpdate({ at }: { at: number }) {
  useEffect(drawn, []);
  // The clock subscribes the line to the timer; now itself is read as the line is drawn.
  const now = Math.max(clock.value, Date.now());
  return (
    <span class="last-update" aria-label={lastUpdateSpoken(at, now)} title={new Date(at).toLocaleString()}>
      {lastUpdateLine(at, now)}
    </span>
  );
}

/**
 * A section's heading with the line at its trailing end (#5146), for a pane read when it opens. The line is
 * beside the heading, not in it, so the section's name stays the heading's words alone.
 */
export function HeadWithUpdate({ id, title, at }: { id: string; title: string; at: number | undefined }) {
  return (
    <div class="section-head-row">
      <h3 class="section-head" id={id}>{title}</h3>
      {at !== undefined && <LastUpdate at={at} />}
    </div>
  );
}
