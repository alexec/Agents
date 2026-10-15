// The Blob's celebrations (#986), as `CelebrationBlob` in Swift: in the bottom left corner, the Blob
// comes up, hops once looking up, and goes back down, with a burst of confetti for the day's first
// merge and for a milestone. With reduced motion it fades in and out where it stands, with no hop
// and no confetti. Held while the open session asks a question or the person is typing; let go at
// once with Celebrations off in Settings. Takes no clicks.
import { useEffect, useState } from "preact/hooks";
import { type Celebration as Moment, celebrationsOn } from "../model/celebrations";
import { route } from "../route";
import type { Store } from "../model/store";
import { Blob } from "./Huddle";

/** How long after the last key the person counts as typing, in ms. */
const QUIET = 3000;
/** How long the Blob stays, in ms, as `Celebration.seconds`. */
const LASTS = 2200;
/** The confetti's bits: where each flies, how it spins, its colour. Made once. */
const BITS = Array.from({ length: 26 }, (_, i) => ({
  x: Math.round(-110 + Math.random() * 220),
  y: Math.round(-200 - Math.random() * 110),
  spin: Math.round(-540 + Math.random() * 1080),
  colour: ["#3A78E6", "#CFE3FF", "#FF7BA9", "#FFD23F", "#5ED6B0", "#FF9F45"][i % 6],
}));

let lastKey = 0;
if (globalThis.window) window.addEventListener("keydown", () => { lastKey = Date.now(); }, { capture: true, passive: true });

export function Celebration({ store }: { store: Store }) {
  const pending = store.celebration.value;
  const on = celebrationsOn.value;
  const r = route.value;
  const held = !!(r.host && r.session
    && (store.permissionsFor(r.host, r.session).length > 0 || store.elicitationsFor(r.host, r.session).length > 0));
  const [playing, setPlaying] = useState<Moment | null>(null);

  useEffect(() => {
    if (!pending || playing) return;
    if (!on) { store.celebration.value = null; return; }
    if (held) return;
    let timer = 0;
    const tryPlay = () => {
      const since = Date.now() - lastKey;
      if (since < QUIET) { timer = window.setTimeout(tryPlay, QUIET - since); return; }
      setPlaying(pending);
      if (store.celebration.peek()?.id === pending.id) store.celebration.value = null;
    };
    tryPlay();
    return () => window.clearTimeout(timer);
  }, [pending?.id, on, held, playing]);

  useEffect(() => {
    if (!playing) return;
    const timer = window.setTimeout(() => setPlaying(null), LASTS + 400);
    return () => window.clearTimeout(timer);
  }, [playing?.id]);

  if (!playing) return null;
  return (
    <div class="celebration" key={playing.id} aria-hidden="true">
      {playing.confetti && (
        <div class="confetti">
          {BITS.map((bit, i) => (
            <i key={i} style={{ "--x": `${bit.x}px`, "--y": `${bit.y}px`, "--spin": `${bit.spin}deg`, background: bit.colour }} />
          ))}
        </div>
      )}
      <div class="celebration-blob"><Blob look={{ x: 0.3, y: -0.6 }} height={58} /></div>
    </div>
  );
}
