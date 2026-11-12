// The web page's part of the budgets a pull request keeps (#4784): bytes and counts, which do
// not change with the runner's load, as a time does. The budgets are in scripts/perf-budgets.json;
// the times are measured at night (scripts/perf-nightly.sh).
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";
import { load } from "./load.mjs";

const repo = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const budgets = JSON.parse(readFileSync(join(repo, "scripts/perf-budgets.json"), "utf8")).pr;
const dist = join(repo, "Web/dist");
// CI builds Web/dist before its tests, so there a missing one fails; here it is skipped.
const skip = existsSync(join(dist, "MANIFEST")) || process.env.CI ? false : "no Web/dist built here; run scripts/web.sh build";

/** What the page loads to draw: its scripts, styles and HTML, each gzipped as a server sends it. */
function gzippedBundle(folder) {
  const files = (at) => readdirSync(at).flatMap((name) => {
    const path = join(at, name);
    return statSync(path).isDirectory() ? files(path) : [path];
  });
  return files(folder).filter((path) => /\.(js|css|html)$/.test(path))
    .reduce((sum, path) => sum + gzipSync(readFileSync(path), { level: 9 }).length, 0);
}

test("the bundle, gzipped, keeps its budget", { skip }, () => {
  const bytes = gzippedBundle(dist);
  console.log(`web bundle: ${bytes} bytes gzipped (budget ${budgets["web.gzipBytes"]})`);
  assert.ok(bytes <= budgets["web.gzipBytes"],
    `the web bundle is ${bytes} bytes gzipped, over its budget of ${budgets["web.gzipBytes"]} (scripts/perf-budgets.json, #4784)`);
});

const { Store } = await load("test/store-call.ts");

/** Every call the page makes from its link opening until the first live list, in order. */
async function callsBeforeFirstList() {
  const calls = [];
  let open = () => {};
  let listed = () => {};
  const first = new Promise((resolve) => { listed = resolve; });
  const link = {
    onNotification: () => {},
    onState: (handler) => { open = handler; },
    keyRecord: async () => null,
    call: async (method, params, host) => {
      // The first list: client/catchUp (#4794), or agents/list from a host before it.
      if (method === "client/catchUp") {
        listed();
        return { agents: [] };
      }
      if (method === "agents/list" && !params?.includeArchived) {
        listed();
        return [];
      }
      calls.push(host ? `${method} (${host})` : method);
      if (method === "machines/list") return [{ id: "mac", name: "Mac", state: "online", capabilities: [] }];
      // The rest have no answer here: the page goes on without them, as it does when a call fails.
      throw new Error("not in this test");
    },
  };
  new Store(link);
  open({ kind: "open" });
  await first;
  return calls;
}

test("the page asks for few things before its first list", async () => {
  const calls = await callsBeforeFirstList();
  const budget = budgets["web.callsBeforeFirstList"];
  console.log(`web: ${calls.length} calls before the first list (budget ${budget}): ${calls.join(", ")}`);
  assert.ok(calls.length <= budget,
    `the page makes ${calls.length} calls before its first list, over its budget of ${budget} (scripts/perf-budgets.json, #4784): ${calls.join(", ")}`);
});
