import assert from "node:assert/strict";
import { test } from "node:test";
import { load } from "./load.mjs";

const later = await load("src/model/later.ts");
const dates = await load("src/protocol/dates.ts");

const at = (d) => dates.toWireDate(d);

test("Later's choices are the window's, in its order (#4236)", () => {
  assert.deepEqual(later.laters.map((c) => later.laterWords[c]),
    ["Later in 1 Hour", "Later in 4 Hours", "Later in 8 Hours", "Later in 1 Day", "Later at My Mac"]);
});

test("a timed choice defers to hours from now, At My Mac to the Mac (#4236)", () => {
  const now = new Date(2026, 10, 10, 9, 0);
  assert.deepEqual(later.deferParams("r", "hour", now), { id: "r", until: at(new Date(2026, 10, 10, 10, 0)) });
  assert.deepEqual(later.deferParams("r", "day", now), { id: "r", until: at(new Date(2026, 10, 11, 9, 0)) });
  assert.deepEqual(later.deferParams("r", "atMac", now), { id: "r", atMac: true });
});

test("a row in Later says when it comes back (#4236)", () => {
  const now = new Date(2026, 10, 10, 9, 0);
  const time = (d) => d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  const evening = new Date(2026, 10, 10, 18, 0);
  assert.equal(later.backWords({ until: at(evening), at: at(now) }, now, "en-GB"), `Back at ${time(evening)}`);
  const morning = new Date(2026, 10, 11, 9, 0);
  assert.equal(later.backWords({ until: at(morning), at: at(now) }, now, "en-GB"), `Back tomorrow at ${time(morning)}`);
  assert.match(later.backWords({ until: at(new Date(2026, 10, 13, 9, 0)), at: at(now) }, now, "en-GB"), /^Back on .+ at /);
  assert.equal(later.backWords({ atMac: true, at: at(now) }, now, "en-GB"), "At my Mac");
  assert.equal(later.backWords({ until: at(evening), atMac: true, at: at(now) }, now, "en-GB"), `Back at ${time(evening)} or at my Mac`);
});

test("Later lists the soonest back first, At my Mac alone last", () => {
  const r = (id, until, askedAt) => ({ id, askedAt, deferred: { until, at: 0 } });
  const rows = [r("mac", undefined, 1), r("late", 200, 2), r("soon", 100, 3)].sort(later.byBack);
  assert.deepEqual(rows.map((x) => x.id), ["soon", "late", "mac"]);
  assert.equal(later.isDeferred({ deferred: undefined }), false);
  assert.equal(later.isDeferred({ deferred: { at: 0 } }), true);
});
