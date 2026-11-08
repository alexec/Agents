// A refusal says so (071 spec edge case, T058).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const e = await load("src/model/errors.ts");
const w = e;

test("a refusal from an older control plane, or a method a host doesn't know, says so", () => {
  assert.equal(e.describe(new w.CallFailed(-32045, "agents/x is not open to this client (device).")), e.notAllowed);
  assert.equal(e.describe(new w.CallFailed(-32601, "method not found")), e.notKnown);
});

test("anything else the host says is shown as it said it", () => {
  assert.equal(e.describe(new w.CallFailed(-32005, "No such agent.")), "No such agent.");
  assert.match(e.describe(new w.LinkDown()), /isn't answering/);
  assert.match(e.describe(new w.CallTimedOut()), /took too long/);
  assert.doesNotMatch(e.describe(new w.CallTimedOut()), /isn't answering/);
});

test("an offline host says so", () => {
  assert.match(e.describe(new w.CallFailed(-32090, "host offline")), /^That machine is offline/);
});

test("a machine older than the page that refuses a call needs an update (#4096)", () => {
  e.knowVersions("0.18.0", [["box", "0.17.0"], ["same", "0.18.0"]]);
  const words = "This machine needs an update to do this. It runs Agents 0.17.0; this page is 0.18.0.";
  assert.equal(e.describe(new w.CallFailed(-32602, "Those parameters are not a ProviderCreate.", undefined, "box")), words);
  assert.equal(e.describe(new w.CallFailed(-32601, "method not found", undefined, "box")), words);
  // The same version, or the control plane, which serves the page: a real fault, as it said it.
  assert.equal(e.describe(new w.CallFailed(-32602, "Those parameters are not a ProviderCreate.", undefined, "same")),
    "Those parameters are not a ProviderCreate.");
  assert.equal(e.describe(new w.CallFailed(-32602, "Those parameters are not a ProviderCreate.", undefined, null)),
    "Those parameters are not a ProviderCreate.");
  assert.equal(e.describe(new w.CallFailed(-32005, "No such agent.", undefined, "box")), "No such agent.");
  e.knowVersions(undefined, []);
});
