// A Work page's images on the web (#4011): only an https source goes to forge/image, only where
// the page gives a source, and the viewer is sized and zoomed as the Mac's (#4010).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { renderMarkdown } = await load("src/render/markdown.ts");
const { forgeImageURL } = await load("src/model/forgeMarkdown.ts");
const { viewerSize, magnificationAfterWheel, viewerBar } = await load("src/model/pageImage.ts");

const images = (nodes) => [nodes].flat(Infinity).flatMap(function walk(node) {
  if (!node || typeof node !== "object") return [];
  const own = typeof node.type === "function" && node.type.name === "ForgePicture" ? [node.props] : [];
  return [...own, ...[node.props?.children ?? []].flat(Infinity).flatMap(walk)];
});
const read = async () => null;

test("only an https source is asked of forge/image", () => {
  assert.equal(forgeImageURL(" https://avatars.githubusercontent.com/u/1?s=64 "), "https://avatars.githubusercontent.com/u/1?s=64");
  assert.equal(forgeImageURL("http://example.com/a.png"), null);
  assert.equal(forgeImageURL("data:image/png;base64,AAAA"), null);
  assert.equal(forgeImageURL("cat.png"), null);
  assert.equal(forgeImageURL("javascript:alert(1)"), null);
});

test("without a forge image source, a remote image stays its words", () => {
  assert.deepEqual(images(renderMarkdown("![a cat](https://example.com/cat.png)")), []);
});

test("with one, an https image is a forge picture and anything else its words", () => {
  const got = images(renderMarkdown("![a cat](https://example.com/cat.png) ![x](http://example.com/x.png)", undefined, undefined, read));
  assert.equal(got.length, 1);
  assert.equal(got[0].url, "https://example.com/cat.png");
  assert.equal(got[0].alt, "a cat");
  assert.equal(got[0].read, read);
});

test("the viewer is as large as the image inside the window, and no smaller than 480 by 360", () => {
  assert.deepEqual(viewerSize(800, 600, 1600, 1000), { w: 800, h: 600 + viewerBar });
  assert.deepEqual(viewerSize(64, 64, 1600, 1000), { w: 480, h: 360 });
  const big = viewerSize(4000, 2000, 1600, 1000);
  assert.equal(big.w, 1360);
  assert.equal(big.h, 680 + viewerBar);
  assert.deepEqual(viewerSize(64, 64, 400, 300), { w: 400, h: 300 });
});

test("the wheel zooms in going up, a pinch counts for more, and both stay between fit and the most", () => {
  assert.ok(magnificationAfterWheel(1, 0.5, -100, false) > 1);
  assert.ok(magnificationAfterWheel(1, 0.5, 100, false) < 1);
  assert.ok(magnificationAfterWheel(1, 0.5, -10, true) > magnificationAfterWheel(1, 0.5, -10, false));
  assert.equal(magnificationAfterWheel(0.5, 0.5, 10000, false), 0.5);
  assert.equal(magnificationAfterWheel(1, 0.5, -100000, false), 8);
  assert.equal(magnificationAfterWheel(1, 0.5, NaN, false), 1);
});
