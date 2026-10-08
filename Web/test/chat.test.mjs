// New Chat (#229), held to AppModel.newChat's rules.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/chat.ts");
const d = await load("src/model/diff.ts");
const project = (folder, extra = {}) => ({
  project: { folder, addedAt: 0, ...extra.project }, name: folder.split("/").pop(), exists: true,
  lastActivityAt: 0, counts: {}, costToDate: {}, unmeasuredAgents: 0, ...extra.summary,
});

test("the chat project is the one marked isChat, and not when archived", () => {
  assert.equal(c.chatProject(undefined), undefined);
  assert.equal(c.chatProject([project("file:///work/api")]), undefined);
  const chat = project("file:///home/.agents/chat", { summary: { isChat: true } });
  assert.equal(c.chatProject([project("file:///work/api"), chat]), chat);
  const archived = project("file:///home/.agents/chat", { summary: { isChat: true }, project: { archivedAt: 5 } });
  assert.equal(c.chatProject([archived]), undefined);
});

test("New Chat says why there is none, as the window does", () => {
  assert.equal(c.chatProblem({ ready: { folder: "file:///x" } }, "This Mac"), null);
  assert.equal(c.chatProblem({ archived: { folder: "file:///x" } }, "This Mac"), "The chat project on this Mac is archived.");
  assert.equal(c.chatProblem({ archived: { folder: "file:///x" } }, "devbox"), "The chat project on devbox is archived.");
  assert.match(c.chatProblem({ noPersonalHome: {} }, "This Mac"), /^This Mac has no personal home folder/);
  assert.equal(c.chatProblem({ failed: { message: "It is a file." } }, "This Mac"), "It is a file.");
  assert.equal(c.chatProblem(null, "devbox"), "devbox has no chat project.");
});

test("a folder that is not a repository says so in Changes, in the Remote's words", () => {
  assert.equal(d.unavailableNote(undefined), null);
  assert.equal(d.unavailableNote({ owned: { since: "abc" } }), null);
  assert.equal(d.unavailableNote({ unavailable: { notARepository: {} } }), "This folder is not a Git repository.");
  assert.equal(d.unavailableNote({ unavailable: { gitNotInstalled: {} } }), "Git is not installed on the Mac.");
  assert.equal(d.unavailableNote({ unavailable: { folderGone: {} } }), "The agent's folder is gone.");
  assert.equal(d.unavailableNote({ unavailable: { failed: { message: "fatal: bad" } } }), "fatal: bad");
});
