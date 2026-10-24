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
  const own = entry({ method: "control/setFolderDetection" });
  assert.equal(a.place(own, (h) => h), "on the control plane");
  assert.equal(a.call(own), "control/setFolderDetection");
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

test("Console ▸ Audit (#1804): JSON lines as CSV, quoted where they must be", async () => {
  const lines = [
    JSON.stringify({ id: "1", at: 0, action: "Stopped an agent", method: "agents/stop", host: "H1", target: "A1", actor: { user: "u", userName: "Bea, admin" } }),
    "not json",
    JSON.stringify({ id: "2", at: 60, action: "Approved", method: "hosts/approveJoin", actor: { user: "b", event: { kind: "schedule", id: "w" } } }),
  ].join("\n");
  const csv = a.auditCSV(lines, (h) => `${h}'s box`).trim().split("\n");
  assert.equal(csv.length, 3);
  assert.equal(csv[0], "at,action,method,host,hostName,target,user,userName,client,clientName,event");
  assert.equal(csv[1], `2001-01-01T00:00:00.000Z,Stopped an agent,agents/stop,H1,H1's box,A1,u,"Bea, admin",,,`);
  assert.match(csv[2], /,schedule w$/);
  assert.equal(a.csvExportName(new Date(2026, 9, 20)), "audit-2026-10-20.csv");
});

test("a shorter time says what it deletes (#2067)", () => {
  const now = new Date((782654400 + 978307200) * 1000);
  const ago = (id, d) => entry({ id, at: 782654400 - d * 86400 });
  const list = { entries: [ago("a", 1), ago("b", 40), ago("c", 200)], more: false };
  assert.equal(a.older(list, 30, now), 2);
  assert.equal(a.older(list, 180, now), 1);
  assert.equal(a.older({ ...list, more: true }, 30, now), null);
  assert.equal(a.shorterTitle(30), "Keep the audit for 30 days?");
  assert.equal(a.shorterMessage(365, 30, 2),
    "Everyone's entries older than 30 days are deleted in a day (up to 335 days of them, 2 entries now). To keep them, choose 365 days again before then.");
  assert.equal(a.shorterMessage(2, 1, null),
    "Everyone's entries older than 1 day are deleted in a day (up to 1 day of them). To keep them, choose 2 days again before then.");
  assert.deepEqual(a.choices(90), [30, 90, 180, 365]);
  assert.deepEqual(a.choices(7), [7, 30, 90, 180, 365]);
});
