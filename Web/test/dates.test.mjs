// The wire's dates count from 2001, as Swift's do (contracts/generated-types.md).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { fromWireDate, toWireDate } = await load("src/protocol/dates.ts");

test("zero is 2001-01-01, and a date round-trips", () => {
  assert.equal(fromWireDate(0).toISOString(), "2001-01-01T00:00:00.000Z");
  assert.equal(fromWireDate(812548800).toISOString(), "2026-10-01T12:00:00.000Z");
  const now = new Date("2026-10-01T12:34:56.789Z");
  assert.equal(fromWireDate(toWireDate(now)).getTime(), now.getTime());
});
