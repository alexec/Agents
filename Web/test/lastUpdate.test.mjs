// The "Last update" line (#5141), as AgentsKit's LastUpdateTests says it for the Mac and the Remote.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/lastUpdate.ts");
const now = new Date(2026, 10, 13, 15, 30).getTime();
const ago = (s) => m.lastUpdateLine(now - s * 1000, now, "en-GB");

test("the words", () => {
  assert.equal(ago(0), "Last update just now");
  assert.equal(ago(59), "Last update just now");
  assert.equal(ago(-30), "Last update just now", "a read ahead of this clock");
  assert.equal(ago(60), "Last update 1 min ago");
  assert.equal(ago(5 * 60 + 20), "Last update 5 min ago");
  assert.equal(ago(59 * 60), "Last update 59 min ago");
  assert.equal(ago(3600), "Last update 1 h ago");
  assert.equal(ago(23 * 3600 + 59 * 60), "Last update 23 h ago");
  assert.equal(ago(24 * 3600), "Last update yesterday");
  assert.equal(m.lastUpdateLine(new Date(2026, 10, 3, 15, 30).getTime(), now, "en-GB"), "Last update 3 Nov");
  assert.equal(m.lastUpdateLine(new Date(2025, 9, 9, 15, 30).getTime(), now, "en-GB"), "Last update 9 Oct 2025");
});

test("spoken", () => {
  const say = (s) => m.lastUpdateSpoken(now - s * 1000, now, "en-GB");
  assert.equal(say(5), "Last update just now");
  assert.equal(say(60), "Last update 1 minute ago");
  assert.equal(say(5 * 60), "Last update 5 minutes ago");
  assert.equal(say(3600), "Last update 1 hour ago");
  assert.equal(say(2 * 3600), "Last update 2 hours ago");
});

test("it ticks every 10 s, then each minute", () => {
  assert.equal(m.nextChange(now, now), now + 10_000);
  assert.equal(m.nextChange(now, now + 15_000), now + 20_000);
  assert.equal(m.nextChange(now, now + 60_000), now + 120_000);
  assert.equal(m.nextChange(now, now + 130_000), now + 180_000);
});

test("the time of the page's read", () => {
  assert.equal(m.pageReadAt({ kind: "open" }, 5), undefined, "live: no line");
  assert.equal(m.pageReadAt({ kind: "down", heardAt: 9 }, 5), 9, "the last word on the link");
  assert.equal(m.pageReadAt({ kind: "down" }, 5), 5, "never heard: the copy");
  assert.equal(m.pageReadAt({ kind: "connecting" }, 5), 5);
  assert.equal(m.pageReadAt({ kind: "loading" }, undefined), undefined);
});

test("a usage page says its oldest read (#5144)", () => {
  const reads = { mac: { cost: 300, usage: 200 }, server: { cost: 100 } };
  assert.equal(m.oldestRead(reads, ["mac", "server"], ["cost", "usage"]), 100);
  assert.equal(m.oldestRead(reads, ["mac"], ["cost", "usage"]), 200);
  assert.equal(m.oldestRead(reads, ["mac"], ["time"]), undefined, "nothing read yet");
  assert.equal(m.oldestRead(reads, ["gone"], ["cost"]), undefined);
});
