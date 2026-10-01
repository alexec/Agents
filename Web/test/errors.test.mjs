// A refusal by grant says so (071 spec edge case, T058).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const e = await load("src/model/errors.ts");
const w = e;

test("a grant refusal, by either code, says the grant", () => {
  assert.equal(e.describe(new w.CallFailed(-32045, "agents/x is not open to this client (device).")), e.notAllowedByGrant);
  assert.equal(e.describe(new w.CallFailed(-32601, "method not found")), e.notAllowedByGrant);
});

test("anything else the host says is shown as it said it", () => {
  assert.equal(e.describe(new w.CallFailed(-32005, "No such agent.")), "No such agent.");
  assert.match(e.describe(new w.LinkDown()), /isn't answering/);
});
