// Status ▸ Secrets and Status ▸ Accounts (#4161): the same lines as the window's StatusSecretsWords.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const s = await load("src/model/statusSecrets.ts");
const nav = await load("src/model/nav.ts");

const now = Date.UTC(2027, 0, 15, 12);
const ref = Date.UTC(2001, 0, 1);
const wire = (minutesAgo) => (now - minutesAgo * 60_000 - ref) / 1000;
const row = (name, more = {}) => ({ name, updated: "", machines: ["mac"], backedUp: true, ...more });

test("status secrets: newest operation first, with the hint and the not-backed-up warning", () => {
  const lines = s.secretLines([
    row("GITHUB_TOKEN", { hint: "ab12", lastOp: { what: "read", at: wire(120) } }),
    row("OPENAI_API_KEY", { hint: "Zq9w", lastOp: { what: "read", at: wire(5) }, backedUp: false }),
    row("NPM_PIN", { created: "2026-01-02T03:04:05Z" }),
    row("NEVER"),
  ]);
  assert.deepEqual(lines.map((l) => l.title), ["OPENAI_API_KEY", "GITHUB_TOKEN", "NPM_PIN", "NEVER"]);
  assert.equal(lines[0].hint, "••••Zq9w");
  assert.equal(lines[0].operation, "Read");
  assert.equal(lines[0].backedUp, false);
  assert.equal(lines[2].hint, "••••");
  assert.equal(lines[2].operation, "Added");
  assert.equal(lines[3].at, null);
  assert.equal(s.newestAt(lines), now - 5 * 60_000);
  assert.equal(s.warns(lines), true);
  assert.equal(s.summary(lines[1]), "••••ab12 · Read");
});

test("status accounts: the newest of its own and its secret's operations", () => {
  const secrets = [row("GITLAB_TOKEN", { hint: "ab12", lastOp: { what: "read", at: wire(10) }, backedUp: false })];
  const lines = s.accountLines([
    { service: "slack.com", made: "2025-12-01" },
    { service: "aws.amazon.com", secret: "ELSEWHERE" },
    { service: "gitlab.com", address: "agentstest@example.com", secret: "GITLAB_TOKEN", made: "2026-01-01", edited: wire(60) },
  ], secrets);
  assert.deepEqual(lines.map((l) => l.title), ["gitlab.com", "slack.com", "aws.amazon.com"]);
  assert.equal(lines[0].operation, "GITLAB_TOKEN read");
  assert.equal(lines[0].backedUp, false);
  assert.equal(s.summary(lines[0]), "agentstest@example.com · ••••ab12 · GITLAB_TOKEN read");
  assert.equal(lines[1].hint, "no secret");
  assert.equal(lines[1].operation, "Added");
  assert.equal(lines[2].hint, "not in Secrets");
  assert.equal(lines[2].backedUp, true);
});

test("status secrets: short ages, as the window's", () => {
  assert.equal(s.shortAgo(now - 30_000, now), "just now");
  assert.equal(s.shortAgo(now - 300_000, now), "5 min ago");
  assert.equal(s.shortAgo(now - 7_200_000, now), "2 h ago");
  assert.equal(s.shortAgo(now - 3 * 86_400_000, now), "3 d ago");
});

test("status secrets: two pages under Status, after Events", () => {
  assert.deepEqual(nav.navPages.status.map((p) => p.id), ["runtimes", "events", "secrets", "accounts"]);
});
