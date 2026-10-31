// Console ▸ Read API (#2019): how a token and the OTLP exporter read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/readApi.ts");
const at = (d) => (d.getTime() - Date.UTC(2001, 0, 1)) / 1000;
const now = new Date("2026-10-22T15:00:00Z");
const today = at(new Date("2026-10-22T09:30:00Z"));

test("a token says who made it, and its last use or its revoke", () => {
  const made = { by: { user: "alex", userName: "Alex" }, at: today };
  assert.match(m.tokenLine({ id: "a", name: "Looker", made }, now), /^Made by Alex at \d\d:\d\d\. Not used yet\.$/);
  assert.match(m.tokenLine({ id: "a", name: "Looker", made, lastUse: { at: today, address: "10.0.0.2" } }, now), /Last used at \d\d:\d\d from 10\.0\.0\.2\.$/);
  assert.match(m.tokenLine({ id: "a", name: "Looker", made, revoked: made }, now), /Revoked at \d\d:\d\d\.$/);
});

test("the exporter says where, how often, and how the last send went", () => {
  const o = { endpoint: "https://otel.example.com/v1/metrics", every: 300 };
  assert.equal(m.otlpLine(o, now), "Sends today's figures by runtime to https://otel.example.com/v1/metrics every 5 min. Not sent yet: the first goes a minute after start.");
  assert.match(m.otlpLine({ ...o, lastSent: today }, now), /Last sent at/);
  assert.match(m.otlpLine({ ...o, lastSent: today, failedAt: today + 60, lastFailure: "503" }, now), /The last send failed at \d\d:\d\d: 503\.$/);
});

test("the curl line reads a month as CSV", () => {
  assert.equal(m.curlLine("https://cp/v1/read/reports", "agread_x"), "curl -H 'Authorization: Bearer agread_x' 'https://cp/v1/read/reports?range=month&format=csv'");
});

test("Revoke… asks first, and names the token (#2438)", () => {
  assert.match(m.revokeQuestion("Looker"), /^Revoke Looker\? .*cannot be brought back\.$/);
});
