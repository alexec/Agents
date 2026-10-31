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

test("the nodes in groups by kind, the session itself left out", () => {
  const groups = l.lineageGroups(session, graph, new Map(), (n) => n.ref === helper.ref ? "Helper" : undefined);
  assert.deepEqual(groups.map((g) => [g.title, g.rows.map((r) => r.name)]),
    [["Issues", ["alexec/agents#12"]], ["Pull Requests", ["alexec/agents#34"]], ["Sessions", ["Helper"]]]);
  const [issueRow] = groups[0].rows;
  assert.deepEqual(issueRow.links, ["This session works on it · from the branch", "Helper works on it · when it started",
    "alexec/agents#34 fixes it · from the PR's text · ended"]);
  assert.deepEqual(groups[1].rows[0].links, ["Fixes alexec/agents#12 · from the PR's text · ended"]);
  assert.equal(groups[2].rows[0].session, T);
  assert.deepEqual(groups[2].rows[0].links[0], "This session started it · as a helper");
  const run = { kind: "workflow-run", ref: "run:nightly" };
  const started = l.lineageGroups(session, { nodes: [session, run], links: [{ from: run, to: session, rel: "started", source: "start", at }] },
    new Map(), () => undefined);
  assert.deepEqual(started[0].rows[0].links, ["Started this session · when it started"]);
});

test("an issue's and a PR's cost, with how the PRs ended", () => {
  const costs = new Map([
    [l.costKey(issue), rollup(issue, cost(10, 720), { prsMerged: 1, prsClosed: 1, waste: cost(3) })],
    [l.costKey(pr), rollup(pr, cost(4), { parts: [{ node: pr, banked: cost(4), outcome: "closed", lastAt: at }] })],
  ]);
  const groups = l.lineageGroups(session, graph, costs, () => undefined);
  assert.equal(groups[0].rows[0].cost, "$10.00 · 12m working · 1 merged, 1 closed · $3.00 wasted");
  assert.equal(groups[1].rows[0].cost, "$4.00 · closed without a merge: waste");
  assert.equal(l.costLine(rollup(pr, cost(1))), "$1.00 · open");
  assert.equal(l.costLine(rollup(pr, cost(0, 3))), "3s working · open");
  assert.equal(l.costLine(rollup(issue, cost(0))), "Nothing banked yet");
});

test("only issues and PRs are costed", () => {
  assert.ok(l.costed(issue) && l.costed(pr));
  assert.ok(!l.costed(helper));
});

test("an issue, a PR or a milestone on GitHub has its address; a session has none", () => {
  const rows = l.lineageGroups(session, graph, new Map(), () => undefined).flatMap((g) => g.rows);
  const url = (ref) => rows.find((r) => r.node.ref === ref).url;
  assert.equal(url(issue.ref), "https://github.com/alexec/agents/issues/12");
  assert.equal(url(pr.ref), "https://github.com/alexec/agents/pull/34");
  assert.equal(url(helper.ref), undefined);
  assert.equal(l.lineageUrl({ kind: "milestone", ref: "github:alexec/agents/milestone/15" }), "https://github.com/alexec/agents/milestone/15");
});
