// The sessions column's groups and status words, as Swift has them (SC-005, research R7).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const groups = await load("src/model/groups.ts");
const status = await load("src/model/status.ts");

for (const { name, input, expected } of cases("groups/agents.json")) {
  test(`group: ${name}`, () => {
    const group = groups.groupOf(input.agent);
    assert.deepEqual({ group, title: groups.groupTitles[group], needsAPerson: groups.needsAPerson(input.agent),
                       isWaiting: groups.isWaiting(input.agent), showsUnread: groups.showsUnread(input.agent),
                       asksToArchive: groups.asksToArchive(input.agent) }, expected);
  });
}

for (const { name, input, expected } of cases("groups/panels.json")) {
  test(`column: ${name}`, () => {
    const headings = groups.headings(input.agents, input.folder)
      .map((h) => ({ group: h.group, title: h.title, ids: h.agents.map((a) => a.id), unread: h.agents.filter(groups.showsUnread).length,
                     asking: h.agents.filter(groups.asksToArchive).length }));
    const counts = groups.counts(input.agents, input.folder);
    assert.deepEqual({
      headings,
      archived: groups.agentsIn(input.agents, input.folder, "archived").map((a) => a.id),
      counts,
      needsYou: counts.needsAttention ?? 0,
      unread: groups.unreadCount(input.agents, input.folder),
      attention: groups.attentionCount(input.agents, input.folder),
    }, expected);
  });
}

const symbols = { working: null, needsYou: "exclamationmark.circle.fill", waiting: "dot.radiowaves.left.and.right",
                  done: "checkmark", stopped: "stop.circle" };

for (const { name, input, expected } of cases("status/rows.json")) {
  test(`status: ${name}`, () => {
    const row = status.rowStatus(input.agent, input.isComingBack);
    assert.deepEqual({ shape: row.shape, symbol: symbols[row.shape], tinted: row.tinted, words: row.words }, expected);
  });
}

test("a folder row says Needs you first, unread beside it (FolderRow.subtitle, #70)", () => {
  const [{ input }] = cases("groups/panels.json");
  assert.equal(groups.folderSubtitle(input.agents, input.folder), "Needs you · 4 unread");
  assert.equal(groups.folderSubtitle([], input.folder), null);
});

// A worktree with "folder": "" (#2650), left by #2617, counts under where the agent runs.
test("an empty worktree folder counts as none", () => {
  const worktree = { name: "lane", root: "file:///r/.agents/worktrees/lane/", madeByApp: true, folder: "" };
  assert.equal(groups.folderPath({ cwd: "file:///r/.agents/worktrees/lane/", worktree }), "file:///r/.agents/worktrees/lane");
  assert.equal(groups.folderPath({ cwd: "file:///w/", worktree: { ...worktree, folder: "file:///r/" } }), "file:///r");
});

test("Recently archived sessions are the newest three archived in the last 24 hours (#2868)", () => {
  const now = 900_000_000;
  const day = groups.recentArchivedWithin;
  const archived = [now - 10, now - 20, now - day + 60, now - day - 60].map((archivedAt, i) =>
    ({ id: `a${i}`, archivedAt, lastActivityAt: 0 }));
  assert.deepEqual(groups.recentlyArchived(archived, 3, now).map((a) => a.id), ["a0", "a1", "a2"]);
  assert.deepEqual(groups.recentlyArchived(archived.slice(2), 3, now).map((a) => a.id), ["a2"]);
  assert.deepEqual(groups.recentlyArchived(archived, 3, now + day), []);
  const before = [{ id: "old", lastActivityAt: now - 5 }];
  assert.deepEqual(groups.recentlyArchived(before, 3, now).map((a) => a.id), ["old"]);
});
