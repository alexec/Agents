// Console ▸ Audit ▸ Sinks (#1001): what is sent to audit/setSinks, and how a sink's status reads.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/auditSinks.ts");

test("a token goes only where one was typed, and never for syslog; empty rows are left out", () => {
  assert.deepEqual(m.sinksToSet([
    { kind: "http", address: " https://siem/in ", token: " t0k ", hasToken: false },
    { kind: "http", address: "https://other/in", token: "", hasToken: true },
    { kind: "syslog", address: "tls://siem:6514", token: "ignored", hasToken: false },
    { kind: "syslog", address: "  ", token: "", hasToken: false },
  ]), [
    { kind: "http", address: "https://siem/in", token: "t0k" },
    { kind: "http", address: "https://other/in" },
    { kind: "syslog", address: "tls://siem:6514" },
  ]);
});

test("the drafts start from what the control plane answers, with no token", () => {
  assert.deepEqual(m.draftsOf([{ sink: { kind: "http", address: "https://siem/in", hasToken: true }, queued: 0, dropped: 0 }]),
    [{ kind: "http", address: "https://siem/in", token: "", hasToken: true }]);
});

test("a sink's line says the last sent, what waits, what was dropped, or the failure", () => {
  const now = new Date("2026-10-22T10:00:00Z");
  const sink = { kind: "syslog", address: "tcp://siem:514" };
  assert.equal(m.sinkStatusLine({ sink, queued: 0, dropped: 0 }, now), "Nothing sent yet");
  assert.equal(m.sinkStatusLine({ sink, queued: 0, dropped: 0, sentAt: "2026-10-22T09:55:00Z" }, now), "Sent 5 minutes ago");
  assert.equal(m.sinkStatusLine({ sink, queued: 1200, dropped: 3, lastError: "connection refused", sentAt: "2026-10-22T09:00:00Z" }, now),
    "Not sent: connection refused · 1,200 waiting · 3 dropped when the queue was full");
});
