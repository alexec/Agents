// The editor's problem rows have a class of their own (#1667): with one `.problem` for them and the
// error banner, a warning looked like a save failure. Since #4740 a failure is a toast, with no `.problem` rule.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/app.css", import.meta.url), "utf8");
const editor = readFileSync(new URL("../src/views/files/SourceEditor.tsx", import.meta.url), "utf8");

test("no .problem rule; the editor's rows are .source-problem", () => {
  assert.equal(css.match(/^\.problem\s*\{/gm), null);
  assert.match(css, /^\.source-problem\s*\{/m);
  assert.doesNotMatch(editor, /class="problem"/);
  assert.match(editor, /class="source-problem"/);
});
