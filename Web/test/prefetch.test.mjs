// Chats fetched before they are opened (#4795; spec 4777-fast): the row under the pointer and the
// rows beside the open one, drawn at once on opening, and the host's own page still replaces it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { Store, neighbours } = await load("src/model/store.ts");

const entry = (id) => ({ id, at: 0, kind: { agentMessage: { text: id } } });

/** A link whose transcript answers say which call they are, and that can hold the next one. */
function countingLink() {
  const link = {
    calls: [],
    hold: null,
    onNotification: () => {},
    onState: () => {},
    call: async (method, params) => {
      link.calls.push([method, params?.agentID]);
      if (method === "agents/turns") return { turns: [], firstTurn: 0, openStart: 0 };
      if (method === "agents/transcript") {
        if (link.hold) await link.hold;
        return { firstIndex: 0, total: 1, entries: [entry(`${params.agentID}-${link.calls.length}`)] };
      }
      if (method === "agents/list") return [];
      throw new Error("no");
    },
  };
  return link;
}

test("neighbours: the rows either side, none for one not in the list", () => {
  assert.deepEqual(neighbours("b", ["a", "b", "c"]), ["c", "a"]);
  assert.deepEqual(neighbours("a", ["a", "b"]), ["b"]);
  assert.deepEqual(neighbours("z", ["a", "b"]), []);
});

test("a chat fetched under the pointer draws at once on opening, then its host's page replaces it", async () => {
  const link = countingLink();
  const store = new Store(link);
  await store.prefetch("mac", "s");
  assert.equal(link.calls.filter(([m]) => m === "agents/transcript").length, 1);
  // Fetched once while it is fresh.
  await store.prefetch("mac", "s");
  assert.equal(link.calls.filter(([m]) => m === "agents/transcript").length, 1);

  let release;
  link.hold = new Promise((r) => { release = r; });
  const opening = store.openSession("mac", "s");
  assert.equal(store.transcriptSource.value, "device");
  assert.match(store.entries.value[0].id, /^s-/);
  release();
  await opening;
  assert.equal(store.transcriptSource.value, "host");
});

test("the open chat is not prefetched, and one that fails holds nothing", async () => {
  const link = countingLink();
  const store = new Store(link);
  store.watch("mac", "s");
  await store.prefetch("mac", "s");
  assert.equal(link.calls.length, 0);
  link.call = async () => { throw new Error("down"); };
  await store.prefetch("mac", "t");
  await store.openSession("mac", "t");
  assert.equal(store.transcriptSource.value, "none");
});
