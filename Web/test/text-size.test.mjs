// The person's text size (#750): one of three, read back safely, and put on the page's root.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const { parseTextSize, textSizes } = await load("src/model/textSize.ts");

test("three sizes, Default first, nothing smaller", () => {
  assert.deepEqual(textSizes.map((s) => s.title), ["Default", "Large", "Larger"]);
});

test("anything stored that is not a size reads back as Default", () => {
  assert.equal(parseTextSize("large"), "large");
  assert.equal(parseTextSize("larger"), "larger");
  for (const junk of [null, undefined, "", "small", "LARGE", "huge"]) assert.equal(parseTextSize(junk), "default");
});

test("every pixel font size on the page is multiplied by the one scale", () => {
  for (const sheet of ["src/app.css", "src/sidebar.css"]) {
    const css = readFileSync(new URL(`../${sheet}`, import.meta.url), "utf8");
    const pinned = [...css.matchAll(/font(?:-size)?:\s*([0-9.]+px)/g)].map((m) => m[0]);
    assert.deepEqual(pinned, [], `${sheet} pins text to a pixel size; use calc(Npx * var(--text-scale))`);
  }
  const theme = readFileSync(new URL("../src/theme/paper.css", import.meta.url), "utf8");
  assert.match(theme, /\[data-text-size="large"\]\s*\{\s*--text-scale: 1\.15;/);
  assert.match(theme, /\[data-text-size="larger"\]\s*\{\s*--text-scale: 1\.3;/);
});
