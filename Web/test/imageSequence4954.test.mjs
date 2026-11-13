// The image viewer's sequence on the web (#4954), as ImageSequence on the Mac and the Remote: a
// small image and an image that is a link do not open large, a step stops at either end, and the
// counter shows only for more than one image.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { renderMarkdown } = await load("src/render/markdown.ts");
const { opensLarge, sequenceStep, sequenceCounter, swipeStep, sequenceLeast } = await load("src/model/pageImage.ts");

const pictures = (nodes) => [nodes].flat(Infinity).flatMap(function walk(node) {
  if (!node || typeof node !== "object") return [];
  const own = typeof node.type === "function" && node.type.name === "ForgePicture" ? [node.props] : [];
  return [...own, ...[node.props?.children ?? []].flat(Infinity).flatMap(walk)];
});
const read = async () => null;

test("an image under 200 pixels on its longer side does not open large", () => {
  assert.equal(sequenceLeast, 200);
  assert.equal(opensLarge(20, 20), false);
  assert.equal(opensLarge(199, 120), false);
  assert.equal(opensLarge(200, 40), true);
  assert.equal(opensLarge(80, 900), true);
});

test("a step goes one image on or back, and there is none past either end", () => {
  assert.equal(sequenceStep(0, 3, 1), 1);
  assert.equal(sequenceStep(2, 3, -1), 1);
  assert.equal(sequenceStep(0, 3, -1), null);
  assert.equal(sequenceStep(2, 3, 1), null);
  assert.equal(sequenceStep(0, 1, 1), null);
});

test("the counter shows only when there is more than one image", () => {
  assert.equal(sequenceCounter(1, 5), "2 of 5");
  assert.equal(sequenceCounter(0, 1), null);
});

test("a swipe left goes on, a swipe right goes back, and a short or downward drag does neither", () => {
  assert.equal(swipeStep(-120, 10), 1);
  assert.equal(swipeStep(120, -10), -1);
  assert.equal(swipeStep(40, 0), null);
  assert.equal(swipeStep(100, 200), null);
});

test("an image that is a link is marked so, and does not open large", () => {
  const got = pictures(renderMarkdown("[![badge](https://example.com/b.svg)](https://example.com/ci) ![shot](https://example.com/s.png)", undefined, undefined, read));
  assert.deepEqual(got.map((p) => [p.url, p.linked]), [["https://example.com/b.svg", true], ["https://example.com/s.png", false]]);
});
