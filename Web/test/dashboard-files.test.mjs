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
