// Settings ▸ Agent Runtimes ▸ Auto while its cells load (#2894): a failed load says why, so the page
// can show it with Try again, and the page's draws while one is on the way ask only once.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { Store, CallFailed } = await load("test/tokenAsk.ts");

const mappings = { cells: [], choices: [] };

/** A link whose `auto/mappings` fails while `failing` is true, and that counts what it was asked. */
function autoLink() {
  const link = {
    failing: true,
    asked: 0,
    onNotification: () => {},
    onState: () => {},
    call: async (method) => {
      if (method === "auto/state") return { order: [], excluded: [], overrides: [] };
      if (method === "auto/mappings") {
        link.asked += 1;
        if (link.failing) throw new CallFailed(-32000, "The host could not read Auto's cells.");
        return mappings;
      }
      throw new Error("no");
    },
  };
  return link;
}

test("a failed load keeps why, and Try again clears it when the cells come", async () => {
  const link = autoLink();
  const store = new Store(link);
  await store.loadAuto("mac");
  assert.equal(store.autoMappings.value.mac, undefined);
  assert.match(store.autoProblems.value.mac, /could not read Auto's cells/);
  link.failing = false;
  await store.loadAuto("mac");
  assert.deepEqual(store.autoMappings.value.mac, mappings);
  assert.equal(store.autoProblems.value.mac, undefined);
});

test("draws while a load is on the way ask once", async () => {
  const link = autoLink();
  link.failing = false;
  const store = new Store(link);
  await Promise.all([store.loadAuto("mac"), store.loadAuto("mac"), store.loadAuto("mac")]);
  assert.equal(link.asked, 1);
});
