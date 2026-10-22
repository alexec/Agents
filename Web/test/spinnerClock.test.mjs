// The working ring (#2332): the same maths as SpinnerClock.ringDots in Swift, and the keyframes
// the page draws from it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const clock = await load("src/spinnerClock.ts");
const near = (a, b, why) => assert.ok(Math.abs(a - b) < 1e-9, `${why}: ${a} is not ${b}`);

test("at rest the ring is #2044's three dots: a line 0.34 apart, the middle one bright", () => {
  const dots = clock.ringDots(0, 0);
  near(dots[0].x, -0.34, "left"); near(dots[1].x, 0, "middle"); near(dots[2].x, 0.34, "right");
  for (const dot of dots) near(dot.y, 0, "on the line");
  near(dots[1].opacity, 1, "front");
});

test("a dot is bright at the front, 0.3 at the back, and rises with the tilt", () => {
  near(clock.ringDot(-Math.PI / 2, 0).opacity, 0.3, "back");
  const tipped = clock.ringDot(Math.PI / 2, Math.PI / 6);
  near(tipped.y, clock.ringRadius / 2, "risen by r·sin 30°");
  near(tipped.opacity, 0.3 + 0.7 * (Math.cos(Math.PI / 6) + 1) / 2, "dimmed by the cosine");
});

test("thinking stays on the line; a tool tips it up, then down", () => {
  for (let n = 0; n < 36; n++) for (const dot of clock.ringDots((n / 36) * 3.6, 0)) near(dot.y, 0, "flat");
  assert.ok(clock.ringDots(0, 30)[1].y > 0);
  assert.ok(clock.ringDots(1.8, 30)[1].y < 0);
  assert.ok(clock.ringDots(0.05, 0)[1].x > 0, "the front goes left to right");
});

test("the tilt comes from localStorage, between 0 and 90, else 30", () => {
  assert.equal(clock.readRingTilt(null), 30);
  assert.equal(clock.readRingTilt(""), 30);
  assert.equal(clock.readRingTilt("abc"), 30);
  assert.equal(clock.readRingTilt("45"), 45);
  assert.equal(clock.readRingTilt("120"), 90);
  assert.equal(clock.readRingTilt("-5"), 0);
});

test("six keyframes, one per dot and activity, that start on the line", () => {
  const css = clock.ringKeyframes(30, 12);
  for (const name of ["think", "do"]) for (const i of [0, 1, 2]) assert.match(css, new RegExp(`@keyframes ring-${name}-${i}\\{`));
  assert.match(css, /@keyframes ring-think-1\{0%\{transform:translate\(0%,0%\);opacity:1\}/);
  assert.match(css, /@keyframes ring-think-0\{0%\{transform:translate\(-141\.67%,0%\);opacity:0\.475\}/);
});
