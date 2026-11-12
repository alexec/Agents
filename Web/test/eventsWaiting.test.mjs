// Status ▸ Events' grey line: how many sessions wait, over every machine; none, no line.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const w = await load("src/model/eventsWaiting.ts");
const page = (waiting, events = []) => ({ events, waiting, hasMore: false });
const wait = (id) => ({ agentID: id });

test("the line counts the sessions waiting on every machine", () => {
  assert.equal(w.eventsWaitingLine({}), undefined);
  assert.equal(w.eventsWaitingLine({ a: page([]) }), undefined);
  assert.equal(w.eventsWaitingLine({ a: page([wait("1")]) }), "1 session waiting");
  assert.equal(w.eventsWaitingLine({ a: page([wait("1"), wait("2")]), b: page([wait("3"), wait("4")]) }), "4 sessions waiting");
});

test("events/changed sets the waiting list and puts a new event at the head once", () => {
  const first = w.takeEventsChange(undefined, { waiting: [wait("1")] });
  assert.deepEqual(first, { hasMore: false, waiting: [wait("1")], events: [] });
  const held = page([wait("1")], [{ position: 1 }]);
  const next = w.takeEventsChange(held, { waiting: [], event: { position: 2 } });
  assert.deepEqual(next.events.map((e) => e.position), [2, 1]);
  assert.deepEqual(next.waiting, []);
  assert.equal(w.takeEventsChange(next, { waiting: [], event: { position: 2 } }).events.length, 2);
});
