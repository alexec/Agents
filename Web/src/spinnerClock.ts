// Every working mark of a kind turns in step (#1606, #2044), as SpinnerClock.swift keeps the
// window's and the Remote's. A CSS animation starts when its element appears, so each new `spin`,
// `dots` or `cog` animation is set back to start on a whole period of the wall clock, as
// SpinnerClock's epoch is (2001 and 1970 are a whole number of 1.2 s and 2 s apart). A dot's own
// delay stays on top, so the three still fade up in turn.
const clocked = new Set(["spin", "dots", "cog"]);

export function startSpinnerClock(): void {
  document.addEventListener("animationstart", (event) => {
    if (!clocked.has(event.animationName) || !(event.target instanceof Element)) return;
    for (const animation of event.target.getAnimations()) {
      if (!(animation instanceof CSSAnimation) || !clocked.has(animation.animationName)) continue;
      const period = Number(animation.effect?.getTiming().duration);
      if (!(period > 0)) continue;
      // The document timeline counts from performance.timeOrigin, which is a wall-clock time.
      animation.startTime = -(performance.timeOrigin % period);
    }
  });
}
