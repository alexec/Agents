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

// #3089: a resolved node's real title is shown, and its state and labels when nothing is banked
// on it yet; once something is banked, the cost line's own state is shown instead.
test("a resolved node shows its title, state and labels", () => {
  const resolved = { ...graph, resolved: {
    [issue.ref]: { title: "Fix the flaky test", state: "open", labels: ["bug", "area:lineage"] },
    [pr.ref]: { title: "Fix it", state: "merged" },
  } };
  const rows = l.lineageRows(session, resolved, new Map(), (n) => n.ref === helper.ref ? "Helper" : undefined);
  // #3158: the number before the title, and the whole ref in the help.
  assert.deepEqual(rows.map((r) => r.name), ["#12 Fix the flaky test", "Helper", "#34 Fix it"]);
  assert.deepEqual(rows.map((r) => r.ref), ["alexec/agents#12", undefined, "alexec/agents#34"]);
  assert.deepEqual(rows.map((r) => r.resolved), ["open · bug, area:lineage", undefined, "merged"]);

  const costs = new Map([[l.costKey(issue), rollup(issue, cost(10))]]);
  const withCost = l.lineageRows(session, resolved, costs, (n) => n.ref === helper.ref ? "Helper" : undefined);
  assert.equal(withCost[0].resolved, "open · bug, area:lineage");

  const g = l.lineageGraph(session, resolved, new Map(), title);
  assert.equal(g.nodes.find((n) => n.row.node.ref === issue.ref).detail, "Issue · open · bug, area:lineage");
  assert.equal(g.nodes.find((n) => n.row.node.ref === issue.ref).row.name, "#12 Fix the flaky test");
});

// #3159: a merged PR's box says "merged" once: its cost line's state, not the forge's as well.
test("a PR's state shows once in its box", () => {
  const resolved = { ...graph, resolved: { [pr.ref]: { title: "Fix it", state: "merged", labels: ["bug"] } } };
  const banked = rollup(pr, cost(4), { parts: [{ node: pr, banked: cost(4), outcome: "merged", lastAt: at }] });
  const g = l.lineageGraph(session, resolved, new Map([[l.costKey(pr), banked]]), title);
  assert.equal(g.nodes.find((n) => n.row.node.ref === pr.ref).detail, "Pull request · $4.00 · merged · bug");
  const unbanked = l.lineageGraph(session, resolved, new Map(), title);
  assert.equal(unbanked.nodes.find((n) => n.row.node.ref === pr.ref).detail, "Pull request · merged · bug");
});

test("an issue, a PR, a milestone or a release on GitHub has its address; a session has none", () => {
  const rows = l.lineageRows(session, graph, new Map(), () => undefined);
  const url = (ref) => rows.find((r) => r.node.ref === ref).url;
  assert.equal(url(issue.ref), "https://github.com/alexec/agents/issues/12");
  assert.equal(url(pr.ref), "https://github.com/alexec/agents/pull/34");
  assert.equal(url(helper.ref), undefined);
  assert.equal(l.lineageUrl({ kind: "milestone", ref: "github:alexec/agents/milestone/15" }), "https://github.com/alexec/agents/milestone/15");
  assert.equal(l.lineageUrl({ kind: "release", ref: "github:alexec/agents/release/v0.14.0" }), "https://github.com/alexec/agents/releases/tag/v0.14.0");
});

// The graph (#3019), as LineageLayoutTests has it on the window.
const title = (n) => n.ref === helper.ref ? "Helper" : undefined;

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
  assert.deepEqual(g.edges[0].curve, { start: p(106, 124), c1: p(106, 96), c2: p(204, 96), end: p(204, 68), mid: p(155, 96) });
  // This session started the helper, beside it in its tier: below them.
  assert.deepEqual(g.edges[1].curve, { start: p(106, 176), c1: p(106, 216), c2: p(302, 216), end: p(302, 176), mid: p(204, 206) });
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

// Reports ▸ Lineage (#3087): the graph from any start, as LineageListTests has it on the window.
test("an issue as the start has its own name, and its links name it", () => {
  const title = (n) => n.ref === helper.ref ? "Helper" : n.ref === session.ref ? "Fix it" : undefined;
  const rows = l.lineageRows(issue, graph, new Map(), title);
  assert.deepEqual(rows.map((r) => r.name), ["Fix it", "Helper", "alexec/agents#34"]);
  assert.deepEqual(rows[0].links, ["Works on alexec/agents#12 · from the branch", "Started Helper · as a helper"]);
  assert.ok(!rows.some((r) => r.node.ref === issue.ref));
  const the = rows.find((r) => r.node.ref === pr.ref);
  assert.deepEqual(the.links, ["Fixes alexec/agents#12 · from the PR's text · ended"]);
  const start = l.startRow(issue, graph, new Map([[l.costKey(issue), rollup(issue, cost(2))]]), () => undefined);
  assert.equal(start.name, "alexec/agents#12");
  assert.equal(start.cost, "$2.00");
  assert.equal(start.url, "https://github.com/alexec/agents/issues/12");
  assert.deepEqual(start.links, []);
  const g = l.lineageGraph(issue, graph, new Map(), () => undefined);
  assert.deepEqual(g.nodes.filter((n) => n.here).map((n) => n.row.name), ["alexec/agents#12"]);
  assert.equal(l.startRow(session, graph, new Map(), () => undefined).name, "This session");
});

test("a typed start: a GitHub address, owner/repo#12 or a session's id", () => {
  assert.deepEqual(l.typedNode(" https://github.com/alexec/Agents/issues/12 "), { kind: "issue", ref: "github:alexec/Agents#12" });
  assert.deepEqual(l.typedNode("https://github.com/alexec/Agents/pull/34/files"), { kind: "pr", ref: "github:alexec/Agents#34" });
  assert.deepEqual(l.typedNode("https://github.com/alexec/Agents/milestone/15"), { kind: "milestone", ref: "github:alexec/Agents/milestone/15" });
  assert.deepEqual(l.typedNode("https://github.com/alexec/Agents/releases/tag/v0.14.0"),
    { kind: "release", ref: "github:alexec/Agents/release/v0.14.0" });
  assert.deepEqual(l.typedNode("alexec/Agents#12"), { kind: "issue", ref: "github:alexec/Agents#12" });
  assert.deepEqual(l.typedNode("github:alexec/Agents#12"), { kind: "issue", ref: "github:alexec/Agents#12" });
  assert.deepEqual(l.typedNode(S.toLowerCase()), session);
  assert.deepEqual(l.typedNode(`session:${S}`), session);
  for (const no of ["", "#12", "alexec/Agents", "https://gitlab.com/a/b/-/issues/1", "https://github.com/alexec/Agents/issues/x", "a b/c#1"]) {
    assert.equal(l.typedNode(no), undefined, no);
  }
});

test("the bare form may also be a pull request", () => {
  assert.deepEqual(l.typedPullRequest("alexec/Agents#12"), { kind: "pr", ref: "github:alexec/Agents#12" });
  assert.deepEqual(l.typedPullRequest(" github:alexec/Agents#12 "), { kind: "pr", ref: "github:alexec/Agents#12" });
  for (const no of ["https://github.com/alexec/Agents/issues/12", "https://github.com/alexec/Agents/pull/12",
    "https://github.com/alexec/Agents/milestone/15", `session:${S}`, "alexec/Agents"]) {
    assert.equal(l.typedPullRequest(no), undefined, no);
  }
});

test("the starts go back and forward as a browser's", () => {
  const same = (a, b) => a === b;
  let h = l.emptyHistory();
  assert.equal(l.currentStart(h), undefined);
  h = l.goTo(h, "a", same); h = l.goTo(h, "b", same); h = l.goTo(h, "b", same);
  assert.deepEqual(h, { places: ["a", "b"], at: 1 });
  h = l.goBack(h);
  assert.equal(l.currentStart(h), "a");
  assert.equal(l.goBack(h), h);
  h = l.goTo(h, "c", same);
  assert.deepEqual(h, { places: ["a", "c"], at: 1 });
  assert.equal(l.goForward(h), h);
  for (let i = 0; i < 60; i++) h = l.goTo(h, `n${i}`, same);
  assert.equal(h.places.length, l.mostStarts);
  assert.equal(l.currentStart(h), "n59");
});

test("a session's machine is found among every machine's sessions, not only the newest (#3156)", () => {
  const many = Array.from({ length: 20 }, (_, i) => ({ id: `old-${i}` }));
  const agents = { mac: many, linux: [{ id: "a" }, { id: S }] };
  assert.equal(l.sessionHost(agents, S), "linux");
  assert.equal(l.sessionHost(agents, "old-19"), "mac");
  assert.equal(l.sessionHost(agents, "nowhere"), undefined);
});
