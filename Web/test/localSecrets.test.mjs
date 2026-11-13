// Settings ▸ You ▸ Secrets ▸ On This Machine (#5122): the words and the line, as the window's and the
// Remote's LocalSecretWords and SecretInfoWords.line(LocalSecret) say them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const s = await load("src/model/localSecrets.ts");
const now = new Date(1_794_132_840_000);
const wire = (ms) => (ms - Date.UTC(2001, 0, 1)) / 1000;

test("local secrets: the section's words", () => {
  assert.equal(s.localSecretWords.header, "On This Machine");
  assert.equal(s.localSecretWords.notBackedUp, "Only on this machine. Not backed up.");
});

test("local secrets: a row says when it was set and used", () => {
  const secret = { name: "GITHUB_SAM_TOKEN", setAt: wire(now - 3_600_000), lastOp: { what: "read", at: wire(now - 1_200_000) } };
  assert.deepEqual(s.localLine(secret, now).map((p) => p.text), ["Set 1 h ago", "Used 20 min ago"]);
});
