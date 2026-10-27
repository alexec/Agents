// A server's key ask on the page (043, #344): a start a server refuses for want of a key asks
// the person, lends what they paste on this browser's connection, and goes again as the same
// start; cancelled, it fails as the server said. Nothing is kept.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { Store, CallFailed, keyKind, takesKey, wantedRuntime } = await load("test/tokenAsk.ts");

const wanted = () => new CallFailed(-32036, "Gemini on this server needs a key.", { runtime: "gemini", offered: false });
const request = { runtimeID: "gemini", cwd: "file:///w/p/", prompt: "hi", attachments: [], requestID: "R" };

/** A link whose `agents/start` is refused for a key until one is lent, and that keeps what it was asked. */
function serverLink({ refuseLend = false } = {}) {
  const asked = [];
  let lent = false;
  return {
    asked,
    onNotification: () => {},
    onState: () => {},
    call: async (method, params, host) => {
      asked.push({ method, params, host });
      if (method === "credentials/offer") return {};
      if (method === "credentials/lend") {
        if (refuseLend) throw new CallFailed(-32037, "That is not a gemini credential.");
        lent = true;
        return {};
      }
      if (method === "agents/start") {
        if (!lent) throw wanted();
        return "A";
      }
      if (method === "hosts/list") return [];
      throw new Error("no");
    },
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a key is told apart as the window tells it, and only Gemini takes one", () => {
  assert.equal(keyKind("  AIzaSyExample ", "gemini"), "geminiAPIKey");
  assert.equal(keyKind("AQ.Example", "gemini"), "geminiAPIKey");
  assert.equal(keyKind("sk-ant-example", "gemini"), null);
  assert.equal(keyKind("AIzaSyExample", "claude"), null);
  assert.equal(takesKey("gemini"), true);
  assert.equal(takesKey("claude"), false);
  assert.equal(wantedRuntime({ runtime: "gemini", offered: false }), "gemini");
  assert.equal(wantedRuntime(null), null);
});

test("a start on a server that wants a key asks, lends on this connection, and goes again as the same start", async () => {
  const link = serverLink();
  const store = new Store(link);
  const started = store.start("box", request);
  await settle();
  const ask = store.tokenAsk.value;
  assert.equal(ask?.host, "box");
  assert.equal(ask?.runtimeID, "gemini");
  assert.equal(await store.lendKey("not a key"), "notAKey");
  assert.notEqual(store.tokenAsk.value, null);
  assert.equal(await store.lendKey(" AIzaSyExample "), null);
  assert.equal(await started, "A");
  assert.equal(store.tokenAsk.value, null);
  const calls = link.asked.filter((c) => c.method !== "hosts/list");
  assert.deepEqual(calls.map((c) => `${c.host} ${c.method}`),
    ["box agents/start", "box credentials/offer", "box credentials/lend", "box agents/start"]);
  assert.deepEqual(calls[1].params, { runtimes: ["gemini"], ownSignInOnly: false });
  assert.deepEqual(calls[2].params, { runtime: "gemini", kind: "geminiAPIKey", secret: "AIzaSyExample" });
  assert.equal(calls[3].params.requestID, "R");
});

test("cancelled, the start fails as the server said, and nothing is lent", async () => {
  const link = serverLink();
  const store = new Store(link);
  const said = [];
  store.say = (sentence) => said.push(sentence);
  const started = store.start("box", request);
  await settle();
  store.finishTokenAsk(false);
  assert.equal(await started, null);
  assert.deepEqual(said, ["Gemini on this server needs a key."]);
  assert.equal(link.asked.some((c) => c.method === "credentials/lend"), false);
});

test("a key the server refuses leaves the ask open with its words", async () => {
  const store = new Store(serverLink({ refuseLend: true }));
  void store.start("box", request);
  await settle();
  const why = await store.lendKey("AIzaSyExample");
  assert.ok(why && why !== "notAKey");
  assert.notEqual(store.tokenAsk.value, null);
  store.finishTokenAsk(false);
});

test("this Mac's own host is never asked here: its key is the window's", async () => {
  const link = serverLink();
  const store = new Store(link);
  store.say = () => {};
  assert.equal(await store.start("mac", request), null);
  assert.equal(store.tokenAsk.value, null);
});
