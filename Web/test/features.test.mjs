// Reports ▸ Features' words and sums (#2165), as FeatureUsageTests has them on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const f = await load("src/model/features.ts");

test("hosts are added up, the least used first", () => {
  const mac = { days: 90, since: "2026-09-01", features: [
    { method: "workflows/run", week: 0, quarter: 0, clients: [] },
    { method: "sessions/start", week: 2, quarter: 5, clients: ["mac"], lastUsed: "2026-10-29" },
  ] };
  const server = { days: 90, since: "2026-08-15", features: [
    { method: "sessions/start", week: 1, quarter: 1, clients: ["agent", "mac"], lastUsed: "2026-10-30" },
    { method: "files/read", week: 1, quarter: 2, clients: ["web"], lastUsed: "2026-10-01" },
  ] };
  const all = f.mergeFeatures([mac, server]);
  assert.equal(all.since, "2026-08-15");
  assert.deepEqual(all.features.map((x) => x.method), ["workflows/run", "files/read", "sessions/start"]);
  assert.deepEqual(all.features[2], { method: "sessions/start", week: 3, quarter: 6, clients: ["agent", "mac"], lastUsed: "2026-10-30" });
});

test("a line says the uses and the clients, as the window says it", () => {
  assert.equal(f.featureLine({ method: "m", week: 7, quarter: 30, clients: ["mac", "web"] }, 90), "7 this week · 30 in 90 days · mac, web");
  assert.equal(f.featureLine({ method: "m", week: 0, quarter: 0, clients: [] }, 90), "0 this week · 0 in 90 days");
});
