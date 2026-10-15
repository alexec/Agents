import { useEffect, useRef, useState } from "preact/hooks";

/**
 * The Huddle (#987, the mark of #1007): three Blobs over the empty page of a new session, as the
 * window's and the Remote's `Huddle`. Left alone their eyes look around now and then and blink, and
 * the two at the back glance at the one in front. While the prompt has focus all three look at the
 * pointer; with no pointer, or with it still for about 2 s, down at the prompt and along it as the
 * person types. With reduced motion the eyes stay still, looking ahead.
 */

type Look = { x: number; y: number };

/**
 * In the mark's own units (`design/logo/three-blobs/B.svg`), the two at the back first. Each Blob's eyes
 * take their own time (`pace`) and wait their own beat (`lag`), in seconds, so the three never move as one.
 */
const BLOBS = [
  { cx: 300, cy: 430, tilt: -8, scale: 0.5, fill: "#CFE3FF", facing: 20, pace: 0.55, lag: 0.12 },
  { cx: 724, cy: 430, tilt: 8, scale: 0.5, fill: "#CFE3FF", facing: -20, pace: 0.7, lag: 0.25 },
  { cx: 512, cy: 600, tilt: 0, scale: 0.62, fill: "#fff", facing: 0, pace: 0.4, lag: 0 },
];
/** The part of the mark's 1024 square the three Blobs and their outlines cover. */
const BOX = { x: 115, y: 249, width: 794, height: 548 };
const BODY = "M0 -290 C188 -290 300 -186 300 4 C300 196 188 290 0 290 C-188 290 -300 196 -300 4 C-300 -186 -188 -290 0 -290 Z";
const AHEAD: Look = { x: 0, y: 0 };

const random = (low: number, high: number) => low + Math.random() * (high - low);

function reducedMotion(): boolean {
  return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export function Huddle({ focused, typed, height = 72 }: { focused: boolean; typed: number; height?: number }) {
  const svg = useRef<SVGSVGElement>(null);
  const [still] = useState(reducedMotion);
  const [idle, setIdle] = useState<Look[]>([AHEAD, AHEAD, AHEAD]);
  const [blinking, setBlinking] = useState<boolean[]>([false, false, false]);
  /** Where the pointer is, in the page; null while it is still or there is none. */
  const [pointer, setPointer] = useState<{ x: number; y: number } | null>(null);

  // Now and then one Blob looks somewhere else; the two at the back sometimes at the one in front.
  useEffect(() => {
    if (still) return;
    let timer = 0;
    const next = () => {
      timer = window.setTimeout(() => {
        const index = Math.floor(Math.random() * 3);
        const roll = Math.random();
        const angle = random(0, 2 * Math.PI), length = random(0.4, 0.9);
        const look = index < 2 && roll < 0.35 ? { x: index === 0 ? 0.8 : -0.8, y: 0.5 }
          : roll < 0.55 ? AHEAD : { x: Math.cos(angle) * length, y: Math.sin(angle) * length };
        setIdle((looks) => looks.map((l, i) => (i === index ? look : l)));
        next();
      }, random(1400, 3200));
    };
    next();
    return () => window.clearTimeout(timer);
  }, [still]);

  // One at a time, never all three together.
  useEffect(() => {
    if (still) return;
    let timer = 0;
    const next = () => {
      timer = window.setTimeout(() => {
        const which = Math.floor(Math.random() * 3);
        setBlinking((b) => b.map((v, i) => v || i === which));
        timer = window.setTimeout(() => {
          setBlinking([false, false, false]);
          next();
        }, 130);
      }, random(2500, 5500));
    };
    next();
    return () => window.clearTimeout(timer);
  }, [still]);

  // The pointer only while the prompt has focus; a still one gives the prompt back after 2 s.
  useEffect(() => {
    if (still || !focused) { setPointer(null); return; }
    let resting = 0;
    const moved = (e: PointerEvent) => {
      if (e.pointerType === "touch") return;
      setPointer({ x: e.clientX, y: e.clientY });
      window.clearTimeout(resting);
      resting = window.setTimeout(() => setPointer(null), 2000);
    };
    window.addEventListener("pointermove", moved);
    return () => { window.removeEventListener("pointermove", moved); window.clearTimeout(resting); };
  }, [still, focused]);

  const look = (index: number): Look => {
    if (still) return AHEAD;
    if (!focused) return idle[index] ?? AHEAD;
    const rect = svg.current?.getBoundingClientRect();
    if (pointer && rect) {
      const blob = BLOBS[index]!;
      const unit = rect.height / BOX.height;
      const dx = pointer.x - (rect.left + (blob.cx - BOX.x) * unit);
      const dy = pointer.y - (rect.top + (blob.cy - 30 * blob.scale - BOX.y) * unit);
      const distance = Math.max(Math.hypot(dx, dy), 1);
      // Full turn only past a short reach, so a pointer on the Blobs is not a squint.
      const reach = Math.min(distance / 160, 1);
      return { x: (dx / distance) * reach, y: (dy / distance) * reach };
    }
    // Down at the prompt, along it left to right as the words grow.
    return { x: typed === 0 ? 0 : -0.7 + (1.4 * (typed % 60)) / 60, y: 1 };
  };

  return (
    <svg ref={svg} class="huddle" aria-hidden="true" viewBox={`${BOX.x} ${BOX.y} ${BOX.width} ${BOX.height}`}
      height={height} width={(height * BOX.width) / BOX.height}>
      {BLOBS.map((blob, index) => {
        const eyes = look(index);
        return (
          <g key={index} transform={`translate(${blob.cx} ${blob.cy}) rotate(${blob.tilt}) scale(${blob.scale})`}>
            <path d={BODY} fill="none" stroke="#3A78E6" stroke-width="56" stroke-linejoin="round" />
            <path d={BODY} fill={blob.fill} />
            <g class="huddle-eyes" style={{ transform: `translate(${blob.facing + eyes.x * 18}px, ${eyes.y * 32}px)`,
              transitionDuration: `${blob.pace}s`, transitionDelay: `${blob.lag}s` }}>
              {[-92, 92].map((x) => (
                <ellipse key={x} class={blinking[index] ? "huddle-eye shut" : "huddle-eye"} cx={x} cy={-30} rx={46} ry={62} fill="#0E1A3A" />
              ))}
            </g>
            <path d={`M${blob.facing - 64} 80 Q${blob.facing} 150 ${blob.facing + 64} 80`} fill="none" stroke="#0E1A3A"
              stroke-width="28" stroke-linecap="round" />
          </g>
        );
      })}
    </svg>
  );
}
