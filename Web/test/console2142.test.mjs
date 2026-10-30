// The web console's look (#2142): a table's sort and its kept order, the top bar's search, and the
// breadcrumb over each page.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const sort = await load("src/model/sort.ts");
const search = await load("src/model/search.ts");
const crumbs = await load("src/model/crumbs.ts");

test("a table sorts words by their sense, numbers as numbers, and nothing last both ways", () => {
  const rows = [{ n: "build-10", v: 3 }, { n: "Build-2", v: undefined }, { n: "alpha", v: 12 }, { n: "", v: 1 }];
  assert.deepEqual(sort.sortRows(rows, (r) => r.n, "asc").map((r) => r.n), ["alpha", "Build-2", "build-10", ""]);
  assert.deepEqual(sort.sortRows(rows, (r) => r.n, "desc").map((r) => r.n), ["build-10", "Build-2", "alpha", ""]);
  assert.deepEqual(sort.sortRows(rows, (r) => r.v, "asc").map((r) => r.v), [1, 3, 12, undefined]);
  assert.deepEqual(sort.sortRows(rows, (r) => r.v, "desc").map((r) => r.v), [12, 3, 1, undefined]);
  assert.deepEqual(rows.map((r) => r.n), ["build-10", "Build-2", "alpha", ""], "the rows given are not changed");
});

test("equal rows keep their order", () => {
  const rows = [{ k: "a", i: 1 }, { k: "b", i: 2 }, { k: "a", i: 3 }];
  assert.deepEqual(sort.sortRows(rows, (r) => r.k, "asc").map((r) => r.i), [1, 3, 2]);
  assert.deepEqual(sort.sortRows(rows, (r) => r.k, "desc").map((r) => r.i), [2, 1, 3]);
});

test("a header sorts its column its first way, then the other way", () => {
  const by = { column: "name", dir: "asc" };
  assert.deepEqual(sort.nextOrder(by, "name"), { column: "name", dir: "desc" });
  assert.deepEqual(sort.nextOrder({ column: "name", dir: "desc" }, "name"), { column: "name", dir: "asc" });
  assert.deepEqual(sort.nextOrder(by, "cost", "desc"), { column: "cost", dir: "desc" });
  assert.deepEqual(sort.nextOrder(by, "state"), { column: "state", dir: "asc" });
});

test("with no tab storage, a table keeps its own order", () => {
  assert.deepEqual(sort.keptOrder("machines", { column: "name", dir: "asc" }, ["name"]), { column: "name", dir: "asc" });
  sort.keepOrder("machines", { column: "name", dir: "desc" });
});

const host = (id, name) => ({ id, name, platform: "macOS" });
const placed = (h, folderName, id, title) => ({ host: h, folder: { name: folderName, folder: { folder: `file:///${folderName}/` } }, agent: { id, title } });

test("search finds pages, machines and sessions by name, the best first", () => {
  const studio = host("m1", "Studio");
  const sessions = [placed(studio, "api", "s1", "Fix login redirect"), placed(studio, "web", "s2", "Runtime badge")];
  const found = search.searchFound("run", true, [studio, host("m2", "runner-01")], sessions);
  assert.deepEqual(found.map((f) => [f.kind, f.title, f.detail]), [
    ["page", "Runtimes", "Machines"], ["page", "Runtimes", "Reports"], ["machine", "runner-01", "Machine · macOS"], ["session", "Runtime badge", "web · Studio"]],
  "names starting with the words, pages before machines before sessions");
  assert.deepEqual(found.find((f) => f.kind === "session").to, { host: "m1", folder: "file:///web/", session: "s2" });
  assert.deepEqual(found.find((f) => f.kind === "machine").to, { nav: "machines" });
  assert.deepEqual(found.find((f) => f.title === "Runtimes" && f.detail === "Machines").to, { nav: "machines", section: "runtimes" });
});

test("search matches a word inside a name, and says nothing for no words", () => {
  const studio = host("m1", "Studio");
  const found = search.searchFound("login", false, [studio], [placed(studio, "api", "s1", "Fix login redirect")]);
  assert.deepEqual(found.map((f) => [f.title, f.detail]), [["Fix login redirect", "api · Studio"]]);
  assert.deepEqual(search.searchFound("  ", true, [studio], []), []);
});

test("a member's search finds no admin page; an admin's does", () => {
  assert.equal(search.searchFound("audit", false, [], []).length, 0);
  assert.deepEqual(search.searchFound("audit", true, [], []).map((f) => [f.title, f.detail]), [["Audit", "Reports"]]);
  assert.equal(search.searchFound("people", false, [], []).length, 0, "nor the People section");
  assert.deepEqual(search.searchFound("overview", false, [], [])[0].to, {});
});

test("search lists at most eight", () => {
  const studio = host("m1", "Studio");
  const many = Array.from({ length: 20 }, (_, i) => placed(studio, "api", `s${i}`, `Task ${i}`));
  assert.equal(search.searchFound("task", true, [], many).length, search.foundLimit);
});

test("a page's breadcrumb is its section, then the page; a page named as its section is one part", () => {
  assert.deepEqual(crumbs.pageCrumbs("machines", "Runtimes"), [{ title: "Machines", to: { nav: "machines" } }, { title: "Runtimes" }]);
  assert.deepEqual(crumbs.pageCrumbs("machines", "Machines"), [{ title: "Machines" }]);
  assert.equal(crumbs.sectionOfActivity("runtimes"), "machines");
  assert.equal(crumbs.sectionOfActivity("events"), "reports");
  assert.equal(crumbs.sectionOfActivity("spending"), undefined, "Usage's panes are drawn in Usage");
});

test("the person's initial", () => {
  assert.equal(crumbs.initialOf("bea lopez"), "B");
  assert.equal(crumbs.initialOf("  Émile"), "É");
  assert.equal(crumbs.initialOf("@3po"), "3");
  assert.equal(crumbs.initialOf(undefined), "•");
  assert.equal(crumbs.initialOf(""), "•");
});
