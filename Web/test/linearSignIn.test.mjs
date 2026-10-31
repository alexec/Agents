// Connect Linear (#1343): the page takes the hand-back page's message only from
// oauth.agentloops.dev, of its own type, and for its own sign-in.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");
const good = { type: "agents-oauth-callback", code: "c1", state: "s1", error: null };
const from = (origin, data) => ({ origin, data });

test("a message from another origin is ignored", () => {
  assert.equal(c.oauthCallback(from("https://evil.example", good), "f1", "s1"), undefined);
});

test("a message of another type, or with no state, is ignored", () => {
  assert.equal(c.oauthCallback(from("https://oauth.agentloops.dev", { ...good, type: "other" }), "f1"), undefined);
  assert.equal(c.oauthCallback(from("https://oauth.agentloops.dev", { ...good, state: "" }), "f1"), undefined);
});

test("a message for another sign-in is ignored", () => {
  assert.equal(c.oauthCallback(from("https://oauth.agentloops.dev", good), "f1", "s2"), undefined);
});

test("a good message gives the code, and an error gives the error", () => {
  assert.deepEqual(c.oauthCallback(from("https://oauth.agentloops.dev", good), "f1", "s1"), { flowID: "f1", state: "s1", code: "c1" });
  assert.deepEqual(c.oauthCallback(from("https://oauth.agentloops.dev", { ...good, code: null, error: "access_denied" }), "f1", "s1"),
    { flowID: "f1", state: "s1", error: "access_denied" });
});
