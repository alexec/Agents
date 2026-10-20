// This Mac's host notice on the page (#666): the window's cases and words (MacHostNotice.swift).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const at = "2026-10-11T00:00:00Z";

test("why this Mac's host is quiet is told apart as the window tells it", async () => {
  const { decideMacHostNotice: decide } = await load("src/model/macHostNotice.ts");
  assert.deepEqual(decide(true, "offline", undefined), { kind: "notRunning" }, "beside this Mac, no join is the process down");
  assert.deepEqual(decide(true, "connecting", undefined), { kind: "notRunning" });
  assert.equal(decide(true, "online", undefined), null);
  assert.deepEqual(decide(true, "offline", { member: false, connected: false, at }), { kind: "notJoined", problem: undefined });
  assert.deepEqual(decide(true, "offline", { member: true, connected: false, problem: "refused", at }), { kind: "uplinkFailing", problem: "refused" });
  assert.deepEqual(decide(true, "offline", { member: true, connected: false, at }), { kind: "notAnswering" });
  assert.deepEqual(decide(true, "offline", { member: true, connected: true, at }), { kind: "notAnswering" });
  assert.equal(decide(true, "online", { member: true, connected: true, at }), null);
  assert.deepEqual(decide(false, "offline", undefined), { kind: "notAnswering" }, "elsewhere, a missing join is not the process down");
  assert.equal(decide(false, undefined, undefined), null);
});

test("this Mac's host needing an update is up, not down (#1771)", async () => {
  const { decideMacHostNotice: decide } = await load("src/model/macHostNotice.ts");
  assert.equal(decide(true, "needsUpdate", undefined), null);
  assert.equal(decide(true, "needsUpdate", { member: true, connected: true, at }), null);
  assert.equal(decide(false, "needsUpdate", undefined), null);
});

test("not running and not joined say to open Agents Host", async () => {
  const { macHostNoticeTitle: title, macHostNoticeDetail: detail } = await load("src/model/macHostNotice.ts");
  assert.equal(title({ kind: "notRunning" }), "This Mac’s host isn’t running");
  assert.match(detail({ kind: "notRunning" }), /^Open Agents Host\./);
  assert.equal(title({ kind: "notJoined" }), "This Mac’s host hasn’t joined");
  assert.equal(detail({ kind: "notJoined", problem: "the code expired" }),
    "It’s running, and it has no membership. The code expired. Open Agents Host and press Try Again there.");
  assert.match(detail({ kind: "notAnswering" }), /trying again by itself/);
});
