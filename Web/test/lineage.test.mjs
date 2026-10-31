// A session's Lineage pane (#2940), as LineageListTests has it on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const l = await load("src/model/lineage.ts");

const S = "11111111-1111-4111-8111-111111111111";
const T = "22222222-2222-4222-8222-222222222222";
const session = l.sessionNode(S);
const helper = l.sessionNode(T);
const issue = { kind: "issue", ref: "github:alexec/agents#12" };
const pr = { kind: "pr", ref: "github:alexec/agents#34" };
const at = "2026-10-30T10:00:00Z";
const graph = {
  nodes: [session, issue, helper, pr],
  links: [
    { from: session, to: issue, rel: "works-on", source: "branch", at },
    { from: session, to: helper, rel: "started", source: "helper", at },
    { from: helper, to: issue, rel: "works-on", source: "start", at },
    { from: pr, to: issue, rel: "fixes", source: "pr-body", at, endedAt: at },
  ],
};
const cost = (usd, working = 0) => ({ cost: { USD: usd }, inputTokens: 0, outputTokens: 0, turns: 1, workingSeconds: working, waitingSeconds: 0 });
const blank = cost(0);
const rollup = (node, total, extra = {}) => ({ node, own: total, total, waste: blank, unlinked: blank, prsMerged: 0, prsClosed: 0,
  prsReverted: 0, failedChecks: 0, parts: [], ...extra });

test("a row for each node, the session itself left out", () => {
  const rows = l.lineageRows(session, graph, new Map(), (n) => n.ref === helper.ref ? "Helper" : undefined);
  assert.deepEqual(rows.map((r) => r.name), ["alexec/agents#12", "Helper", "alexec/agents#34"]);
  assert.deepEqual(rows[0].links, ["This session works on it · from the branch", "Helper works on it · when it started",
    "alexec/agents#34 fixes it · from the PR's text · ended"]);
  assert.deepEqual(rows[2].links, ["Fixes alexec/agents#12 · from the PR's text · ended"]);
  assert.equal(rows[1].session, T);
  assert.deepEqual(rows[1].links[0], "This session started it · as a helper");
  const run = { kind: "workflow-run", ref: "run:nightly" };
  const started = l.lineageRows(session, { nodes: [session, run], links: [{ from: run, to: session, rel: "started", source: "start", at }] },
    new Map(), () => undefined);
  assert.deepEqual(started[0].links, ["Started this session · when it started"]);
});

test("an issue's and a PR's cost, with how the PRs ended", () => {
  const costs = new Map([
    [l.costKey(issue), rollup(issue, cost(10, 720), { prsMerged: 1, prsClosed: 1, waste: cost(3) })],
    [l.costKey(pr), rollup(pr, cost(4), { parts: [{ node: pr, banked: cost(4), outcome: "closed", lastAt: at }] })],
  ]);
  const rows = l.lineageRows(session, graph, costs, () => undefined);
  assert.equal(rows[0].cost, "$10.00 · 12m working · 1 merged, 1 closed · $3.00 wasted");
  assert.equal(rows[2].cost, "$4.00 · closed without a merge: waste");
  assert.equal(l.costLine(rollup(pr, cost(1))), "$1.00 · open");
  assert.equal(l.costLine(rollup(pr, cost(0, 3))), "3s working · open");
  assert.equal(l.costLine(rollup(issue, cost(0))), "Nothing banked yet");
});

test("only issues and PRs are costed", () => {
  assert.ok(l.costed(issue) && l.costed(pr));
  assert.ok(!l.costed(helper));
});

test("an issue, a PR or a milestone on GitHub has its address; a session has none", () => {
  const rows = l.lineageRows(session, graph, new Map(), () => undefined);
  const url = (ref) => rows.find((r) => r.node.ref === ref).url;
  assert.equal(url(issue.ref), "https://github.com/alexec/agents/issues/12");
  assert.equal(url(pr.ref), "https://github.com/alexec/agents/pull/34");
  assert.equal(url(helper.ref), undefined);
  assert.equal(l.lineageUrl({ kind: "milestone", ref: "github:alexec/agents/milestone/15" }), "https://github.com/alexec/agents/milestone/15");
});

// The tree and the graph (#3019), as LineageLayoutTests has them on the window.
const title = (n) => n.ref === helper.ref ? "Helper" : undefined;

test("the tree shows each node once, under the first node that reached it", () => {
  const tree = l.lineageTree(session, graph, new Map(), title);
  assert.deepEqual(tree.map((t) => t.row.name), ["This session", "alexec/agents#12", "alexec/agents#34", "Helper"]);
  assert.deepEqual(tree.map((t) => t.depth), [0, 1, 2, 1]);
  assert.deepEqual(tree.map((t) => t.guides), [[], [], [true], []]);
  assert.deepEqual(tree.map((t) => t.last), [true, false, true, true]);
  assert.deepEqual(tree.map((t) => t.hasChildren), [true, true, false, false]);
  // The helper's own link to the issue is not a line of the tree, but stays in its words.
  assert.ok(tree[3].row.links.includes("Works on alexec/agents#12 · when it started"));
  assert.equal(tree[0].row.session, undefined);
});

test("a node the walk did not reach goes last, alone", () => {
  const stray = { kind: "issue", ref: "github:alexec/agents#99" };
  const tree = l.lineageTree(session, { ...graph, nodes: [...graph.nodes, stray] }, new Map(), title);
  assert.equal(tree.at(-1).row.node.ref, stray.ref);
  assert.equal(tree.at(-1).depth, 0);
  assert.deepEqual(l.lineageTree(session, { nodes: [session], links: [] }, new Map(), title), []);
});

test("the graph has a tier per kind, centred on the widest", () => {
  const g = l.lineageGraph(session, graph, new Map(), title);
  const at = (n) => { const b = g.nodes.find((x) => x.row.node.ref === n.ref); return [b.x, b.y]; };
  assert.deepEqual(at(issue), [114, 16]);
  assert.deepEqual(at(session), [16, 124]);
  assert.deepEqual(at(helper), [212, 124]);
  assert.deepEqual(at(pr), [114, 232]);
  assert.deepEqual(g.nodes.filter((n) => n.here).map((n) => n.row.name), ["This session"]);
  assert.deepEqual([g.width, g.height], [408, 300]);
  assert.deepEqual(g.edges.map((e) => e.label), ["works on", "started", "works on", "fixes"]);
  assert.deepEqual(g.edges.map((e) => e.ended), [false, false, false, true]);
  assert.deepEqual([g.edges[3].from, g.edges[3].to], [pr.ref, issue.ref]);
  assert.deepEqual(g.nodes.map((n) => n.detail), ["Issue", "Session", "Session", "Pull request"]);
  assert.deepEqual(l.lineageGraph(session, { nodes: [session], links: [] }, new Map(), title).nodes, []);
});

test("a line goes from tier to tier, or below its tier", () => {
  const g = l.lineageGraph(session, graph, new Map([[l.costKey(pr), rollup(pr, cost(4))]]), title);
  const p = (x, y) => ({ x, y });
  // This session (below) works on the issue (above): from its top to the issue's bottom.
  assert.deepEqual(l.curve(g, g.edges[0]), { start: p(106, 124), c1: p(106, 96), c2: p(204, 96), end: p(204, 68), mid: p(155, 96) });
  // This session started the helper, beside it in its tier: below them.
  assert.deepEqual(l.curve(g, g.edges[1]), { start: p(106, 176), c1: p(106, 216), c2: p(302, 216), end: p(302, 176), mid: p(204, 206) });
  assert.equal(g.nodes.find((n) => n.row.node.ref === pr.ref).detail, "Pull request · $4.00 · open");
  // With no PR, the sessions are the last tier, and the bend needs room.
  const noPR = l.lineageGraph(session, { nodes: [session, helper], links: [{ from: session, to: helper, rel: "started", source: "helper", at }] },
    new Map(), title);
  assert.equal(noPR.height, 16 + 52 + 40 + 16);
});

test("a tier follows the order of the boxes above it", () => {
  const other = { kind: "issue", ref: "github:alexec/agents#1" };
  const otherPR = { kind: "pr", ref: "github:alexec/agents#2" };
  // The walk gives #2 first, but it fixes #1, which is right of #12.
  const g = l.lineageGraph(session, { nodes: [session, issue, other, otherPR, pr], links: [
    { from: session, to: issue, rel: "works-on", source: "branch", at },
    { from: session, to: other, rel: "works-on", source: "branch", at },
    { from: otherPR, to: other, rel: "fixes", source: "pr-body", at },
    { from: pr, to: issue, rel: "fixes", source: "pr-body", at },
  ] }, new Map(), title);
  const prs = g.nodes.filter((n) => n.row.node.kind === "pr").sort((a, b) => a.x - b.x).map((n) => n.row.node.ref);
  assert.deepEqual(prs, [pr.ref, otherPR.ref]);
});
