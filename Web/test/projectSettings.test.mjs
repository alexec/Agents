// Project Settings and Folder Settings (#3280): a default is kept as no value, as the window keeps it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/projectSettings.ts");

test("project settings: a limit at its default leaves .agents/folder.json", () => {
  assert.deepEqual(p.withLimit({ queued: 8, agentsMayArchive: false }, "queued", 5, 5), { agentsMayArchive: false });
  assert.deepEqual(p.withLimit(undefined, "queued", 8, 5), { queued: 8 });
  assert.deepEqual(p.withLimit({ continueWhenBack: true }, "continueWhenBack", undefined, undefined), {});
});

test("project settings: the queued and disk menus offer a number set by hand", () => {
  assert.deepEqual(p.queuedChoices(5).slice(0, 3), [1, 2, 3]);
  assert.equal(p.queuedChoices(30).at(-1), 30);
  assert.deepEqual(p.diskChoices([5, 10, 20], 15), [5, 10, 15, 20]);
  assert.deepEqual(p.withDiskLine({ lowGB: 50 }, "lowGB", 20, 20), {});
});

test("project settings: the folder that keeps them is named", () => {
  assert.equal(p.folderPathOf("file:///Users/a/My%20Repo/"), "/Users/a/My Repo");
  assert.match(p.writtenIn("/Users/a/Agents", "This Mac"), /^Written in \/Users\/a\/Agents on This Mac\. Commit \.agents/);
});
