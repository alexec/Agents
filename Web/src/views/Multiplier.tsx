// The Multiplier page (#3990): the page's half of the window's MultiplierPage (#3904), with the crowd
// (#3985), the bests (#3988) and the earned badges (#3987), in place of the web's Achievements page. It
// is Reports ▸ Multiplier, and Agents with nothing chosen, as the window's detail with nothing picked.
//
// The numbers count to each new value (about 1 s), from the last values this browser showed. When a PR
// merges or a revert does, a line says so and fades; a new best week says that instead. With reduced
// motion they change with no count and no line, and the crowd neither pops nor blinks.
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import type { Store } from "../model/store";
import type { Multiplier } from "../protocol/generated";
import { achievementDay, achievementList } from "../model/achievements";
import {
  badgeGlyph, baselineLine, blobSize, crowdCount, crowdFill, crowdLayout, earnedBadges, emptyLayout, newsOf, oneDecimal, whole,
  type CrowdLayout,
} from "../model/multiplier";
import { BlobParts } from "./Huddle";

function reducedMotion(): boolean {
  return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
}

function darkScheme(): boolean {
  return typeof matchMedia === "function" && matchMedia("(prefers-color-scheme: dark)").matches;
}

/** The host whose Multiplier and achievements are drawn: this Mac's, as on the window. */
function pageHost(store: Store): string | undefined {
  const macID = store.macHostID.value;
  return store.hosts.value.some((h) => h.id === macID) ? macID : store.hosts.value[0]?.id;
}

interface Figures { multiplier: number; prsMerged: number; engineerHours: number; agentsWorking: number; bestWeek: number; mostAtOnce: number }
const zero: Figures = { multiplier: 0, prsMerged: 0, engineerHours: 0, agentsWorking: 0, bestWeek: 0, mostAtOnce: 0 };
const storageKey = "agents.multiplier.shown";

/** What the page showed last in this browser, so the next open counts from there (the first, from 0). */
function lastShown(): Figures {
  try {
    const stored = JSON.parse(globalThis.window?.localStorage.getItem(storageKey) ?? "null");
    return stored && typeof stored === "object" ? { ...zero, ...stored } : zero;
  } catch {
    return zero;
  }
}

function keepShown(figures: Figures): void {
  try {
    globalThis.window?.localStorage.setItem(storageKey, JSON.stringify(figures));
  } catch {
    // A private window may refuse to store; the next open counts from 0.
  }
}

/** Counts from what it shows to `target` over about a second, eased out; jumps there with reduced motion. */
function useCounting(target: Figures): Figures {
  const [shown, setShown] = useState<Figures>(lastShown);
  const from = useRef(shown);
  from.current = shown;
  const key = JSON.stringify(target);
  useEffect(() => {
    keepShown(target);
    if (reducedMotion()) { setShown(target); return; }
    const start = from.current, began = performance.now();
    let frame = 0;
    const step = (now: number) => {
      const k = Math.min((now - began) / 1000, 1), eased = 1 - (1 - k) ** 3;
      const next = {} as Figures;
      for (const name of Object.keys(target) as (keyof Figures)[]) next[name] = start[name] + (target[name] - start[name]) * eased;
      setShown(next);
      if (k < 1) frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [key]);
  return shown;
}

/** The line under the numbers about the PR that changed them, for about 3 s. */
function useNews(multiplier: Multiplier | undefined): { words: string; up: boolean; id: number } | undefined {
  const [news, setNews] = useState<{ words: string; up: boolean; id: number }>();
  const before = useRef(multiplier);
  useEffect(() => {
    const old = before.current;
    before.current = multiplier;
    if (!multiplier || old === multiplier || reducedMotion()) return;
    const said = newsOf(old, multiplier);
    if (!said) return;
    const next = { ...said, id: Date.now() };
    setNews(next);
    const timer = window.setTimeout(() => setNews((n) => (n?.id === next.id ? undefined : n)), 3000);
    return () => window.clearTimeout(timer);
  }, [multiplier]);
  return news;
}

export function MultiplierPage({ store }: { store: Store }) {
  const host = pageHost(store);
  const multiplier = host ? store.multiplier.value[host] : undefined;
  const achievements = host ? store.achievements.value[host] : undefined;
  // Every agent the page holds with a turn starting or running, so "agents now" moves as they do.
  const agentsWorking = store.allAgents().filter((a) => a.state === "starting" || a.state === "running").length;
  const shown = useCounting({
    multiplier: multiplier?.multiplier ?? 0, prsMerged: multiplier?.prsMerged ?? 0, engineerHours: multiplier?.engineerHours ?? 0,
    agentsWorking, bestWeek: multiplier?.bestWeek ?? 0, mostAtOnce: multiplier?.mostAtOnce ?? 0,
  });
  const news = useNews(multiplier);
  const counted = multiplier?.multiplier !== undefined;
  const bests = multiplier?.bestWeek !== undefined && (
    <p class="multiplier-bests">
      Best week <strong>{oneDecimal(shown.bestWeek)}×</strong>
      {multiplier.mostAtOnce !== undefined && <> · Most at once <strong>{whole(shown.mostAtOnce)}</strong></>}
    </p>
  );
  return (
    <section class="chat multiplier-page" aria-label="Multiplier">
      <div class="multiplier-body">
        <Crowd multiplier={counted ? shown.multiplier : undefined} />
        {counted ? (
          <>
            <p class="multiplier-range">Last 7 days</p>
            <p class="multiplier-hero">{oneDecimal(shown.multiplier)}×</p>
            <div class="multiplier-stats">
              <Stat value={shown.prsMerged} label="PRs merged" />
              <Stat value={shown.engineerHours} label="engineer-hours" />
              <Stat value={shown.agentsWorking} label="agents now" />
            </div>
            {bests}
            <EarnedBadges achievements={achievements} />
            <p class={`multiplier-news${news?.up === false ? " down" : ""}`} aria-live="polite">
              {news && <span key={news.id}>{news.words}</span>}
            </p>
          </>
        ) : (
          <>
            <p class="multiplier-hero empty">— ×</p>
            <p>No merged work in the last 7 days.</p>
            <p class="quiet small">Your number starts when an agent’s first PR merges.</p>
            {bests}
            <EarnedBadges achievements={achievements} />
          </>
        )}
      </div>
      <footer class="multiplier-foot quiet small">
        {multiplier && <p>{baselineLine(multiplier)}</p>}
        <p>↑↓ move · →← unfold and fold a folder</p>
      </footer>
    </section>
  );
}

function Stat({ value, label }: { value: number; label: string }) {
  return (
    <div class="multiplier-stat">
      <span class="multiplier-figure">{whole(value)}</span>
      <span class="quiet small">{label}</span>
    </div>
  );
}

/** The earned achievements as badges (#3987), "5 of 7", and a Next line with the first still to earn. */
function EarnedBadges({ achievements }: { achievements: Parameters<typeof earnedBadges>[0] }) {
  const { badges, next } = earnedBadges(achievements);
  const first = useRef<Set<string> | null>(null);
  // The first answer from the host is what was there, not news: only a badge earned later scales in.
  if (first.current === null && achievements) first.current = new Set(badges.map((b) => b.id));
  return (
    <div class="multiplier-badges" aria-label="Achievements">
      {badges.length > 0 && (
        <div class="badge-row">
          {badges.map((b) => {
            const words = `${b.title}, ${achievementDay(b.at)}`;
            return (
              <span key={b.id} class={`badge${first.current?.has(b.id) ? "" : " new"}`} title={words} aria-label={words} role="img">
                {badgeGlyph[b.id]}
              </span>
            );
          })}
          {next && <span class="quiet small badge-count">{badges.length} of {achievementList.length}</span>}
        </div>
      )}
      {next && <p class="small"><span class="quiet">Next:</span> <strong>{next.how}</strong></p>}
    </div>
  );
}

const crowdHeight = 190;

/**
 * The crowd over the Multiplier (#3985), as the window's `Crowd`: one light-blue Blob for each engineer the
 * agents equal, you in front in white. Past 1,000 one Blob is 10 engineers. The engineers are drawn on one
 * canvas; only your Blob is live, with eyes that look around.
 */
function Crowd({ multiplier }: { multiplier: number | undefined }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const box = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [layout, setLayout] = useState<CrowdLayout>(emptyLayout);
  const [blinking, setBlinking] = useState<Set<number>>(new Set());
  const [youLook, setYouLook] = useState({ x: 0, y: 0 });
  const [youBlink, setYouBlink] = useState(false);
  const popAt = useRef(new Map<number, number>());
  const settled = useRef(false);
  const blobsBefore = useRef(0);
  const [still] = useState(reducedMotion);
  const count = crowdCount(multiplier ?? 0);

  useLayoutEffect(() => {
    const el = box.current;
    if (!el) return;
    setWidth(el.clientWidth);
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(() => setWidth(el.clientWidth));
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  useEffect(() => { setLayout(crowdLayout(count.blobs, width, crowdHeight - 20)); }, [count.blobs, width]);
  // The figures the page sets as it opens are no news.
  useEffect(() => { const t = window.setTimeout(() => { settled.current = true; }, 50); return () => window.clearTimeout(t); }, []);

  // New Blobs pop in one after another over about a second, as the number counts up.
  useEffect(() => {
    const old = blobsBefore.current, now = count.blobs;
    blobsBefore.current = now;
    if (!settled.current || still || now <= old) return;
    const step = Math.min(1 / (now - old), 0.15) * 1000, at = performance.now();
    for (let i = old; i < now; i++) popAt.current.set(i, at + (i - old) * step);
  }, [count.blobs]);

  // A few at a time, now and then; you too, sometimes.
  useEffect(() => {
    if (still) return;
    let timer = 0;
    const next = () => {
      timer = window.setTimeout(() => {
        const blobs = Math.max(count.blobs, 1), n = 1 + Math.floor(Math.random() * 5);
        setBlinking(new Set(Array.from({ length: n }, () => Math.floor(Math.random() * blobs))));
        setYouBlink(Math.random() < 0.25);
        timer = window.setTimeout(() => { setBlinking(new Set()); setYouBlink(false); next(); }, 140);
      }, 900);
    };
    next();
    return () => window.clearTimeout(timer);
  }, [still, count.blobs]);

  // Your eyes look somewhere else now and then.
  useEffect(() => {
    if (still) return;
    let timer = 0;
    const next = () => {
      timer = window.setTimeout(() => {
        const angle = Math.random() * 2 * Math.PI, length = Math.random() * 0.9;
        setYouLook({ x: Math.cos(angle) * length, y: Math.sin(angle) * length * 0.6 });
        next();
      }, 1400 + Math.random() * 1800);
    };
    next();
    return () => window.clearTimeout(timer);
  }, [still]);

  useEffect(() => {
    const el = canvas.current;
    const context = el?.getContext("2d");
    if (!el || !context) return;
    const ratio = globalThis.devicePixelRatio ?? 1;
    el.width = Math.round(width * ratio);
    el.height = Math.round(crowdHeight * ratio);
    const dark = darkScheme();
    let frame = 0;
    const draw = (now: number) => {
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      context.clearRect(0, 0, width, crowdHeight);
      let popping = false;
      for (const index of layout.drawingOrder) {
        const place = layout.places[index]!;
        let scale = place.scale;
        const start = popAt.current.get(index);
        if (!still && start !== undefined) {
          const k = (now - start) / 500;
          if (k < 0) { popping = true; continue; }
          if (k < 1) { popping = true; scale *= 1.25 * k - 0.25 * k ** 3 + Math.sin(k * Math.PI) * 0.15; } else popAt.current.delete(index);
        }
        const faint = index === count.blobs - 1 && count.fraction > 0;
        context.save();
        context.globalAlpha = faint ? Math.max(count.fraction, 0.12) : 1;
        context.translate(place.x, place.y);
        context.rotate((place.seed - 0.5) * 0.18);
        context.scale(scale, scale);
        drawBlob(context, crowdFill(place.seed, dark), (place.seed - 0.5) * 1.6, !still && blinking.has(index));
        context.restore();
      }
      if (popping) frame = requestAnimationFrame(draw);
    };
    frame = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(frame);
  }, [layout, width, blinking, count.blobs, count.fraction]);

  const you = layout.youScale;
  return (
    <div class="crowd" ref={box} style={{ height: `${crowdHeight}px` }} aria-hidden="true">
      <canvas ref={canvas} style={{ width: `${width}px`, height: `${crowdHeight}px` }} />
      <svg class="crowd-you huddle" viewBox={`${-blobSize.width / 2 - 40} ${-blobSize.height / 2 - 40} ${blobSize.width + 80} ${blobSize.height + 80}`}
        width={(blobSize.width + 80) * you} height={(blobSize.height + 80) * you}
        style={{ left: `${width / 2 - (blobSize.width + 80) * you / 2}px`, top: `${crowdHeight - 2 - (blobSize.height + 80) * you}px` }}>
        <BlobParts fill="#fff" look={still ? { x: 0, y: 0 } : youLook} shut={youBlink} />
      </svg>
      {count.each > 1 && <span class="crowd-each quiet small">each Blob is {count.each} engineers</span>}
    </div>
  );
}

const body = typeof Path2D === "function"
  ? new Path2D("M0 -290 C188 -290 300 -186 300 4 C300 196 188 290 0 290 C-188 290 -300 196 -300 4 C-300 -186 -188 -290 0 -290 Z")
  : undefined;

/** One engineer, in the Blob's own units, centred on the origin, as `Crowd.drawBlob`. */
function drawBlob(context: CanvasRenderingContext2D, fill: string, look: number, shut: boolean): void {
  if (!body) return;
  context.lineWidth = 56;
  context.lineJoin = "round";
  context.strokeStyle = "#3A78E6";
  context.stroke(body);
  context.fillStyle = fill;
  context.fill(body);
  context.fillStyle = "#0E1A3A";
  for (const x of [-92, 92]) {
    const height = shut ? 12 : 124;
    context.beginPath();
    context.ellipse(x + look * 18, -30, 46, height / 2, 0, 0, 2 * Math.PI);
    context.fill();
  }
  context.beginPath();
  context.moveTo(-64, 80);
  context.quadraticCurveTo(0, 150, 64, 80);
  context.lineWidth = 28;
  context.lineCap = "round";
  context.strokeStyle = "#0E1A3A";
  context.stroke();
}
