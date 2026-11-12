// What the page says when it can't reach the control plane (#4916): "this Mac" only when the
// page is the one on this Mac, at localhost; elsewhere, the control plane by its address.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

delete globalThis.BroadcastChannel;
const s = await load("src/session.ts");

test("controlPlaneReach: at localhost the words name this Mac (#4916)", () => {
  assert.equal(s.unreachableWords("localhost"), s.pairingWords.unreachable);
  assert.match(s.unreachableWords("127.0.0.1"), /this Mac/);
  assert.equal(s.notAnsweringWords("This browser is still paired.", "localhost"),
    "Your Mac is not answering. This browser is still paired.");
});

test("controlPlaneReach: elsewhere the words name the control plane and its address (#4916)", () => {
  const words = s.unreachableWords("control.example.com");
  assert.match(words, /control plane at control\.example\.com/);
  assert.doesNotMatch(words, /Mac/);
  assert.equal(s.notAnsweringWords("This browser is still paired.", "control.example.com"),
    "The control plane is not answering. This browser is still paired.");
});
