// The session list's single keys (#4796), the same cases as the window's ListKeyTests.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const k = await load("src/model/listKeys.ts");
const press = (key, more = {}) => ({ key, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...more });

test("the keys are the letters with no modifier, outside a field", () => {
  assert.equal(k.listKeyOf(press("j"), false), "next");
  assert.equal(k.listKeyOf(press("k"), false), "previous");
  assert.equal(k.listKeyOf(press("e"), false), "archive");
  assert.equal(k.listKeyOf(press("l"), false), "later");
  assert.equal(k.listKeyOf(press("r"), false), "rename");
  assert.equal(k.listKeyOf(press("e"), true), undefined);
  assert.equal(k.listKeyOf(press("e", { metaKey: true }), false), undefined);
  assert.equal(k.listKeyOf(press("E", { shiftKey: true }), false), undefined);
  assert.equal(k.listKeyOf(press("e", { isComposing: true }), false), undefined);
  assert.equal(k.listKeyOf(press("x"), false), undefined);
  assert.equal(k.listKeyOf(press("toString"), false), undefined);
  assert.equal(k.listKeyGlyph.archive, "E");
});

test("j and k stop at the ends", () => {
  const ids = ["a", "b", "c"];
  assert.equal(k.stepFrom("a", ids, true), "b");
  assert.equal(k.stepFrom("c", ids, true), undefined);
  assert.equal(k.stepFrom("b", ids, false), "a");
  assert.equal(k.stepFrom("a", ids, false), undefined);
  assert.equal(k.stepFrom(undefined, ids, true), "a");
  assert.equal(k.stepFrom("z", ids, false), "c");
  assert.equal(k.stepFrom(undefined, [], true), undefined);
});

test("archive opens the next, or the one before at the end", () => {
  const ids = ["a", "b", "c"];
  assert.equal(k.afterArchiving("a", ids), "b");
  assert.equal(k.afterArchiving("c", ids), "b");
  assert.equal(k.afterArchiving("a", ["a"]), undefined);
  assert.equal(k.afterArchiving("z", ids), undefined);
});
