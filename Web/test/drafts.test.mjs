// Drafts kept across a reload (#254), bounded: the most recent only, and big attachments let go.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

class Memory {
  items = new Map();
  getItem(key) { return this.items.get(key) ?? null; }
  setItem(key, value) { this.items.set(key, String(value)); }
}

const { Drafts, draftsKept, attachmentsKept } = await load("src/model/drafts.ts");
const { promptPlaceholder, willQueue } = await load("src/model/promptWords.ts");

test("a draft comes back on the next visit; an emptied or sent one does not", () => {
  const storage = new Memory();
  const first = new Drafts(storage);
  first.set("mac|a", { text: "half a thought", attachments: [] });
  first.set("mac|b", { text: "gone", attachments: [] });
  first.delete("mac|b");
  first.set("mac|c", { text: "", attachments: [] });
  const next = new Drafts(storage);
  assert.deepEqual(next.get("mac|a"), { text: "half a thought", attachments: [] });
  assert.equal(next.get("mac|b"), undefined);
  assert.equal(next.get("mac|c"), undefined);
});

test("only the most recent drafts are kept, and a big attachment keeps its words only", () => {
  const storage = new Memory();
  const drafts = new Drafts(storage);
  for (let i = 0; i <= draftsKept; i++) drafts.set(`mac|${i}`, { text: `draft ${i}`, attachments: [] });
  const big = [{ id: "x", displayName: "big.png", block: { type: "image", mimeType: "image/png", data: "A".repeat(attachmentsKept) } }];
  drafts.set("mac|big", { text: "with a picture", attachments: big });
  const next = new Drafts(storage);
  assert.equal(next.get("mac|0"), undefined, "the oldest went");
  assert.equal(next.get("mac|1"), undefined);
  assert.equal(next.get(`mac|${draftsKept}`)?.text, `draft ${draftsKept}`);
  assert.deepEqual(next.get("mac|big"), { text: "with a picture", attachments: [] });
  assert.equal(drafts.get("mac|big").attachments.length, 1, "held whole while the page is open");
});

test("an unreadable store starts empty; no store keeps drafts in memory", () => {
  const storage = new Memory();
  storage.setItem("agents.drafts", "{not json");
  assert.equal(new Drafts(storage).get("mac|a"), undefined);
  const memory = new Drafts(undefined);
  memory.set("mac|a", { text: "here", attachments: [] });
  assert.equal(memory.get("mac|a").text, "here");
});

test("the empty field's words, and when what is typed waits (PromptWords)", () => {
  assert.equal(promptPlaceholder(undefined), "What do you want to do?");
  assert.equal(promptPlaceholder({ state: "running" }), "What do you want to do next?");
  assert.equal(promptPlaceholder({ state: "finished" }), "What do you want to do?");
  assert.equal(promptPlaceholder({ state: "archived" }), "Say what next, and this comes back");
  assert.equal(willQueue({ state: "waitingOnUser" }), true);
  assert.equal(willQueue({ state: "finished", queuedPrompts: [{}] }), true);
  assert.equal(willQueue({ state: "finished" }), false);
});
