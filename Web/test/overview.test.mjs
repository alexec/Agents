// The Overview's words (#2141): what each card says.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const o = await load("src/model/overview.ts");

const host = (id, name = id) => ({ id, name, platform: "macOS", version: "0.14.0", state: "online", reach: "dialOut" });
const folder = (path, name, archivedAt) => ({ name, folder: { folder: path, archivedAt } });
const agent = (id, state, createdAt) => ({ id, state, createdAt, labels: [] });

test("every live session in every folder not put away, and those working or needing you", () => {
  const hosts = [host("mac", "Bea's Mac"), host("box", "build-01")];
  const folders = { mac: [folder("file:///api", "api"), folder("file:///old", "old", 5)], box: [folder("file:///web", "web")] };
  const sessions = { "mac|file:///api": [agent("A", "running", 1), agent("B", "finished", 2)], "mac|file:///old": [agent("Z", "running", 9)],
    "box|file:///web": [agent("C", "running", 3)] };
  const placed = o.placedSessions(hosts, folders, (h, f) => sessions[`${h}|${f}`] ?? []);
  assert.deepEqual(placed.map((p) => p.agent.id), ["A", "B", "C"], "not the folder put away");
  const working = o.workingNow(placed);
  assert.deepEqual(working.map((p) => p.agent.id), ["C", "A"], "newest started first");
  assert.equal(o.workingWords(working), "2 agents on 2 machines");
  assert.equal(o.workingWords(working.slice(0, 1)), "1 agent on 1 machine");
  assert.equal(o.workingWords([]), o.nothingRuns);
  assert.equal(o.placeWords(working[0], true), "build-01: web");
  assert.equal(o.placeWords(working[0], false), "web");
});

test("what waits: sessions and, for an admin, requests", () => {
  assert.equal(o.waitingWords(2, 3), "2 sessions · 3 requests");
  assert.equal(o.waitingWords(1, null), "1 session");
  assert.equal(o.waitingWords(0, 1), "1 request");
  assert.equal(o.waitingWords(0, 0), o.nothingWaits);
});

test("a day's report added up by currency", () => {
  assert.deepEqual(o.rowsCost([{ cost: { USD: 1.5 } }, { cost: { USD: 2, EUR: 1 } }]), { USD: 3.5, EUR: 1 });
  assert.deepEqual(o.rowsCost([]), {});
});
