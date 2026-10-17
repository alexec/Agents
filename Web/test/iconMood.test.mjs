// The favicon's mood (#1317), as IconMoodTests holds the Dock tile's.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { iconMood, faviconFor } = await load("src/model/iconMood.ts");

test("nothing running is asleep", () => {
  assert.equal(iconMood([]), "asleep");
  assert.equal(iconMood([{ needsYou: false, working: false }]), "asleep");
});

test("a working agent is happy", () => {
  assert.equal(iconMood([{ needsYou: false, working: false }, { needsYou: false, working: true }]), "happy");
});

test("a waiting question wins over work", () => {
  assert.equal(iconMood([{ needsYou: false, working: true }, { needsYou: true, working: false }]), "quizzical");
});

test("happy is the bundle's favicon", () => {
  assert.equal(faviconFor.happy, "/assets/favicon.png");
});
