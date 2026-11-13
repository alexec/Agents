// The message kinds (docs/reference/design-system.md, "Messages"; #4740): tones, toast times and alerts,
// and that the page asks with its own <dialog>, never window.confirm, and draws no red strip.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { load } from "./load.mjs";

const m = await load("src/model/messageKinds.ts");

test("a failure is an alert to a screen reader; the other tones are a status", () => {
  assert.equal(m.toneRole("failure"), "alert");
  for (const tone of ["neutral", "attention", "warning", "success"]) assert.equal(m.toneRole(tone), "status");
});

test("each tone has its own icon, so it is never colour alone", () => {
  assert.equal(new Set(Object.values(m.toneGlyph)).size, 5);
});

test("a success goes after 4 s, one with Undo after 8 s, a failure stays", () => {
  assert.equal(m.toastMillis("success", false), 4000);
  assert.equal(m.toastMillis("success", true), 8000);
  assert.equal(m.toastMillis("failure", false), null);
  assert.equal(m.toastMillis("failure", true), null);
});

test("an alert's title ends at the blank line, else at the first question mark", () => {
  assert.deepEqual(m.alertParts("Delete it?\n\nIt goes for good."), { title: "Delete it?", detail: "It goes for good." });
  assert.deepEqual(m.alertParts("Remove Acme? Its keys go."), { title: "Remove Acme?", detail: "Its keys go." });
  assert.deepEqual(m.alertParts("Delete notes.md?"), { title: "Delete notes.md?", detail: null });
  assert.deepEqual(m.alertParts("Your edits will be lost."), { title: "Your edits will be lost.", detail: null });
});

test("an alert's button is its question's verb, destructive for one that takes away", () => {
  assert.deepEqual(m.alertButton("Remove Acme?"), { label: "Remove", destructive: true });
  assert.deepEqual(m.alertButton("Shut down iPhone 17?"), { label: "Shut Down", destructive: true });
  assert.deepEqual(m.alertButton("Move coder.md to the Trash?"), { label: "Move to Trash", destructive: true });
  assert.deepEqual(m.alertButton("Restore this backup?"), { label: "Restore", destructive: false });
  assert.deepEqual(m.alertButton("Your edits will be lost."), { label: "Continue", destructive: false });
});

const src = fileURLToPath(new URL("../src", import.meta.url));
const files = (dir) => readdirSync(dir).flatMap((n) => {
  const p = join(dir, n);
  return statSync(p).isDirectory() ? files(p) : /\.tsx?$/.test(n) ? [p] : [];
});

test("the page asks with its own alert, never window.confirm", () => {
  const found = files(src).filter((p) => /(?<![\w.])(?:window\.)?confirm\(/.test(readFileSync(p, "utf8")));
  assert.deepEqual(found, []);
});

test("no message is a .hint with role=alert, a red .problem strip or an amber wash", () => {
  const found = files(src).filter((p) => /class="hint[^"]*" role="alert"|class="problem[ "]|class="offline-strip|class="work-error/.test(readFileSync(p, "utf8")));
  assert.deepEqual(found, []);
  const css = readFileSync(join(src, "app.css"), "utf8");
  assert.doesNotMatch(css, /^\.problem\s*\{/m);
  assert.doesNotMatch(css, /--tint-success|--danger/);
});
