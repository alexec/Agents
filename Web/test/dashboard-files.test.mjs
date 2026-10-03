// Where a Dashboard is kept, as DashboardModel says it (#127).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const d = await load("src/model/dashboard.ts");

test("the Dashboard says its tiles and trends are project files, in the window's words", () => {
  assert.equal(d.filesSentence,
    "Tiles and their trends are files in .agents/dashboard/ in this project, which you may commit");
  assert.equal(d.historyFile("open_bugs"), ".agents/dashboard/history/open_bugs.jsonl");
});

// Update now (#146), as DashboardUpdate says it. Wire dates are seconds since 2001.
const at = 800_000_000;

test("Update now waits five minutes after the last start, and not while one runs or is blocked", () => {
  const last = { name: "Update the dashboard", isRunning: false, lastFailed: false, lastStartedAt: at };
  assert.equal(d.updateReadyAt(last, at + 60), at + 300);
  assert.equal(d.updateReadyAt(last, at + 300), null);
  assert.equal(d.canUpdate(last, at + 299), false);
  assert.equal(d.canUpdate(last, at + 300), true);
  assert.equal(d.canUpdate({ ...last, isRunning: true }, at + 900), false);
  assert.equal(d.canUpdate({ ...last, blocked: "x" }, at + 900), false);
  assert.equal(d.canUpdate({ name: "Update the dashboard", isRunning: false, lastFailed: false }, at), true);
});

test("Update now's line says what is going, why it can't, or how the last one went", () => {
  const base = { name: "Update the dashboard", isRunning: false, lastFailed: false };
  assert.equal(d.updateLine(base, at), null);
  assert.equal(d.updateLine({ ...base, isRunning: true, blocked: "x" }, at), "Update the dashboard is running");
  assert.equal(d.updateLine({ ...base, blocked: "Update the dashboard is waiting for approval" }, at),
    "Update now can't start: Update the dashboard is waiting for approval");
  assert.match(d.updateLine({ ...base, lastStartedAt: at, lastFailed: true }, at + 60), /^The last update, .+, did not finish$/);
  assert.match(d.updateLine({ ...base, lastStartedAt: at }, at + 60), /^Last update .+; again from .+$/);
  assert.match(d.updateLine({ ...base, lastStartedAt: at }, at + 600), /^Last update [^;]+$/);
});

test("Update now's times are 24-hour, as the window's", () => {
  // 15 Jan 2027 08:00 UTC; the clock is local, so only the shape is asserted.
  const line = d.updateLine({ name: "x", isRunning: false, lastFailed: false, lastStartedAt: 810_892_800 }, 810_892_860);
  assert.match(line, /^Last update \d\d:\d\d; again from \d\d:\d\d$/);
});
