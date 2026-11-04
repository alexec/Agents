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

test("a Jira issue's row has its status and the tracker jira (#3260)", () => {
  const row = w.forgeRow(item(0, { node: { kind: "issue", ref: "jira:PROJ-7" }, status: "In Review" }), "mac");
  assert.equal(row.status, "In Review");
  assert.equal(row.state, "open");
  assert.equal(row.repo, "jira");
  assert.equal(w.repoName(row.repo), "Jira");
  assert.equal(w.repoName("github:alexec/Agents"), "alexec/Agents");
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
  // #3311: a Linear issue's repo is its team, a choice of the Repo filter of its own.
  assert.equal(w.repoOf("linear:ENG-4"), "linear:ENG");
  assert.equal(w.repoName("linear:ENG"), "Linear · ENG");
  assert.equal(w.lineageRow(node(0, 0, { node: { kind: "issue", ref: "linear:OPS-2" }, repo: "linear" })).repo, "linear:OPS");
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

// #3130: the page's actions say what each does, as WorkListTests has it on the window.
test("the merge button says its method, and waits while checks run", () => {
  assert.equal(w.mergeButton("squash", false), "Squash and merge");
  assert.equal(w.mergeButton(undefined, true), "Merge when checks pass");
  const pr = (checks, list) => ({ item: { ...item(1), checks }, body: "", comments: [], checks: list });
  assert.equal(w.mergeWaits(pr("running")), true);
  assert.equal(w.mergeWaits(pr("passing", [{ name: "a", state: "running" }])), true);
  assert.equal(w.mergeWaits(pr("passing", [{ name: "a", state: "passing" }])), false);
  assert.deepEqual(w.failedChecks(pr("failing", [{ name: "a", state: "failing" }, { name: "b", state: "passing" }])).map((c) => c.name), ["a"]);
});

test("a write says what it did", () => {
  assert.equal(w.doneWords("forge/merge", { auto: true }), "Auto-merge is on: it merges when its checks pass.");
  assert.equal(w.doneWords("forge/merge", {}), "Merged.");
  assert.equal(w.doneWords("forge/rerun", { reran: 2 }), "2 runs started again.");
  assert.equal(w.doneWords("forge/close", {}), "Closed.");
  assert.equal(w.doneWords("forge/close", {}, true), "Reopened.");
  assert.equal(w.doneWords("forge/close", {}, false, true), "Status changed.");
  assert.equal(w.closeTitle("open"), "Close");
  assert.equal(w.closeTitle("closed"), "Reopen");
});

test("previous and next are the rows above and below in the list shown (#3257)", () => {
  const rows = w.sortRows(w.mergeForge([{ host: "mac", items: [item(1), item(2), item(3)] }], []), "newest");
  const refs = rows.map((r) => r.node.ref);
  const first = w.neighbours(refs[0], rows);
  assert.deepEqual(first, { previous: undefined, next: refs[1], position: 1, count: 3 });
  const last = w.neighbours(refs[2], rows);
  assert.equal(last.next, undefined);
  assert.equal(last.previous, refs[1]);
  assert.equal(w.positionWords(last, true), "3 of 3+");
  assert.equal(w.positionWords(w.neighbours(refs[1], rows), false), "2 of 3");
  // A row the filters leave out has no place in the list.
  assert.equal(w.neighbours(refs[1], w.filterRows(rows, { ...w.anyFilter, text: "Issue 3" })), undefined);
});

// #3282: a project's boards narrow Issues and Features, on the machines that know boards.
test("the boards of several machines are one list, each once by url, the first name kept", () => {
  const a = { name: "Platform", url: "https://github.com/orgs/acme/projects/7", forge: "github", key: "acme/7" };
  const b = { name: "Mobile", url: "https://linear.app/acme/team/MOB" };
  const merged = w.mergeBoards([[a], [{ ...a, name: "Other name" }, b], []]);
  assert.deepEqual(merged.map((x) => [x.name, x.url]), [["Platform", a.url], ["Mobile", b.url]]);
  assert.deepEqual(w.mergeBoards([]), []);
});

test("the Board menu offers each board by its name, and keeps one chosen that no machine lists now", () => {
  const boards = [{ name: "Platform", url: "https://github.com/orgs/acme/projects/7" }];
  assert.deepEqual(w.boardChoices(boards, ""), [boards[0].url]);
  assert.deepEqual(w.boardChoices(boards, boards[0].url), [boards[0].url]);
  assert.deepEqual(w.boardChoices(boards, "https://linear.app/acme/team/OLD"), [boards[0].url, "https://linear.app/acme/team/OLD"]);
  assert.equal(w.boardName(boards, boards[0].url), "Platform");
  assert.equal(w.boardName(boards, "https://linear.app/acme/team/OLD"), "https://linear.app/acme/team/OLD");
});

test("a list's request carries the board only when one is chosen", () => {
  assert.equal(w.anyFilter.board, "");
  assert.deepEqual(w.forgeListRequest("open", ""), { state: "open", limit: 100 });
  assert.deepEqual(w.forgeListRequest("all", "https://github.com/orgs/acme/projects/7", "c2"),
    { state: "all", limit: 100, cursor: "c2", board: "https://github.com/orgs/acme/projects/7" });
  assert.deepEqual(w.withBoard({}, ""), {});
  assert.deepEqual(w.withBoard({ state: "open", feature: "work" }, "u"), { state: "open", feature: "work", board: "u" });
  // The board is the machines' to narrow: the rows are not filtered by it again here.
  const rows = w.mergeForge([{ host: "mac", items: [item(1)] }], []);
  assert.equal(w.filterRows(rows, { ...w.anyFilter, board: "https://github.com/orgs/acme/projects/7" }).length, 1);
});

test("a project has the repos its folders read on every machine, and the Project filter shows them (#3283)", () => {
  const read = (n, repo, folder) => item(n, { node: { kind: "issue", ref: `github:${repo}#${n}` }, folder });
  const agents = { id: "p1", name: "Agents", folders: new Set([w.workFolderKey("mac", "file:///Users/a/Agents/"), w.workFolderKey("box", "/home/a/Agents")]) };
  const www = { id: "p2", name: "www", folders: new Set([w.workFolderKey("mac", "/Users/a/www")]) };
  const quiet = { id: "p3", name: "quiet", folders: new Set([w.workFolderKey("mac", "/Users/a/quiet")]) };
  const lists = [
    { host: "mac", items: [read(1, "alexec/Agents", "/Users/a/Agents"), read(2, "alexec/www", "/Users/a/www")] },
    { host: "box", items: [read(3, "alexec/docs", "/home/a/Agents")] },
  ];
  const projects = w.projectRepos([agents, www, quiet], lists);
  // A project whose folders read nothing is not offered.
  assert.deepEqual(projects.map((p) => p.project.name), ["Agents", "www"]);
  assert.deepEqual([...projects[0].repos].sort(), ["github:alexec/Agents", "github:alexec/docs"]);

  const rows = w.mergeForge(lists, []);
  const refs = (project) => w.filterRows(rows, { ...w.anyFilter, project }, projects).map((r) => r.node.ref).sort();
  assert.deepEqual(refs("p1"), ["github:alexec/Agents#1", "github:alexec/docs#3"]);
  assert.deepEqual(refs("p2"), ["github:alexec/www#2"]);
  assert.deepEqual(refs("p3"), []);
  assert.equal(w.filterRows(rows, w.anyFilter, projects).length, 3);

  assert.equal(w.projectOfFolder("/home/a/Agents", "box", [agents, www])?.name, "Agents");
  assert.equal(w.projectOfFolder("/home/a/Agents", "mac", [agents, www]), undefined);
  assert.equal(w.projectOfFolder(undefined, "mac", [agents]), undefined);
  assert.equal(w.projectWords("Agents"), "Project Agents");
});
