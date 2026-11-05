// Settings ▸ Browser (#3535): the web page's section says what the window's BrowserSettingsView says,
// in the same words, and shows the sites, the download and why there are none.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
const m = await load("src/model/browserSettings.ts");
const swift = read("Packages/AgentsKit/Sources/AgentsKitCore/Model/BrowserSettings.swift");

test("every word is the window's", () => {
  // Swift's literals, with its "+" joins and its escaped ellipsis taken away.
  const flat = swift.replace(/"\s*\n\s*\+ "/g, "").replace(/\\u\{2026\}/g, "…");
  for (const [key, words] of Object.entries(m.browserWords)) {
    assert.ok(flat.includes(`static let ${key} = "${words}"`), `${key}: ${words}`);
  }
});

test("before the download it says so, and the size says there is none", () => {
  const state = { installed: false, running: false, downloadBytes: 0, sites: [] };
  assert.equal(m.sitesNote(state), m.browserWords.notDownloaded);
  assert.equal(m.downloadWords(state), "Not downloaded");
});

test("after it, the sites, or why there are none", () => {
  const state = { installed: true, running: true, downloadBytes: 182_400_000, sites: [{ site: "github.com", cookies: 3 }] };
  assert.equal(m.sitesNote(state), null);
  assert.equal(m.downloadWords(state), "182 MB");
  assert.equal(m.sitesNote({ ...state, sites: [] }), "No sites yet.");
  assert.equal(m.sitesNote({ ...state, sites: [], problem: "The sites could not be read: x" }), "The sites could not be read: x");
  assert.equal(m.cookiesWords(1), "1 cookie");
  assert.equal(m.cookiesWords(3), "3 cookies");
});
