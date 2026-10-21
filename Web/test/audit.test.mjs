// Events ▸ Audit's words (#996), as EventAuditTests has them on the window and the Remote.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const a = await load("src/model/audit.ts");

const entry = (over = {}) => ({ id: "x", at: 782654400, action: "Stopped an agent", method: "agents/stop", actor: { user: "u" }, ...over });

test("who, where and the call", () => {
  const e = entry({ host: "box12345", target: "A1", actor: { user: "owner", userName: "Local owner", clientName: "MacBook Pro" } });
  assert.equal(a.who(e.actor), "Local owner · MacBook Pro");
  assert.equal(a.place(e, () => "box"), "on box");
  assert.equal(a.call(e), "agents/stop · A1");
  const own = entry({ method: "control/setProjectDetection" });
  assert.equal(a.place(own, (h) => h), "on the control plane");
  assert.equal(a.call(own), "control/setProjectDetection");
  assert.equal(a.who(own.actor), "Someone");
  assert.equal(a.who({ user: "b", userName: "Nightly", event: { kind: "pr.merged", id: "42" } }), "Nightly · for pr.merged");
  assert.equal(a.kept(1), "Kept for 1 day");
  assert.equal(a.kept(90), "Kept for 90 days");
});

test("entries are cut into days, newest first", () => {
  const got = a.days([entry({ id: "a", at: 782654400 - 2 * 86400 }), entry({ id: "b", at: 782654400 + 60 }), entry({ id: "c", at: 782654400 })]);
  assert.deepEqual(got.map((d) => d.entries.map((e) => e.id)), [["b", "c"], ["a"]]);
});

test("an export is named by the day", () => {
  assert.equal(a.exportName(new Date(2026, 9, 20, 9)), "audit-2026-10-20.jsonl");
});
