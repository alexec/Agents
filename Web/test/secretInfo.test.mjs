// A secret's row (#4159): the same words as SecretInfoWords, held to the same cases in SecretInfoWordsTests.swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const s = await load("src/model/secretInfo.ts");
const now = new Date(1_794_132_840_000);
const wire = (ms) => (ms - Date.UTC(2001, 0, 1)) / 1000;

test("secret info: the last 4, or dots only", () => {
  assert.equal(s.hint("ab12"), "••••ab12");
  assert.equal(s.hint(undefined), "••••");
});

test("secret info: an age is short, a hover has the date and time", () => {
  assert.equal(s.age(new Date(now - 30_000), now), "just now");
  assert.equal(s.age(new Date(now - 300_000), now), "5 min ago");
  assert.equal(s.age(new Date(now - 7_200_000), now), "2 h ago");
  assert.equal(s.age(new Date(now - 27 * 86_400_000), now), "27 d ago");
  assert.equal(s.stamp(new Date(1_791_796_440_000), "UTC"), "12 Oct 2026, 09:14");
});

test("secret info: a row says where it is, when it was added and when it was used", () => {
  const row = { machines: ["a", "b", "c"], updated: "2026-10-12T09:14:00Z", created: "2026-10-12T09:14:00.123Z",
    lastOp: { what: "read", at: wire(now - 7_200_000) } };
  const parts = s.rowLine(row, now, "UTC");
  assert.equal(s.joined(parts), "On 3 machines · Added 27 d ago · Used 2 h ago");
  assert.equal(parts[1].help, "Added 12 Oct 2026, 09:14");
  assert.match(parts[2].help, /^Read /);

  const replaced = { ...row, updated: "2026-11-06T09:14:00Z", lastOp: { what: "replaced", at: wire(now - 86_400_000) } };
  assert.equal(s.joined(s.rowLine(replaced, now, "UTC")), "On 3 machines · Replaced 2 d ago · Not used since it was replaced");
  assert.equal(s.rowLine(replaced, now, "UTC")[1].help, "Added 12 Oct 2026, 09:14\nReplaced 6 Nov 2026, 09:14");

  assert.equal(s.joined(s.rowLine({ machines: ["a", "b", "c"], updated: "2026-11-06T09:14:00Z" }, now, "UTC")),
    "On 3 machines · Set 2 d ago · Never used");
  assert.equal(s.usedPart({ what: "added", at: wire(now) }, now).text, "Never used");
  assert.equal(s.usedPart({ what: "denied", at: wire(now - 300_000) }, now).text, "Use denied 5 min ago");
});

test("secret info: one copy is not backed up", () => {
  const row = { machines: ["box"], backedUp: false };
  assert.equal(s.notBackedUp(row, s.machineNames([{ id: "box", name: "devbox" }])),
    "Only on devbox. Not backed up: if devbox is lost, this secret is lost.");
  assert.equal(s.notBackedUp(row), "Only on one machine. Not backed up: if it is lost, this secret is lost.");
  assert.equal(s.notBackedUp({ ...row, waiting: ["mac"] }), null);
  assert.equal(s.notBackedUp({ ...row, backedUp: true }), null);
});

test("secret info: a person with one machine is told once", () => {
  const only = { machines: ["mac"], backedUp: false };
  assert.equal(s.onlyMachine([only, only]), "mac");
  assert.equal(s.onlyMachineLine("mac", { mac: "this Mac" }), "Your secrets are only on this Mac. Add a second machine to keep a copy.");
  const two = { machines: ["mac", "box"], backedUp: true };
  assert.equal(s.onlyMachine([only, two]), null);
  assert.equal(s.onlyMachine([two]), null);
});

test("secret info: a session's secret says its session", () => {
  const secret = { title: "Fix the shop sign-in", setAt: wire(now - 3_600_000), created: wire(now - 3_600_000),
    lastOp: { what: "read", at: wire(now - 1_200_000) } };
  assert.equal(s.joined(s.sessionLine(secret, now)), "Fix the shop sign-in · Added 1 h ago · Used 20 min ago");
});
