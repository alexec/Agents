// #176, #193: a drag on the Dashboard while a refresh is on its way neither loses nor doubles a
// tile, and the host ends with the last drop. DashboardOrderSyncTests, ported case for case.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { DashboardOrderSync } = await load("src/model/dashboardOrderSync.ts");

const key = "mac|file:///tmp/somewhere/api";
const order = (...ids) => ({ sections: [{ tiles: ids }] });
const snapshot = (o) => ({ folder: "file:///tmp/somewhere/api", tiles: [], now: 0, ...(o ? { order: o } : {}) });
const tilesOf = (o) => o.sections.flatMap((s) => s.tiles);

test("the race as the review found it: a refresh that lands during a drag does not undo it", () => {
  const sync = new DashboardOrderSync();
  let host = order("a", "b", "c");
  let shown = host;

  const early = sync.beginFetch(key);
  const earlyReply = snapshot(host);

  // First drop: shown at once and sent.
  const first = order("b", "a", "c");
  shown = first;
  assert.equal(sync.arrange(key, first), true);
  const sent = sync.takeUnsent(key);
  assert.deepEqual(sent, first);

  // Second drop while the first is out: waits, and is what goes next.
  const second = order("c", "b", "a");
  shown = second;
  assert.equal(sync.arrange(key, second), false);

  // The refresh from before either drop lands: the drops stay.
  shown = sync.accept(key, earlyReply, early)?.order ?? shown;
  assert.deepEqual(shown, second);

  // The first send lands; its dashboard/changed asks again, and the host says first.
  host = sent;
  const middle = sync.beginFetch(key);
  const middleReply = snapshot(host);

  // Then the second is sent and lands, and the send is over.
  const next = sync.takeUnsent(key);
  assert.deepEqual(next, second);
  host = next;
  assert.equal(sync.takeUnsent(key), null);

  // The fetch after the sends, and then the one from the middle, late.
  const last = sync.beginFetch(key);
  shown = sync.accept(key, snapshot(host), last)?.order ?? shown;
  assert.deepEqual(shown, second);
  assert.equal(sync.accept(key, middleReply, middle), null, "older than what is shown");
  assert.deepEqual(host, second, "the host keeps the last drop");
});

test("after the sends the host is believed again: an agent moving a tile afterwards is shown", () => {
  const sync = new DashboardOrderSync();
  sync.arrange(key, order("b", "a"));
  sync.takeUnsent(key);
  sync.takeUnsent(key);
  sync.accept(key, snapshot(order("b", "a")), sync.beginFetch(key));

  const moved = order("a", "b");
  const ticket = sync.beginFetch(key);
  assert.deepEqual(sync.accept(key, snapshot(moved), ticket)?.order, moved);
});

test("a send that failed is undone by the next fetch", () => {
  const sync = new DashboardOrderSync();
  const kept = order("a", "b");
  sync.arrange(key, order("b", "a"));
  sync.takeUnsent(key);
  // The host refused it, and nothing else was arranged.
  sync.takeUnsent(key);
  const ticket = sync.beginFetch(key);
  assert.deepEqual(sync.accept(key, snapshot(kept), ticket)?.order, kept);
});

test("each Dashboard is kept apart: one host's send does not hold another's fetch", () => {
  const sync = new DashboardOrderSync();
  sync.arrange(key, order("b", "a"));
  sync.takeUnsent(key);
  const other = "box|file:///tmp/somewhere/api";
  const theirs = order("x", "y");
  assert.deepEqual(sync.accept(other, snapshot(theirs), sync.beginFetch(other))?.order, theirs);
});

/** A seeded generator, so a failing interleaving can be run again: SplitMix64, as the Swift test's. */
function splitMix(seed) {
  let state = BigInt(seed);
  const mask = (1n << 64n) - 1n;
  return () => {
    state = (state + 0x9E3779B97F4A7C15n) & mask;
    let z = state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & mask;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & mask;
    return z ^ (z >> 31n);
  };
}
const below = (random, n) => Number(random() % BigInt(n));

// Every interleaving at once: random drops, refreshes begun, read by the host and answered in any
// order, sends landing. When it all settles, the host and the page both have the last drop, and
// every tile is on it once.
for (let seed = 0; seed < 200; seed++) {
  test(`any interleaving ends with the last drop (seed ${seed})`, () => {
    const random = splitMix(seed);
    const sync = new DashboardOrderSync();
    const tiles = ["a", "b", "c", "d", "e"];
    let host = order(...tiles);
    let shown = host;
    let lastDrop = null;
    let inFlight = null;
    const asked = [];      // fetches begun, not yet read by the host
    const replies = [];

    const show = ([ticket, reply]) => {
      const kept = sync.accept(key, reply, ticket);
      if (kept) shown = kept.order ?? shown;
    };
    const landWrite = () => {
      if (!inFlight) return;
      host = inFlight;
      asked.push(sync.beginFetch(key));                       // its dashboard/changed
      inFlight = sync.takeUnsent(key);
      if (!inFlight) asked.push(sync.beginFetch(key));        // the refresh after the sends
    };

    for (let step = 0; step < 40; step++) {
      switch (Number(random() % 5n)) {
        case 0: {
          // A drop: one tile moved somewhere else in what is shown.
          const ids = tilesOf(shown);
          const [tile] = ids.splice(below(random, ids.length), 1);
          ids.splice(below(random, ids.length + 1), 0, tile);
          const drop = order(...ids);
          shown = drop;
          lastDrop = drop;
          if (sync.arrange(key, drop)) inFlight = sync.takeUnsent(key);
          break;
        }
        case 1: asked.push(sync.beginFetch(key)); break;
        case 2: if (asked.length) replies.push([asked.shift(), snapshot(host)]); break;
        case 3: if (replies.length) show(replies.splice(below(random, replies.length), 1)[0]); break;
        default: landWrite();
      }
      assert.deepEqual([...tilesOf(shown)].sort(), tiles, "each tile once, whatever landed");
    }
    // Everything lands, in any order.
    while (inFlight) landWrite();
    for (const ticket of asked) replies.push([ticket, snapshot(host)]);
    while (replies.length) show(replies.splice(below(random, replies.length), 1)[0]);

    if (lastDrop) {
      assert.deepEqual(host, lastDrop);
      assert.deepEqual(shown, lastDrop);
    }
    assert.deepEqual([...tilesOf(shown)].sort(), tiles);
  });
}
