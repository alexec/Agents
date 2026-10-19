// Every working spinner turns in step (#1606), as SpinnerClock.swift keeps the window's and the
// Remote's. A CSS animation starts its turn when its element appears, so each new `spin` animation
// is set back to start on a whole second of the wall clock, as SpinnerClock's epoch is.
export function startSpinnerClock(): void {
  document.addEventListener("animationstart", (event) => {
    if (event.animationName !== "spin" || !(event.target instanceof Element)) return;
    // The document timeline counts from performance.timeOrigin, which is a wall-clock time.
    const startTime = -(performance.timeOrigin % 1000);
    for (const animation of event.target.getAnimations()) {
      if (animation instanceof CSSAnimation && animation.animationName === "spin") animation.startTime = startTime;
    }
  });
}
