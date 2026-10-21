// One Intl format per currency and per time zone (#1850): the Prompts list's rows each say
// a cost and a time, and making a format costs more than using one.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { money } = await load("src/model/limits.ts");
const { parts } = await load("src/model/activity.ts");

function counting(name, run) {
  const real = Intl[name];
  let made = 0;
  Intl[name] = function (...args) { made += 1; return new real(...args); };
  try { run(); } finally { Intl[name] = real; }
  return made;
}

test("money makes one format per currency (#1850)", () => {
  const made = counting("NumberFormat", () => {
    for (let i = 0; i < 50; i++) money(0.14, "SEK");
    money(1, "NOK");
  });
  assert.ok(made <= 2, `made ${made}`);
  assert.equal(money(0.14, "SEK"), new Intl.NumberFormat(undefined, { style: "currency", currency: "SEK" }).format(0.14));
});

test("parts makes one format per time zone (#1850)", () => {
  const date = new Date(Date.UTC(2026, 9, 20, 14, 5));
  const made = counting("DateTimeFormat", () => {
    for (let i = 0; i < 50; i++) parts(date, "Asia/Tokyo");
  });
  assert.ok(made <= 1, `made ${made}`);
  assert.deepEqual(parts(date, "Asia/Tokyo"), { year: 2026, month: 10, day: 20, hour: 23, minute: 5 });
  assert.equal(parts(date, "UTC").hour, 14);
});
