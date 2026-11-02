// Work's lists (#3119), as WorkListTests has it on the window: one row per ref from every machine,
// lineage on top, the filters and the sorts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const w = await load("src/model/work.ts");

// Seconds since 2001, as the wire writes dates.
const at = (iso) => (Date.parse(iso) - Date.parse("2001-01-01T00:00:00Z")) / 1000;
const item = (n, extra = {}) => ({
  node: { kind: "issue", ref: `github:alexec/Agents#${n}` }, title: `Issue ${n}`, state: "open", labels: [], assignees: [],
  updatedAt: at("2026-10-30T10:00:00Z"), comments: 0, ...extra,
});
const cost = (usd) => ({ cost: usd ? { USD: usd } : {}, inputTokens: 0, outputTokens: 0, turns: 1, workingSeconds: 0, waitingSeconds: 0 });
const node = (n, usd, extra = {}) => ({
  node: { kind: "issue", ref: `github:alexec/Agents#${n}` }, cost: { own: cost(usd), total: cost(usd), waste: cost(0) },
  sessions: 2, lastAt: at("2026-10-30T10:00:00Z"), ...extra,
});

test("one row per ref, the last updated copy, with its lineage", () => {
  const rows = w.mergeForge([
    { host: "mac", items: [item(1), item(2, { title: "Old" })] },
    { host: "box", items: [item(2, { title: "New", updatedAt: at("2026-10-31T10:00:00Z") })] },
  ], [node(2, 4.1)]);
  assert.equal(rows.length, 2);
  const two = rows.find((r) => r.node.ref.endsWith("#2"));
  assert.equal(two.title, "New");
  assert.equal(two.host, "box");
  assert.equal(two.lineage.sessions, 2);
  assert.equal(rows.find((r) => r.node.ref.endsWith("#1")).lineage, undefined);
});

test("a row's lineage in words, none without", () => {
  assert.equal(w.lineageWords(undefined), undefined);
  const words = w.lineageWords(node(2, 4.1, { leadTimeSeconds: 86_400 + 4 * 3600, cost: { own: cost(4.1), total: cost(4.1), waste: cost(0.6) } }));
  assert.match(words, /^2 sessions · \$4\.10 · waste \$0\.60 · lead time 1d 4h$/);
  assert.equal(w.lineageWords({ ...node(3, 0), sessions: 0 }), undefined, "nothing worth saying");
});

test("filters: state, repo, label, assignee and words", () => {
  const rows = w.mergeForge([{ host: "mac", items: [
    item(1, { labels: [{ name: "bug", color: "d73a4a" }], assignees: ["alexec"] }),
    item(2, { state: "closed", title: "Flaky test" }),
    { ...item(3), node: { kind: "issue", ref: "github:alexec/Other#3" } },
  ] }], []);
  const f = (patch) => w.filterRows(rows, { ...w.anyFilter, ...patch }).map((r) => w.refNumber(r.node.ref));
  assert.deepEqual(f({}), [1, 3]);
  assert.deepEqual(f({ state: "closed" }), [2]);
  assert.deepEqual(f({ state: "all", repo: "github:alexec/Other" }), [3]);
  assert.deepEqual(f({ label: "bug" }), [1]);
  assert.deepEqual(f({ assignee: "alexec" }), [1]);
  assert.deepEqual(f({ state: "all", text: "flaky" }), [2]);
  assert.deepEqual(w.choices(rows).repos, ["github:alexec/Agents", "github:alexec/Other"]);
});

test("a merged PR is merged, not closed", () => {
  const pr = { ...w.forgeRow(item(5, { state: "merged" }), "mac"), node: { kind: "pr", ref: "github:alexec/Agents#5" } };
  assert.equal(w.stateMatches(pr, "merged"), true);
  assert.equal(w.stateMatches(pr, "closed"), false);
});

test("sorts: last updated, newest by number, cost with no lineage last", () => {
  const rows = w.mergeForge([{ host: "mac", items: [
    item(1, { updatedAt: at("2026-10-31T10:00:00Z") }), item(9), item(4, { updatedAt: at("2026-10-29T10:00:00Z") }),
  ] }], [node(4, 5), node(9, 1)]);
  const order = (s) => w.sortRows(rows, s).map((r) => w.refNumber(r.node.ref));
  assert.deepEqual(order("updated"), [1, 9, 4]);
  assert.deepEqual(order("newest"), [9, 4, 1]);
  assert.deepEqual(order("cost"), [4, 9, 1]);
});

test("refs: repo, short name, and the forge to open on", () => {
  assert.equal(w.repoOf("github:alexec/Agents#12"), "github:alexec/Agents");
  assert.equal(w.repoOf("gitlab:group/repo!45"), "gitlab:group/repo");
  assert.equal(w.repoOf("linear:ENG-4"), "linear");
  assert.equal(w.repoOf("github:alexec/Agents/milestone/15"), "github:alexec/Agents");
  assert.equal(w.shortRef("github:alexec/Agents#12"), "#12");
  assert.equal(w.shortRef("linear:ENG-4"), "ENG-4");
  assert.equal(w.openOnWords("gitlab:g/r!4"), "Open on GitLab");
});

test("a milestone lineage alone knows", () => {
  const row = w.lineageRow({ ...node(0, 2), node: { kind: "milestone", ref: "github:alexec/Agents/milestone/15" }, resolved: { title: "0.14 Lineage" } });
  assert.equal(row.title, "0.14 Lineage");
  assert.equal(row.url, "https://github.com/alexec/Agents/milestone/15");
});

test("a label's ink reads on its colour", () => {
  assert.equal(w.labelInk("ffffff"), "#1f2328");
  assert.equal(w.labelInk("#0e1f8a"), "#ffffff");
  assert.equal(w.labelColor("d73a4a"), "#d73a4a");
  assert.equal(w.labelColor(undefined), undefined);
});

test("a page's links by relation, from its own side, each other node once", () => {
  const issue = { kind: "issue", ref: "github:alexec/Agents#12" };
  const pr = { kind: "pr", ref: "github:alexec/Agents#34" };
  const milestone = { kind: "milestone", ref: "github:alexec/Agents/milestone/15" };
  const session = { kind: "session", ref: "session:S1" };
  const t = at("2026-10-30T10:00:00Z");
  const links = [
    { from: session, to: issue, rel: "works-on", source: "branch", at: t, endedAt: t },
    { from: session, to: issue, rel: "works-on", source: "start", at: t },
    { from: pr, to: issue, rel: "fixes", source: "pr-body", at: t },
    { from: issue, to: milestone, rel: "part-of", source: "forge", at: t },
    { from: pr, to: milestone, rel: "part-of", source: "forge", at: t },
  ];
  const groups = w.linkGroups(issue, links);
  assert.deepEqual(groups.map((g) => g.title), ["Fixed by", "Part of", "Worked on by"]);
  assert.deepEqual(groups[2].rows, [{ node: session, ended: false }], "the active link wins");
  assert.deepEqual(w.linkGroups(pr, links).map((g) => g.title), ["Fixes", "Part of"]);
  assert.equal(w.hasPage(milestone), true);
  assert.equal(w.hasPage(session), false);
});

test("a PR's checks, review and a page's cost in words", () => {
  const checks = [{ name: "a", state: "passing" }, { name: "b", state: "passing" }, { name: "c", state: "failing" }];
  assert.equal(w.checksWords(checks), "Checks: 2 passing, 1 failing");
  assert.equal(w.checksWords([], "none"), undefined);
  assert.equal(w.reviewWords("changes_requested"), "Review: Changes requested");
  const rollup = { node: { kind: "pr", ref: "x" }, own: cost(1.2), total: cost(3.4), waste: cost(0.3), unlinked: cost(0),
    prsMerged: 0, prsClosed: 0, prsReverted: 0, failedChecks: 2, parts: [] };
  assert.match(w.pageCostWords(rollup), /^Own \$1\.20 · total \$3\.40 · waste \$0\.30 · 2 failed checks$/);
  assert.equal(w.pageCostWords({ ...rollup, total: cost(0), failedChecks: 0 }), undefined);
  assert.equal(w.peopleWords({ author: "alexec", assignees: ["bob"], milestone: "0.14" }), "by alexec · assigned to bob · milestone 0.14");
});

test("a milestone's and a release's short name", () => {
  assert.equal(w.shortRef("github:example/shop/milestone/2"), "milestone 2");
  assert.equal(w.shortRef("github:example/shop/release/v1.2.0"), "v1.2.0");
  assert.equal(w.titleSaysRef({ title: "example/shop milestone 2", node: { kind: "milestone", ref: "github:example/shop/milestone/2" } }), true);
  assert.equal(w.titleSaysRef({ title: "1.2 Checkout", node: { kind: "milestone", ref: "github:example/shop/milestone/2" } }), false);
});
