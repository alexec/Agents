// The editor's completion list has a class of its own (#1688): with the prompt's `.completions`
// for both, each list took the other's box, border and height.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/app.css", import.meta.url), "utf8");
const editor = readFileSync(new URL("../src/views/files/SourceEditor.tsx", import.meta.url), "utf8");

test("one .completions rule, the prompt's; the editor's list is .source-completions", () => {
  assert.equal(css.match(/^\.completions\s*\{/gm)?.length, 1);
  assert.match(css, /^\.source-completions\s*\{/m);
  assert.match(editor, /class="source-completions"/);
});

test("Alt+Esc asks as Ctrl+Space does, and nothing found says why (#1688)", () => {
  assert.match(editor, /e\.key === "Escape" && e\.altKey/);
  assert.match(editor, /No completions here\./);
  assert.match(editor, /Couldn't ask for completions/);
});
