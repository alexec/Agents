// The cards at the transcript's end (the wait card, Waiting for you) keep their height under a long
// transcript (#4941): the transcript scrolls, it does not squash them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/app.css", import.meta.url), "utf8");
const chat = readFileSync(new URL("../src/views/Chat.tsx", import.meta.url), "utf8");

test("no child of the transcript shrinks", () => {
  const rule = css.match(/^\.transcript > \*\s*\{([^}]*)\}/m);
  assert.ok(rule, "a .transcript > * rule");
  assert.match(rule[1], /flex-shrink:\s*0/);
});

test("the wait card and the cards waiting for the person are in the transcript", () => {
  assert.match(chat, /class="scroll transcript"|class=\{`scroll transcript/);
  assert.match(chat, /<div class="waiting" aria-label="Waiting for you">/);
  assert.match(chat, /<WaitCard /);
});
