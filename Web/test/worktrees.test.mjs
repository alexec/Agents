// Activity ▸ Worktrees (#790): the same order and words as AgentsKitCore's WorktreeTally.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const w = await load("src/model/worktrees.ts");
const gb = 1_000_000_000;
const tree = (name, size, agents = 0, partial = false, folder = "/p") => ({
  name, root: `file://${folder}/.agents/worktrees/${name}/`, branch: `agents/${name}`, isFolderPath: false,
  exists: true, madeByApp: true, agents: Array.from({ length: agents }, (_, i) => `a${i}`),
  ...(size === null ? {} : { size: { bytes: size * gb, partial } }),
});

test("worktrees: idle first, largest first, then unmeasured, then by name", () => {
  const listed = [tree("busy-big", 9, 1), tree("b", null), tree("small", 1), tree("a", null), tree("big", 5)];
  assert.deepEqual([...listed].sort(w.cleanupOrder).map((t) => t.name), ["big", "small", "a", "b", "busy-big"]);
});

test("worktrees: the page and the row say how much and how much is idle", () => {
  const t = w.tally([tree("a", 9, 1), tree("b", 3, 0, true), tree("c", null)]);
  assert.equal(w.rowWords(t), "3 worktrees, 2 idle");
  assert.equal(w.pageLine(t), "Worktrees hold over 12.0 GB, 3.0 GB of it idle.");
  assert.equal(w.pageLine(w.tally([tree("c", null)])), "Measuring 1 worktree…");
  assert.equal(w.pageLine(w.tally([])), w.worktreesEmpty);
  assert.equal(w.rowWords(w.tally([])), null);
});

test("worktrees: what Remove build output freed, and what Remove… would lose", () => {
  assert.equal(w.freedWords({ removed: ["build", "Web/node_modules"], freed: { bytes: 3.2 * gb, partial: false } }),
    "Freed 3.2 GB: build, Web/node_modules.");
  assert.equal(w.freedWords({ removed: [], freed: { bytes: 0, partial: false } }), "No build output to remove.");
  assert.equal(w.removalMessage({ blockedBy: [], uncommitted: 2, unmerged: true }, "agents/x"),
    "This loses 2 uncommitted changes and commits that are not merged, and removes its branch agents/x.");
});

test("worktrees: a size heard after the list fills it in, and the folder holding most idle comes first", () => {
  const late = tree("late", null, 0, false, "/q");
  const groups = [{ folder: "/p", worktrees: [tree("a", 2)] }, { folder: "/q", worktrees: [late] }];
  assert.deepEqual(w.forCleanup(groups).map((g) => g.folder), ["/p", "/q"]);
  const heard = { [late.root]: { bytes: 7 * gb, partial: false } };
  assert.deepEqual(w.forCleanup(groups, heard).map((g) => g.folder), ["/q", "/p"]);
  assert.equal(w.worktreeDetail(tree("x", 1, 2), { bytes: 4.1 * gb, partial: false }), "agents/x · 2 agents working · 4.1 GB");
  assert.equal(w.statusSummary({ uncommitted: 2, unmerged: 1, ahead: 1 }), "2 uncommitted · 1 unmerged · ↑1");
});

test("worktrees: Clean up worktrees keeps a half-typed draft and its files (#1863)", () => {
  const file = { id: "f", name: "notes.md" };
  assert.deepEqual(w.cleanUpDraft(undefined), { text: w.cleanUpPrompt, attachments: [] });
  assert.deepEqual(w.cleanUpDraft({ text: "  ", attachments: [file] }), { text: w.cleanUpPrompt, attachments: [file] });
  assert.deepEqual(w.cleanUpDraft({ text: "Half a thought", attachments: [file] }),
    { text: `Half a thought\n\n${w.cleanUpPrompt}`, attachments: [file] });
});
