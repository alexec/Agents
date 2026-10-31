// Reports ▸ Value's words (#2351), as ReportValueWordsTests has them on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const v = await load("src/model/value.ts");

const cost = (usd, tokens = 0) => ({ cost: usd ? { USD: usd } : {}, inputTokens: tokens, outputTokens: 0, turns: 1, workingSeconds: 0, waitingSeconds: 0 });

test("a node is named without its tracker, as the window names it", () => {
  assert.equal(v.nodeName({ kind: "issue", ref: "github:alexec/agents#12" }), "alexec/agents#12");
  assert.equal(v.nodeName({ kind: "issue", ref: "linear:ENG-4" }), "ENG-4");
  assert.equal(v.nodeName({ kind: "milestone", ref: "github:alexec/agents/milestone/15" }), "alexec/agents milestone 15");
});

test("the headline, the waste and the lead time", () => {
  const value = { range: "month", scope: { kind: "me" }, total: cost(10), waste: cost(3), unlinked: cost(0), perMergedPR: { USD: 5 },
    prsMerged: 2, prsClosed: 1, prsReverted: 0, failedChecks: 2, leadTimeSeconds: 19 * 3600, issues: [], milestones: [] };
  assert.match(v.valueHeadline(value), /^\$10\.00 on issues and pull requests · 2 merged · \$5\.00 a merged pull request$/);
  assert.equal(v.wasteLine(value), "$3.00 wasted: 1 closed without a merge · 2 failed CI rounds");
  assert.equal(v.wasteLine({ ...value, prsClosed: 0, failedChecks: 0 }), "Nothing wasted");
  assert.match(v.leadLine(value), /^19h from the first work/);
  assert.equal(v.leadLine({ ...value, leadTimeSeconds: undefined }), undefined);
  assert.equal(v.unlinkedLine(value), undefined);
  assert.match(v.unlinkedLine({ ...value, unlinked: cost(0, 1200) }), /tokens on turns with no issue/);
});

test("an issue's line", () => {
  const row = { node: { kind: "issue", ref: "github:o/r#1" }, total: cost(10), waste: cost(3), prsMerged: 1, prsClosed: 1, prsReverted: 0,
    failedChecks: 1, leadTimeSeconds: 3600 };
  assert.equal(v.rowLine(row), "$10.00 · 1 merged, 1 closed · $3.00 wasted · 1 failed CI round · 1h to merge");
  assert.equal(v.rowLine({ ...row, prsMerged: 0, prsClosed: 0, waste: cost(0), failedChecks: 0, leadTimeSeconds: undefined }), "$10.00 · Not merged yet");
});

test("a GitHub issue's or milestone's address, as ReportValueWords.url has it; none for another tracker", () => {
  assert.equal(v.nodeUrl({ kind: "issue", ref: "github:alexec/agents#12" }), "https://github.com/alexec/agents/issues/12");
  assert.equal(v.nodeUrl({ kind: "milestone", ref: "github:alexec/agents/milestone/15" }), "https://github.com/alexec/agents/milestone/15");
  assert.equal(v.nodeUrl({ kind: "issue", ref: "linear:ENG-4" }), undefined);
  assert.equal(v.nodeUrl({ kind: "issue", ref: "github:alexec/agents#x" }), undefined);
});
