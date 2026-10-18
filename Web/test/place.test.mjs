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

test("place: the views' proxy is the address on this Mac, and the views name control/status says on a domain (#1484)", async () => {
  const q = await load("src/place.ts");
  globalThis.location = { hostname: "agents.example.com", port: "", search: "" };
  try {
    const waiting = q.viewsOrigin("agents.example.com");
    q.knowPublicViews("https://views.example.com");
    assert.equal(await waiting, "https://views.example.com");
    assert.equal(await q.viewsOrigin("agents.example.com"), "https://views.example.com");
    q.knowPublicViews(undefined);
    assert.equal(await q.viewsOrigin("agents.example.com"), null);
    globalThis.location.port = "8792";
    assert.equal(await q.viewsOrigin("localhost"), "http://127.0.0.1:8792");
  } finally {
    delete globalThis.location;
  }
});

test("place: the proxy hears the page at localhost on this Mac, and the https host it was given on a domain (#1484)", async () => {
  globalThis.location = { hostname: "views.example.com", port: "8792", search: "" };
  try {
    assert.equal(p.pageOrigin("127.0.0.1", ""), "http://localhost:8792");
    assert.equal(p.pageOrigin("views.example.com", "?csp=e30&host=https%3A%2F%2Fagents.example.com"), "https://agents.example.com");
    assert.equal(p.pageOrigin("views.test", "?host=https%3A%2F%2Fagents.test%3A8444"), "https://agents.test:8444");
    for (const search of ["", "?host=http%3A%2F%2Fagents.example.com", "?host=https%3A%2F%2Fa.b%2Fx", "?host=*"]) {
      assert.equal(p.pageOrigin("views.example.com", search), null, search);
    }
  } finally {
    delete globalThis.location;
  }
});
