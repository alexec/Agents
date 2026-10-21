// Open File does not save over a change made on disk under unsaved typing (#1858).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const s = await load("src/model/sourceEdit.ts");

test("a change on disk is taken in place while nothing typed waits", () => {
  assert.deepEqual(s.onDiskChange("agent's", "old", "old"), { draft: "agent's", saved: "agent's", theirs: null });
  assert.equal(s.onDiskChange("old", "typed", "old"), null);
});

test("a change on disk under unsaved typing is asked about, not written over", () => {
  assert.deepEqual(s.onDiskChange("agent's", "typed", "old"), { theirs: "agent's" });
  // The same text both ways is no conflict.
  assert.deepEqual(s.onDiskChange("typed", "typed", "old"), { draft: "typed", saved: "typed", theirs: null });
});

test("the base is the text's SHA-256 in lower-case hex, as the host works it out", async () => {
  assert.equal(await s.textDigest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  assert.equal(await s.textDigest("# hi"), "8a5d8b28d66ae90b5876fe0337b963d9f66ab1047f8c866ff4646b73a8a3aa41");
  assert.equal(await s.textDigest("café"), "850f7dc43910ff890f8879c0ed26fe697c93a067ad93a7d50f466a7028a9bf4e");
});
