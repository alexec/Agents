// The editor's problem rows and the red error banner each have a class of their own (#1667):
// with one `.problem` for both, a warning looked like a save failure and a banner like a button.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/app.css", import.meta.url), "utf8");
const editor = readFileSync(new URL("../src/views/files/SourceEditor.tsx", import.meta.url), "utf8");

test("one .problem rule, the banner's; the editor's rows are .source-problem", () => {
  assert.equal(css.match(/^\.problem\s*\{/gm)?.length, 1);
  assert.match(css, /^\.source-problem\s*\{/m);
  assert.doesNotMatch(editor, /class="problem"/);
  assert.match(editor, /class="source-problem"/);
});
