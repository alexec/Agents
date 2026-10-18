// The page's text zoom (#1419), as PageZoomTests has it on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const z = await load("src/model/pageZoom.ts");
const press = (key, more = {}) => ({ key, metaKey: true, ctrlKey: false, altKey: false, ...more });

test("zoom in and out go one step and stop at the ends", () => {
  assert.equal(z.larger(1), 1.1);
  assert.equal(z.larger(2), 2);
  assert.equal(z.smaller(1), 0.9);
  assert.equal(z.smaller(0.75), 0.75);
});

test("a level that is not a step snaps to the nearest", () => {
  assert.equal(z.snapped(1.3), 1.25);
  assert.equal(z.snapped(9), 2);
  assert.equal(z.snapped(Number.NaN), 1);
  assert.equal(z.larger(1.3), 1.5);
});

test("the zoom keys, with Command or Control", () => {
  assert.equal(z.zoomForKey(1, press("=")), 1.1);
  assert.equal(z.zoomForKey(1, press("+")), 1.1);
  assert.equal(z.zoomForKey(1, press("-")), 0.9);
  assert.equal(z.zoomForKey(1.5, press("0")), 1);
  assert.equal(z.zoomForKey(1, press("=", { metaKey: false, ctrlKey: true })), 1.1);
  assert.equal(z.zoomForKey(1, press("=", { metaKey: false })), null);
  assert.equal(z.zoomForKey(1, press("=", { altKey: true })), null);
  assert.equal(z.zoomForKey(1, press("p")), null);
});
