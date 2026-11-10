// An account's row (#4160): the same words as AccountsWords, held to the same cases in AccountInfoWordsTests.swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const a = await load("src/model/accounts.ts");
const s = await load("src/model/secretInfo.ts");
const now = new Date(1_794_132_840_000); // 8 Nov 2026, 10:14 UTC
const wire = (ms) => (ms - Date.UTC(2001, 0, 1)) / 1000;
const row = (name, more = {}) => ({ name, machines: ["a", "b"], backedUp: true, ...more });

test("account info: the hint of its secret", () => {
  const rows = [row("GITLAB_TOKEN", { hint: "ab12" }), row("CARD")];
  assert.equal(a.accountHint({ service: "gitlab.com", secret: "GITLAB_TOKEN" }, rows), "••••ab12");
  assert.equal(a.accountHint({ service: "aws.amazon.com", card: "CARD" }, rows), "••••");
  assert.equal(a.accountHint({ service: "slack.com" }, rows), "no secret");
  assert.equal(a.accountHint({ service: "x.com", secret: "ELSEWHERE" }, rows), "not in Secrets");
});

test("account info: a line says made, edited, used and the expiry", () => {
  const parts = a.accountLine({ service: "gitlab.com", made: "2026-10-30", tokenExpires: "2026-12-23",
    edited: wire(now.getTime() - 86_400_000), lastOp: { what: "read", at: wire(now.getTime() - 7_200_000) } }, now, "UTC");
  assert.equal(s.joined(parts), "Made 9 d ago · Edited 1 d ago · Used 2 h ago · Token expires in 45 d");
  assert.equal(parts[0].help, "Made 2026-10-30");
  assert.equal(parts[2].help, "Read 8 Nov 2026, 08:14");
});

test("account info: a new account is never used", () => {
  assert.equal(s.joined(a.accountLine({ service: "slack.com", made: "2026-11-08", tokenExpires: "2026-11-20" }, now, "UTC")),
    "Made today · Never used");
  const added = a.accountUsed({ what: "added", at: wire(now.getTime() - 300_000) }, now, "UTC");
  assert.equal(added.text, "Used 5 min ago");
  assert.equal(added.help, "Added by an agent 8 Nov 2026, 10:09");
});

test("account info: its key or card on one machine is not backed up", () => {
  const rows = [row("AWS_SECRET_KEY", { machines: ["devbox"], backedUp: false }), row("CARD", { machines: ["mac"], backedUp: false })];
  const names = { devbox: "devbox" };
  assert.equal(a.accountNotBackedUp({ service: "aws.amazon.com", card: "CARD", secret: "AWS_SECRET_KEY" }, rows, names),
    "Its key, AWS_SECRET_KEY, is only on devbox. Not backed up.");
  assert.equal(a.accountNotBackedUp({ service: "aws.amazon.com", card: "CARD" }, rows, names), "Its card, CARD, is only on one machine. Not backed up.");
  assert.equal(a.accountNotBackedUp({ service: "gitlab.com", secret: "GONE" }, rows), null);
  assert.equal(a.accountNotBackedUp({ service: "gitlab.com", secret: "OK" }, [row("OK")]), null);
});
