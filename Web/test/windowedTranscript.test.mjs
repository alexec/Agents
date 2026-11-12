// The transcript is windowed (#4789), as the Mac's TranscriptStack: the browser lays out and paints only
// the turns near the view, and a turn drawn once keeps its height when it leaves it. Every turn stays in
// the page, so Find, a jump to an entry and the held turn (Chat.tsx, #2310) still find it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/app.css", import.meta.url), "utf8");
const rows = readFileSync(new URL("../src/views/chat/Rows.tsx", import.meta.url), "utf8");

test("each turn of the transcript is drawn only near the view, and keeps the height it was drawn at", () => {
  const rule = css.match(/^\.transcript > \.turn\s*\{([^}]*)\}/m);
  assert.ok(rule, "a .transcript > .turn rule");
  assert.match(rule[1], /content-visibility:\s*auto/);
  assert.match(rule[1], /contain-intrinsic-block-size:\s*auto \d+px/);
});

test("a turn is a child of the transcript, so the rule reaches it", () => {
  assert.match(rows, /<article class="turn"/);
});
