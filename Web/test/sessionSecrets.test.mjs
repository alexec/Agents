// Secrets for this session only (#3548): the card's and Settings ▸ Secrets' words, as the window's and
// the Remote's SessionSecretWords say them, and the sessions that can take one.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const s = await load("src/model/sessionSecrets.ts");

test("session secrets: the card says where it is kept and when it goes", () => {
  assert.equal(s.keepingForSession("your Mac"),
    "Kept on your Mac for this session only, and deleted when it is archived. The agent gets its name, never the value.");
  assert.equal(s.sessionOnlyField, "sessionOnly");
  assert.equal(s.sessionSecretWords.toggle, "For this session only");
});

test("session secrets: Remove names the secret and its session", () => {
  assert.equal(s.removeQuestion({ agentID: "A", title: "Sign up to the shop", name: "SHOP_PASSWORD", setAt: 0 }),
    "Remove SHOP_PASSWORD from “Sign up to the shop”?");
});

test("session secrets: only sessions not archived take one, latest first", () => {
  const agents = [
    { id: "1", state: "finished", lastActivityAt: 10 },
    { id: "2", state: "archived", lastActivityAt: 30 },
    { id: "3", state: "running", lastActivityAt: 20 },
  ];
  assert.deepEqual(s.sessionsForSecrets(agents).map((a) => a.id), ["3", "1"]);
});
