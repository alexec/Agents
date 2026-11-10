// Settings ▸ Control plane ▸ Clients (#4253): the window's words for each code, where a browser's is pasted (#1459),
// and a QR code the Remote can scan.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/pairClients.ts");
const now = 1_000_000;

test("the three buttons are the window's", () => {
  assert.deepEqual(p.pairPurposes.map(p.pairWords.button), ["Pair a Device…", "Pair a Mac…", "Add a Browser…"]);
});

test("a device code counts down, then says it ran out", () => {
  assert.equal(p.remainingLine(now + 299_500, now), "Good for 4:59");
  assert.equal(p.remainingLine(now - 1, now), "This code has run out. Close this and pair again.");
});

test("a Mac's code says where to paste it and for how long", () => {
  assert.equal(p.codeInstructions("mac", now + 65_000, now, undefined, undefined),
    "On the other Mac, open Agents, choose Connect to a control plane and paste this. That Mac can then do all this page can. It works once, for 1:05.");
  assert.match(p.codeInstructions("mac", now, now, undefined, undefined), /It has run out; close this and ask again\.$/);
});

test("a browser's code names the page anywhere, and the page on the Mac while it is served", () => {
  const later = now + 60_000;
  const served = { port: 8792, served: true };
  assert.equal(p.codeInstructions("browser", later, now, served, undefined),
    "On this Mac, open localhost:8792 and paste it in. That browser can then do all this page can. It works once, for 1:00.");
  assert.match(p.codeInstructions("browser", later, now, served, "https://agents.example.org"),
    /^In any browser, open https:\/\/agents\.example\.org and paste it in\. On this Mac, open localhost:8792/);
  assert.match(p.codeInstructions("browser", later, now, { port: 8792, served: false, reason: "off" }, undefined),
    /^Turn on Serve Agents to browsers on this Mac in Settings ▸ Control plane first\./);
  assert.match(p.codeInstructions("browser", later, now, { port: 8792, served: false, reason: "portInUse" }, undefined),
    /^Not serving: port 8792 is in use by another app\. Press Try Again/);
});

test("the QR code is square, with a border, and its finder patterns where a scanner looks", () => {
  const { size, dark } = p.qrModules("agents-pair:abc123");
  const on = new Set(dark.map(([x, y]) => `${x},${y}`));
  // A version is 17 + 4n modules, with one of border on each side.
  assert.equal((size - 2 - 17) % 4, 0);
  assert.ok(!on.has("0,0"), "the border is light");
  for (const [x, y] of [[1, 1], [7, 1], [1, 7], [size - 2, 1], [1, size - 2]]) assert.ok(on.has(`${x},${y}`), `${x},${y} is dark`);
});
