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

test("an Azure Boards work item's row has its state's name, its project and Open on Azure Boards (#3815)", () => {
  const row = w.forgeRow(item(0, { node: { kind: "issue", ref: "azureboards:acme/web app#12" }, status: "Active" }), "mac");
  assert.equal(row.status, "Active");
  assert.equal(row.repo, "azureboards:acme/web app");
  assert.equal(w.repoName(row.repo), "Azure Boards · acme/web app");
  assert.equal(w.shortRef(row.node.ref), "#12");
  assert.equal(w.openOnWords(row.node.ref), "Open on Azure Boards");
});

test("a Forgejo pull request's row has its repo and Open on Forgejo (#3753)", () => {
  const row = w.forgeRow(item(0, { node: { kind: "pr", ref: "forgejo:walkalex/app#8" } }), "mac");
  assert.equal(row.repo, "forgejo:walkalex/app");
  assert.equal(w.repoName(row.repo), "walkalex/app");
  assert.equal(w.shortRef(row.node.ref), "#8");
  assert.equal(w.openOnWords(row.node.ref), "Open on Forgejo");
  assert.equal(w.forgeName(row.node.ref), "Forgejo");
  assert.equal(w.forgeName("pagure:a/b#1"), "the forge");
  assert.equal(w.errorWords({ forge: "forgejo", message: "not connected" }, "Studio"), "Forgejo on Studio: not connected");
});

test("a Bitbucket issue's row has its repo and Open on Bitbucket (#3786)", () => {
  const row = w.forgeRow(item(0, { node: { kind: "issue", ref: "bitbucket:walkalex/app#3" } }), "mac");
  assert.equal(row.repo, "bitbucket:walkalex/app");
  assert.equal(w.repoName(row.repo), "walkalex/app");
  assert.equal(w.shortRef(row.node.ref), "#3");
  assert.equal(w.openOnWords(row.node.ref), "Open on Bitbucket");
  assert.equal(w.errorWords({ forge: "bitbucket", message: "not connected" }, "Studio"), "Bitbucket on Studio: not connected");
});

test("an Azure DevOps pull request's row has its repo, Open on Azure DevOps and Labels (#3803)", () => {
  const row = w.forgeRow(item(0, { node: { kind: "pr", ref: "azuredevops:acme/web app/app#3" } }), "mac");
  assert.equal(row.repo, "azuredevops:acme/web app/app");
  assert.equal(w.repoName(row.repo), "acme/web app/app");
  assert.equal(w.shortRef(row.node.ref), "#3");
  assert.equal(w.openOnWords(row.node.ref), "Open on Azure DevOps");
  assert.equal(w.errorWords({ forge: "azuredevops", message: "not connected" }, "Studio"), "Azure DevOps on Studio: not connected");
  assert.equal(w.takesLabels(row.node), true);
});

test("a Bitbucket pull request's page has no Labels (#3881)", () => {
  assert.equal(w.takesLabels({ kind: "pr", ref: "bitbucket:walkalex/app#3" }), false);
  assert.equal(w.takesLabels({ kind: "issue", ref: "bitbucket:walkalex/app#3" }), true);
  assert.equal(w.takesLabels({ kind: "pr", ref: "github:alexec/Agents#12" }), true);
  assert.equal(w.takesLabels({ kind: "pr", ref: "forgejo:walkalex/app#2" }), true);
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

test("an issue, a PR, a milestone or a release has a page; a session has none", () => {
  assert.equal(w.hasPage({ kind: "milestone", ref: "github:alexec/Agents/milestone/15" }), true);
  assert.equal(w.hasPage({ kind: "session", ref: "session:S1" }), false);
});

test("a PR's checks and review in words", () => {
  const checks = [{ name: "a", state: "passing" }, { name: "b", state: "passing" }, { name: "c", state: "failing" }];
  assert.equal(w.checksWords(checks), "Checks: 2 passing, 1 failing");
  assert.equal(w.checksWords([], "none"), undefined);
  assert.equal(w.reviewWords("changes_requested"), "Review: Changes requested");
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

// Work's look (#4392, specs/4328-work-look/parts.md): the state icon, the row's line, the chip's colours, the empty states.
test("a row's state icon is the state's glyph, with words, and none for a milestone (#4392)", () => {
  assert.equal(w.stateGlyph("issue", "open"), "issue-open");
  assert.equal(w.stateGlyph("issue", "closed"), "issue-done");
  assert.equal(w.stateGlyph("issue", "closed", false, true), "issue-dropped");
  assert.equal(w.stateGlyph("pr", "open", true), "pr-draft");
  assert.equal(w.stateGlyph("pr", "open"), "pr-open");
  assert.equal(w.stateGlyph("pr", "merged"), "pr-merged");
  assert.equal(w.stateGlyph("pr", "closed"), "pr-closed");
  assert.equal(w.stateGlyph("milestone", "open"), undefined);
  assert.equal(w.stateGlyphWords["pr-merged"], "Merged pull request");
});

test("a row's second line: wide with the age, the author and lineage; short on a phone (#4392)", () => {
  const now = Date.parse("2026-10-30T12:00:00Z");
  const row = w.forgeRow(item(4328, { author: "alexec", comments: 3, status: "In Review" }), "mac", node(4328, 0.42));
  assert.equal(row.comments, 3);
  const line = w.rowLine(row, now);
  assert.equal(line.wide, "#4328 · In Review · updated 2 hours ago by alexec · 2 sessions · $0.42");
  assert.equal(line.short, "#4328 · In Review · 2 h · alexec · $0.42");
  const bare = w.rowLine(w.forgeRow(item(7, { author: "bob" }), "mac"), now);
  assert.equal(bare.wide, "#7 · updated 2 hours ago by bob");
});

test("a label chip's text has 4.5:1 to its fill, in light and dark; no colour, no chip colours (#4392)", () => {
  for (const color of ["d73a4a", "ffffff", "000000", "fbca04", "1D76DB", "0e8a16"]) {
    for (const scheme of ["light", "dark"]) {
      const c = w.chipColours(color, scheme);
      const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
      assert.ok(w.contrast(rgb(c.ink), rgb(c.fill)) >= 4.5, `${color} ${scheme}: ${c.ink} on ${c.fill}`);
    }
  }
  assert.equal(w.chipColours(undefined, "light"), undefined);
  assert.deepEqual(w.labelScope("feature:work"), ["feature:", "work"]);
  assert.equal(w.labelScope("bug"), undefined);
});

test("one login keeps one avatar colour (#4392)", () => {
  assert.equal(w.avatarHue("alexec"), w.avatarHue("alexec"));
  assert.notEqual(w.avatarHue("alexec"), w.avatarHue("bob"));
});

test("an empty list says no open issues, or no match with Clear filters, which keeps the state (#4392)", () => {
  const f = { ...w.anyFilter, state: "closed", label: "bug" };
  assert.equal(w.filtered(f), true);
  assert.equal(w.filtered(w.anyFilter), false);
  assert.deepEqual(w.clearedFilter(f), { ...w.anyFilter, state: "closed" });
  assert.deepEqual(w.emptyWords("issue", "open", false, ["github:alexec/Agents"]),
    { title: "No open issues", line: "Issues on alexec/Agents show here." });
  assert.deepEqual(w.emptyWords("pr", "open", true, []), { title: "No pull requests match" });
});

test("a forge that could not be read keeps its last rows, dimmed; a fresh read has none to carry (#4392)", async () => {
  const { carryStale } = await load("src/model/workLists.ts");
  const fj = (n) => item(n, { node: { kind: "issue", ref: `forgejo:acme/app#${n}` } });
  const had = { host: "mac", items: [item(1), fj(2)], errors: [] };
  const failed = carryStale({ host: "mac", items: [item(1)], errors: [{ forge: "forgejo", message: "down" }] }, had);
  assert.deepEqual(failed.items.map((i) => i.node.ref), ["github:alexec/Agents#1", "forgejo:acme/app#2"]);
  assert.deepEqual(failed.stale, ["forgejo:acme/app#2"]);
  const machine = carryStale({ host: "mac", items: [], errors: [{ forge: "", message: "offline" }] }, had);
  assert.equal(machine.items.length, 2);
  assert.equal(carryStale({ host: "mac", items: [], errors: [] }, had).items.length, 0);
  assert.equal(w.errorWords({ forge: "forgejo", message: "Forgejo: Get …: refused" }, undefined), "Forgejo: Get …: refused");
});

// The lists (#4395, specs/4328-work-look/lists.md), as WorkLookTests has them on the Mac (#4393).
test("a draft says so after its number; a closed draft does not (#4395)", () => {
  const now = Date.parse("2026-10-30T12:00:00Z");
  const pr = (extra) => w.forgeRow(item(4328, { node: { kind: "pr", ref: "github:alexec/Agents#4328" }, author: "alexec", draft: true, ...extra }), "mac");
  assert.equal(w.rowLine(pr({}), now).wide, "#4328 · Draft · updated 2 hours ago by alexec");
  assert.equal(w.rowLine(pr({}), now).short, "#4328 · Draft · 2 h · alexec");
  assert.equal(w.rowLine(pr({ state: "closed" }), now).short, "#4328 · 2 h · alexec");
});

test("the end of a list counts its rows, with + while more pages are there (#4395)", () => {
  assert.equal(w.countWords("issue", 128), "128 issues");
  assert.equal(w.countWords("issue", 50, true), "50+ issues");
  assert.equal(w.countWords("issue", 1), "1 issue");
  assert.equal(w.countWords("pr", 1), "1 pull request");
  assert.equal(w.countWords("pr", 1, true), "1+ pull requests");
  assert.equal(w.loadingMore(50), "Loading more… · 50 shown");
  assert.equal(w.couldNotRead("pr"), "Could not read pull requests");
});

test("an empty list says the filters that are set; none says nothing (#4395)", () => {
  assert.equal(w.setFilters(w.anyFilter), undefined);
  assert.equal(w.setFilters({ ...w.anyFilter, label: "bug", assignee: "alexec" }), "Label: bug · Assignee: alexec");
  assert.equal(w.setFilters({ ...w.anyFilter, text: " look ", project: "p1", repo: "github:alexec/Agents", board: "u" }, "Agents", "Roadmap"),
    "“look” · Project: Agents · Repo: alexec/Agents · Board: Roadmap");
});

test("a credential the forge refused offers Settings ▸ Connectors (#4395)", () => {
  assert.equal(w.credentialProblem("GitHub said 401 Bad credentials"), true);
  assert.equal(w.credentialProblem("GitHub is not connected"), true);
  assert.equal(w.credentialProblem("rate limit"), false);
});

test("the filters and the sort go in the address and back, only what is not the default (#4395)", () => {
  assert.equal(w.workQuery(w.anyFilter, "updated"), "");
  const f = { ...w.anyFilter, project: "agents", label: "bug", state: "closed", text: "a b" };
  const q = w.workQuery(f, "newest");
  assert.equal(q, "q=a+b&project=agents&state=closed&label=bug&sort=newest");
  assert.deepEqual(w.parseWorkQuery(q, "issue"), { filter: f, sort: "newest" });
  // A word the list does not know is left out: merged is a PR's state, a board is Issues' only.
  assert.deepEqual(w.parseWorkQuery("state=merged&sort=up", "issue"), { filter: w.anyFilter, sort: "updated" });
  assert.deepEqual(w.parseWorkQuery("state=merged&board=x", "pr"), { filter: { ...w.anyFilter, state: "merged" }, sort: "updated" });
  assert.equal(w.parseWorkQuery("board=x", "issue").filter.board, "x");
});

test("a next page a forge could not read keeps the rows and the cursor, and says so at the end (#4395)", async () => {
  const lists = await load("src/model/workLists.ts");
  const l = lists.workList("pr");
  l.lists.value = [{ host: "mac", items: [item(1)], cursor: "next", errors: [] }];
  let answer = { items: [], errors: [{ forge: "github", message: "GitHub said 502" }] };
  const store = { link: { call: async () => answer } };
  await lists.loadMore(store, l);
  assert.equal(l.moreFailed.value, "GitHub said 502");
  assert.equal(l.lists.value[0].cursor, "next");
  assert.equal(l.lists.value[0].items.length, 1);
  assert.equal(l.problem.value, null, "not the strip over the rows");
  answer = { items: [item(2)], errors: [] };
  await lists.loadMore(store, l);
  assert.equal(l.moreFailed.value, null);
  assert.equal(l.lists.value[0].items.length, 2);
  assert.equal(l.lists.value[0].cursor, undefined);
});

// The issue page's words (#4402), as WorkItemPage's on the window (#4400).
test("the state line says who opened it, when it was updated and how many comments, wide and narrow", () => {
  const now = new Date("2026-11-10T12:00:00Z");
  const updated = new Date("2026-11-10T10:00:00Z");
  assert.deepEqual(w.pageStateWords({ author: "alexec", updated, comments: 4 }, now),
    { wide: "alexec opened this · updated 2 hours ago · 4 comments", short: "alexec · 2 h · 4 comments" });
  assert.deepEqual(w.pageStateWords({ author: "sam", updated, comments: 1 }, now).wide, "sam opened this · updated 2 hours ago · 1 comment");
  assert.deepEqual(w.pageStateWords({ comments: 0 }, now), { wide: "", short: "" });
});

test("the 390 px bar says 3/42, and Lineage says the cost and the sessions", () => {
  assert.equal(w.shortPositionWords({ position: 3, count: 42 }, false), "3/42");
  assert.equal(w.shortPositionWords({ position: 3, count: 42 }, true), "3/42+");
  assert.equal(w.lineageCountWords("$0.42", 1), "$0.42 · 1 session");
  assert.equal(w.lineageCountWords(undefined, 2), "2 sessions");
  assert.equal(w.lineageCountWords(undefined, 0), "");
});
