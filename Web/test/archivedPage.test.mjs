// The Archived Sessions and Archived Workflows pages' words (#4451), as AgentsKit's ArchivedPageTests.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const page = await load("src/model/archivedPage.ts");
const dates = await load("src/protocol/dates.ts");

const agent = (id, at, extra = {}) => ({ id, lastActivityAt: dates.toWireDate(at), ...extra });

test("the state: never none before the host has said (#664)", () => {
  assert.deepEqual(page.archivedState(0, false, undefined, false), { kind: "loading" });
  assert.deepEqual(page.archivedState(0, false, true, false), { kind: "empty" });
  assert.deepEqual(page.archivedState(0, true, true, false), { kind: "noMatch" });
  assert.deepEqual(page.archivedState(0, false, false, false), { kind: "hostSilent" });
  assert.deepEqual(page.archivedState(0, false, undefined, true), { kind: "hostSilent" });
  assert.deepEqual(page.archivedState(3, false, true, false), { kind: "rows", stale: false });
  assert.deepEqual(page.archivedState(3, false, true, true), { kind: "rows", stale: true }, "what was last read, dimmed");
});

test("the footer and Load more", () => {
  assert.equal(page.footer(50, 128), "50 of 128 archived sessions");
  assert.equal(page.footer(128, 128), "128 archived sessions");
  assert.equal(page.footer(1, 1), "1 archived session");
  assert.equal(page.hasMore(50, 128), true);
  assert.equal(page.hasMore(128, 128), false);
  assert.equal(page.nextLimit(50), 100);
  assert.equal(page.workflowCount(1), "1 archived workflow");
  assert.equal(page.workflowCount(4), "4 archived workflows");
});

test("days: Today, Yesterday, then the day, in the host's order", () => {
  const now = new Date(2026, 10, 10, 15, 0);
  const rows = [
    agent("a", new Date(2026, 10, 10, 13, 0), { archivedAt: dates.toWireDate(new Date(2026, 10, 10, 13, 0)) }),
    agent("b", new Date(2026, 10, 9, 18, 40)),
    agent("c", new Date(2026, 10, 7, 16, 12)),
    agent("d", new Date(2025, 11, 31, 9, 5)),
  ];
  const days = page.days(rows, now);
  assert.deepEqual(days.map((d) => [d.title, d.agents.map((a) => a.id)]),
    [["Today", ["a"]], ["Yesterday", ["b"]], ["Saturday 7 November", ["c"]], ["Wednesday 31 December 2025", ["d"]]]);
  assert.equal(days[0].isToday, true);
  assert.equal(days[1].isToday, false);
});

test("a row's time: ago today, the clock time before", () => {
  const now = new Date(2026, 10, 10, 15, 0);
  assert.equal(page.archivedTime(new Date(2026, 10, 10, 14, 59, 40), now), "now");
  assert.equal(page.archivedTime(new Date(2026, 10, 10, 14, 48), now), "12 min ago");
  assert.equal(page.archivedTime(new Date(2026, 10, 10, 13, 0), now), "2 h ago");
  assert.equal(page.archivedTime(new Date(2026, 10, 9, 18, 40), now), "18:40");
  assert.equal(page.archivedTime(new Date(2026, 10, 7, 9, 5), now), "09:05");
});
