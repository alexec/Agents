// Open in Browser's code in the address (#109): taken once, and gone from the address before
// anything else can read it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

/** Loads pairLink.ts as a page at `hash` would, and says what it took and what it left. */
async function open(hash) {
  const replaced = [];
  globalThis.location = { hash, pathname: "/", search: "" };
  globalThis.history = { replaceState: (_state, _title, url) => replaced.push(url) };
  try {
    const { linkedCode } = await load("src/pairLink.ts");
    return { linkedCode, replaced };
  } finally {
    delete globalThis.location;
    delete globalThis.history;
  }
}

const text = "agents-control:2:c:operator:AAAA:BBBB:http%3A%2F%2Flocalhost%3A8792:-:Alex%27s%20control%20plane";

test("a code in the fragment is taken, and the address replaced without it", async () => {
  const { linkedCode, replaced } = await open("#code=" + encodeURIComponent(text));
  assert.equal(linkedCode, text);
  assert.deepEqual(replaced, ["/"]);
});

// A code as `agents-control code` prints it: a 65-byte key and a 32-byte secret, so it parses.
const b64 = (bytes) => Buffer.from(bytes).toString("base64url");
const printed = ["agents-control", "2", "c", "-", b64([4, ...new Array(64).fill(1)]), b64(new Array(32).fill(2)),
  "https%3A%2F%2Fmac.local%3A8790", "PIN", "Alex%E2%80%99s%20Mac"].join(":");

test("a code put in the fragment as it is printed, not escaped, is taken as it is (#4129)", async () => {
  const { linkedCode, replaced } = await open("#code=" + printed);
  assert.equal(linkedCode, printed);
  assert.deepEqual(replaced, ["/"]);
});

test("the same code, escaped, is taken decoded", async () => {
  const { linkedCode } = await open("#code=" + encodeURIComponent(printed));
  assert.equal(linkedCode, printed);
});

test("a route, or no fragment at all, is left alone", async () => {
  for (const hash of ["", "#/h/mac/p/x", "#/", "#code="]) {
    const { linkedCode, replaced } = await open(hash);
    assert.equal(linkedCode, null, hash);
    assert.deepEqual(replaced, [], hash);
  }
});

test("a fragment that doesn't decode is still taken out of the address", async () => {
  const { linkedCode, replaced } = await open("#code=%E0%A4%A");
  assert.equal(linkedCode, null);
  assert.deepEqual(replaced, ["/"]);
});

test("an org provider's return is taken, and the address replaced without it (#1002)", async () => {
  const replaced = [];
  globalThis.location = { hash: "#oidc-ticket=T1", pathname: "/", search: "" };
  globalThis.history = { replaceState: (_state, _title, url) => replaced.push(url) };
  try {
    const { linkedCode, oidcBack } = await load("src/pairLink.ts");
    assert.equal(linkedCode, null);
    assert.deepEqual(oidcBack, { ticket: "T1" });
    assert.deepEqual(replaced, ["/"]);
  } finally {
    delete globalThis.location;
    delete globalThis.history;
  }
});
