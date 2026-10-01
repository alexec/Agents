// The sessions column's groups and status words, as Swift has them (SC-005, research R7).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const groups = await load("src/model/groups.ts");
const status = await load("src/model/status.ts");

for (const { name, input, expected } of cases("groups/agents.json")) {
  test(`group: ${name}`, () => {
    const group = groups.groupOf(input.agent, input.wantsEyes);
    assert.deepEqual({ group, title: groups.groupTitles[group], needsAPerson: groups.needsAPerson(input.agent),
                       isWaiting: groups.isWaiting(input.agent), showsUnread: groups.showsUnread(input.agent) }, expected);
  });
}

for (const { name, input, expected } of cases("groups/panels.json")) {
  test(`column: ${name}`, () => {
    const headings = groups.headings(input.agents, input.folder)
      .map((h) => ({ group: h.group, title: h.title, ids: h.agents.map((a) => a.id), unread: h.agents.filter(groups.showsUnread).length }));
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

const symbols = { working: null, needsYou: "exclamationmark.circle.fill", waiting: "hourglass.circle",
                  done: "checkmark.circle", stopped: "stop.circle" };

for (const { name, input, expected } of cases("status/rows.json")) {
  test(`status: ${name}`, () => {
    const row = status.rowStatus(input.agent, input.isComingBack);
    assert.deepEqual({ shape: row.shape, symbol: symbols[row.shape], tinted: row.tinted, words: row.words }, expected);
  });
}

test("a project row says Needs you first, unread beside it (ProjectRow.subtitle, #70)", () => {
  const [{ input }] = cases("groups/panels.json");
  assert.equal(groups.projectSubtitle(input.agents, input.folder), "Needs you · 2 unread");
  assert.equal(groups.projectSubtitle([], input.folder), null);
});
