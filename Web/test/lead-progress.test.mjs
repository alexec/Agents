// A lead's sidebar row (#3270), as LeadProgressTests has it on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/leadProgress.ts");

const issue = (n) => ({ kind: "issue", ref: `github:alexec/Agents#${n}` });
const lead = "8A1C0F7E-1111-2222-3333-444455556666";
const me = { kind: "session", ref: `session:${lead}` };
const link = (from, to, { rel = "works-on", at = 0, ended = false } = {}) => ({ from, to, rel, source: "start", at, ...ended ? { endedAt: at + 1 } : {} });

test("a session labelled lead is a lead", () => {
  assert.equal(p.isLead({ labels: [{ value: "#3265", owner: "person" }, { value: "lead", owner: "person" }] }), true);
  assert.equal(p.isLead({ labels: [{ value: "#3265", owner: "person" }] }), false);
  assert.equal(p.isLead({}), false);
});

test("the epic is the newest issue the session works on", () => {
  const links = [
    link(me, issue(1), { at: 0 }),
    link({ kind: "session", ref: me.ref.toLowerCase() }, issue(2), { at: 10 }),
    link(me, issue(3), { at: 20, ended: true }),
    link({ kind: "session", ref: "session:other" }, issue(4), { at: 30 }),
    link(me, { kind: "pr", ref: "github:alexec/Agents#5" }, { at: 40 }),
    link(me, issue(6), { rel: "mentions", at: 50 }),
  ];
  assert.deepEqual(p.leadEpic(lead, links), issue(2));
  assert.equal(p.leadEpic(lead, []), undefined);
});

test("the words are the children closed of all", () => {
  const child = (n, state) => ({ item: { node: issue(n), title: `Issue ${n}`, state }, blockedBy: [], step: 1 });
  assert.equal(p.leadProgressWords({ children: [] }), undefined);
  assert.equal(p.leadProgressWords({ children: [child(2, "closed"), child(3, "open"), child(4, "closed")] }), "2/3");
  assert.equal(p.leadProgressSpoken("2/3"), "2 of 3 done");
});
