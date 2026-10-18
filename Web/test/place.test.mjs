// Where the page is (#1459): on this Mac at localhost, or on the control plane's own domain.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/place.ts");

test("place: localhost and its addresses are this Mac; a domain is not (#1459)", () => {
  for (const host of ["localhost", "127.0.0.1", "[::1]"]) assert.equal(p.onThisMac(host), true, host);
  for (const host of ["agents.example.com", "agents.127.0.0.1.sslip.io", "localhost.example.com"]) {
    assert.equal(p.onThisMac(host), false, host);
  }
});
