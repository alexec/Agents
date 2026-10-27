// A file to see (#1802), as FileToSeeWords.line says it: a mark, never a group.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const w = await load("src/model/fileToSeeWords.ts");
const g = await load("src/model/groups.ts");

const finished = {
  id: "A", runtimeID: "claude", cwd: "file:///p/", state: "finished", startOptions: {}, advertisedOptions: [],
  availableCommands: [], createdAt: 0, lastActivityAt: 0, isUnread: true, endedReason: "endTurn",
  report: { outcome: "done", message: "Wrote the report.", at: 0 },
};

test("a shown file is named on the row", () => {
  assert.equal(w.fileToSeeLine({ ...finished, fileToSee: { path: "/p/docs/report.md" } }), "File to see: report.md");
  assert.equal(w.fileToSeeLine(finished), null);
});

test("a shown file is the row's grey line, in words, then the report (#1873)", () => {
  assert.equal(w.reportLine({ ...finished, fileToSee: { path: "/p/docs/report.md" } }), "File to see: report.md");
  assert.equal(w.reportLine(finished), "Wrote the report.");
  assert.equal(w.reportLine({ ...finished, report: undefined }), null);
});

test("a shown file leaves the session under Done, unread", () => {
  const agent = { ...finished, fileToSee: { path: "/p/docs/report.md" } };
  assert.equal(g.groupOf(agent), "finished");
  assert.equal(g.drawsUnread(agent), true);
});

test("agents may archive the person's chats unless the person said not", () => {
  assert.equal(w.mayArchiveMyChats.value, true);
});

test("the switch's footer says a server's host does not read it (#1872)", () => {
  assert.match(w.mayArchiveMyChatsFooter, /Another machine does not read this switch, so a chat in a folder on another machine may still archive itself\.$/);
});
