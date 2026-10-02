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
