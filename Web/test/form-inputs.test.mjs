// A question's date, date-time, email and URL fields (#265), as the Remote's FormPages.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const f = await load("src/model/formInputs.ts");

test("form inputs: each format has its input", () => {
  assert.deepEqual(["date", "date-time", "email", "uri", undefined].map(f.inputType), ["date", "datetime-local", "email", "url", "text"]);
  assert.equal(f.placeholder("email"), "name@example.com");
  assert.equal(f.placeholder("uri"), "https://");
  assert.equal(f.placeholder(undefined), "");
});

test("form inputs: a date-time goes as ISO 8601 in UTC, and comes back as local time", () => {
  const sent = f.momentFromInput("2026-10-04T09:30");
  assert.match(sent, /^\d{4}-\d\d-\d\dT\d\d:\d\d:00Z$/);
  assert.equal(new Date(sent).getTime(), new Date(2026, 9, 4, 9, 30).getTime());
  assert.equal(f.momentToInput(sent), "2026-10-04T09:30");
  assert.equal(f.momentToInput("not a date"), "");
});
