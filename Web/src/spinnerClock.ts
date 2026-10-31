// Every working mark turns in step (#1606, #2044, #2332), as SpinnerClock.swift keeps the window's
// and the Remote's. A CSS animation starts when its element appears, so each new `spin` or ring
// animation is set back to start where SpinnerClock's cycle is now, counted from its epoch (2001).
//
// The working ring (#2332) is three dots on a ring seen edge on: it spins about the vertical axis
// while the session thinks or replies, and also pivots about the horizontal axis while it runs a
// tool. Its keyframes come from the same maths as SpinnerClock.ringDots, made once at start with
// the tilt from `workingMarkTilt` in localStorage, and drawn by the browser from then on.
//
// The waiting mark (#2456, #2657) is the beacon, breathing: a slow fade between dim and full, as
// SpinnerClock.breathOpacity, once in 4 s unless `waitingMarkPeriod` in localStorage says otherwise.
// Its keyframes and period are made at start the same way, and every beacon on the page breathes in step.

/** One turn of the ring, one pivot, and the cycle that holds both (SpinnerClock). */
export const ringSpinPeriod = 1.8;
export const ringPivotPeriod = 3.6;
export const ringPeriod = ringPivotPeriod;
/** How far the ring pivots each way while it runs a tool, in degrees, unless localStorage says. */
export const ringTilt = 30;
export const ringTiltKey = "workingMarkTilt";
/** A dot's diameter and the ring's radius, in fractions of the well: at rest, #2044's three dots. */
export const ringDotDiameter = 0.24;
export const ringRadius = 0.34 / (Math.sqrt(3) / 2);
const restingOpacity = 0.3;

/** One breath of the waiting beacon, in seconds (SpinnerClock.breathPeriod), unless localStorage says. */
export const breathPeriod = 4;
export const breathPeriodKey = "waitingMarkPeriod";
/** The shortest and longest breath the key can ask for, in seconds. */
export const breathPeriodRange: [number, number] = [1, 30];
/** How dim the beacon is at the bottom of a breath: the ring's resting opacity. */
export const breathDimOpacity = restingOpacity;
/** Under Reduce Motion the marks keep going, this many times slower (SpinnerClock.reducedMotionSlowing). */
export const reducedMotionSlowing = 2;

export interface RingDot { x: number; y: number; opacity: number }

/** The dot at angle `spin` on a ring tipped `tilt` from edge on, in radians; y is up. */
export function ringDot(spin: number, tilt: number): RingDot {
  const depth = (Math.sin(spin) * Math.cos(tilt) + 1) / 2;
  return { x: ringRadius * Math.cos(spin), y: ringRadius * Math.sin(spin) * Math.sin(tilt),
    opacity: restingOpacity + (1 - restingOpacity) * depth };
}

/** The three dots `time` seconds into the cycle, left to right at its start; `tilt` in degrees. */
export function ringDots(time: number, tilt: number): RingDot[] {
  const pivot = (tilt * Math.PI) / 180 * Math.cos((2 * Math.PI * time) / ringPivotPeriod);
  const turned = (2 * Math.PI * time) / ringSpinPeriod;
  return [7 / 6, 1 / 2, 11 / 6].map((start) => ringDot(start * Math.PI - turned, pivot));
}

/** The tilt localStorage asks for, between 0 and 90 degrees, else 30. */
export function readRingTilt(stored: string | null): number {
  const degrees = stored === null || stored.trim() === "" ? NaN : Number(stored);
  return Number.isFinite(degrees) ? Math.min(Math.max(degrees, 0), 90) : ringTilt;
}

/**
 * `ring-think-0…2` and `ring-do-0…2`, one per dot: where it is and how bright, through one cycle. A
 * translate in % is of the dot itself, so the keyframes fit every size of well.
 */
export function ringKeyframes(tilt: number, samples = 72): string {
  const percent = (value: number) => `${+((value / ringDotDiameter) * 100).toFixed(2)}%`;
  const kinds: [string, number][] = [["think", 0], ["do", tilt]];
  return kinds.flatMap(([name, degrees]) => {
    const frames = Array.from({ length: samples + 1 }, (_, n) => ringDots((n / samples) * ringPeriod, degrees));
    return [0, 1, 2].map((index) => {
      const steps = frames.map((dots, n) => {
        const dot = dots[index]!;
        return `${+((n / samples) * 100).toFixed(3)}%{transform:translate(${percent(dot.x)},${percent(-dot.y)});` +
          `opacity:${+dot.opacity.toFixed(3)}}`;
      });
      return `@keyframes ring-${name}-${index}{${steps.join("")}}`;
    });
  }).join("\n");
}

/** The breath localStorage asks for, between 1 and 30 s, else 4 (SpinnerClock.breathPeriod(from:)). */
export function readBreathPeriod(stored: string | null): number {
  const seconds = stored === null || stored.trim() === "" ? NaN : Number(stored);
  return Number.isFinite(seconds) ? Math.min(Math.max(seconds, breathPeriodRange[0]), breathPeriodRange[1]) : breathPeriod;
}

/** How bright the waiting beacon is `time` seconds into a breath of `period`: dim, full halfway, dim. */
export function breathOpacity(time: number, period = breathPeriod): number {
  const depth = (1 - Math.cos((2 * Math.PI * time) / period)) / 2;
  return breathDimOpacity + (1 - breathDimOpacity) * depth;
}

/**
 * `breathe`, the waiting beacon's keyframes through one breath, and `.waiting-beacon`'s period: the one
 * asked for, and `reducedMotionSlowing` times longer under Reduce Motion.
 */
export function breathStyles(period: number, samples = 48): string {
  const steps = Array.from({ length: samples + 1 }, (_, n) =>
    `${+((n / samples) * 100).toFixed(3)}%{opacity:${+breathOpacity((n / samples) * period, period).toFixed(3)}}`);
  return `@keyframes breathe{${steps.join("")}}\n` +
    `.waiting-beacon{--breath-period:${+period.toFixed(3)}s}\n` +
    `@media (prefers-reduced-motion: reduce){.waiting-beacon{--breath-period:${+(period * reducedMotionSlowing).toFixed(3)}s}}`;
}

const clocked = /^(spin|ring-(think|do)-[0-2]|breathe)$/;
/** SpinnerClock's epoch, 2001-01-01, in ms since 1970. */
const epoch = 978_307_200_000;

export function startSpinnerClock(): void {
  let tilt: string | null = null;
  let breath: string | null = null;
  try {
    tilt = localStorage.getItem(ringTiltKey);
    breath = localStorage.getItem(breathPeriodKey);
  } catch { /* storage off: the defaults */ }
  // A sheet made in script, not a <style>: the page's policy takes no inline style (style-src 'self').
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(`${ringKeyframes(readRingTilt(tilt))}\n${breathStyles(readBreathPeriod(breath))}`);
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  document.addEventListener("animationstart", (event) => {
    if (!clocked.test(event.animationName) || !(event.target instanceof Element)) return;
    for (const animation of event.target.getAnimations()) {
      if (!(animation instanceof CSSAnimation) || !clocked.test(animation.animationName)) continue;
      const period = Number(animation.effect?.getTiming().duration);
      if (!(period > 0)) continue;
      // The document timeline counts from performance.timeOrigin, which is a wall-clock time.
      const since = (((performance.timeOrigin - epoch) % period) + period) % period;
      animation.startTime = -since;
    }
  });
}
