// Docs (#3321, spec 3319), as DocsListTests has it on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const d = await load("src/model/docs.ts");
const nav = await load("src/model/nav.ts");
const route = await load("src/route.ts");

const wire = (ms) => (ms - Date.UTC(2001, 0, 1)) / 1000;
const now = new Date(Date.UTC(2026, 10, 3, 12));
const hoursAgo = (h) => wire(now.getTime() - h * 3600_000);
const folder = (id, name) => ({ id, kind: "folder", name, folder: id, state: "read" });
const doc = (path, title, source, updated) => ({ ref: `github:alexec/agents/doc/${path}`, title, source, path, folder: source, ...updated === undefined ? {} : { updated } });

const agents = folder("/Users/a/Agents", "Agents");
const confluence = { id: "mcp:confluence", kind: "connector", name: "confluence", folder: agents.id, state: "read" };
const notion = { id: "mcp:notion", kind: "connector", name: "notion", folder: agents.id, state: "notMapped" };
const mac = {
  host: "mac", name: "Mac",
  sources: [agents, confluence, notion],
  docs: [
    doc("specs/3319-docs/spec.md", "Docs, first-class beside Work", agents.id, hoursAgo(2)),
    doc("specs/3265-work-plans/spec.md", "Plans in Work", agents.id, hoursAgo(24)),
    doc("docs/explanation/leases.md", "Leases", agents.id, hoursAgo(72)),
    doc("README.md", "Agents", agents.id, hoursAgo(120)),
    { ref: "confluence:acme.atlassian.net/1", title: "Payments: requirements", source: "mcp:confluence", url: "https://acme/1", updated: hoursAgo(168) },
  ],
};

test("a folder's docs go by subfolder, its top last; then each connector", () => {
  const groups = d.docsGroups([mac], "updated");
  assert.deepEqual(groups.map((g) => g.heading), ["Agents", "confluence", "notion"]);
  assert.deepEqual(groups[0].shelves.map((s) => s.dir), ["docs/", "specs/", ""]);
  assert.deepEqual(groups[0].shelves[1].docs.map((x) => d.underShelf(x, "specs/")), ["3319-docs/spec.md", "3265-work-plans/spec.md"]);
  assert.deepEqual(groups[1].shelves.map((s) => s.docs.length), [1]);
  assert.deepEqual(groups[2].shelves, []);
  assert.equal(d.sourceProblem(notion), "not mapped");
});

test("Sort by title, and Source to one", () => {
  const specs = d.docsGroups([mac], "title")[0].shelves[1].docs.map((x) => x.title);
  assert.deepEqual(specs, ["Docs, first-class beside Work", "Plans in Work"]);
  const only = d.docsGroups([mac], "updated", "mcp:confluence");
  assert.deepEqual(only.map((g) => g.key), ["mcp:confluence"]);
});

test("one connector on two machines is one source; each machine's folder is its own", () => {
  const studio = { host: "studio", name: "Studio", sources: [folder("/Users/a/Agents", "Agents"), confluence], docs: [] };
  const rows = d.mergeSources([mac, studio]);
  assert.deepEqual(rows.map((r) => r.heading), ["Agents (Mac)", "Agents (Studio)", "confluence", "notion"]);
  assert.deepEqual(rows.filter((r) => r.key === "mcp:confluence").map((r) => r.host), ["mac"]);
});

test("a row says the path of a folder doc and the title of a connector doc", () => {
  assert.equal(d.shortForm(mac.docs[0]), "specs/3319-docs/spec.md");
  assert.equal(d.shortForm(mac.docs[4]), "Payments: requirements");
  assert.equal(d.titleBeside(mac.docs[0]), "Docs, first-class beside Work");
  assert.equal(d.titleBeside(doc("NOTES.md", "NOTES.md", agents.id)), undefined);
  assert.equal(d.updatedWords(mac.docs[0], now), "2h ago");
  assert.equal(d.updatedWords(mac.docs[4], now), "1w ago");
  assert.equal(d.isFolderDoc(mac.docs[0]), true);
  assert.equal(d.isFolderDoc(mac.docs[4]), false);
});

test("a connector doc opens in its vendor's app", () => {
  assert.equal(d.vendorName("confluence:acme.atlassian.net/1"), "Confluence");
  assert.equal(d.vendorName("gdrive:1AbC"), "Google Drive");
  assert.equal(d.vendorName("mcp:wiki/handbook-42"), "wiki");
  assert.equal(d.windowAddress("notion:1f2e"), "agents://docs/notion:1f2e");
});

test("search results from every machine, each doc once, the most matches first", () => {
  const a = { doc: mac.docs[0], matches: [{ line: 3, snippet: "docs" }] };
  const b = { doc: mac.docs[1], matches: [{ line: 1, snippet: "x" }, { line: 9, snippet: "y" }] };
  const merged = d.mergeResults([{ host: "mac", results: [a, b] }, { host: "studio", results: [a] }]);
  assert.deepEqual(merged.map((r) => [r.doc.title, r.host]), [["Plans in Work", "mac"], ["Docs, first-class beside Work", "mac"]]);
});

test("Docs is in the bar after Work, and #/docs/<ref> is a doc's page", () => {
  assert.equal(nav.navSections.indexOf("docs"), nav.navSections.indexOf("work") + 1);
  assert.equal(nav.sectionKeys.d, "docs");
  const ref = "github:alexec/agents/doc/specs/3319-docs/spec.md";
  const hash = route.routeHash({ nav: "docs", section: "docs", item: ref });
  assert.equal(hash, `#/docs/${encodeURIComponent(ref)}`);
  assert.deepEqual(route.parseRoute(hash), { nav: "docs", section: "docs", item: ref });
  assert.deepEqual(route.parseRoute("#/docs"), { nav: "docs" });
});

// Start Agent on a doc and the Docs section on Work's pages (#3322), as DocsStartTests has them.
const specDoc = doc("specs/3319-docs/spec.md", "Docs", agents.id);

test("Build this names the doc in its prompt and labels the session doc:<short form>", () => {
  assert.ok(d.docStartPrompt("build", specDoc.ref).includes(specDoc.ref));
  assert.ok(d.docStartPrompt("build", specDoc.ref).includes("docs_read"));
  assert.deepEqual(d.docStartLabels("build", specDoc), ["doc:3319-docs/spec.md"]);
  assert.deepEqual(d.docStartLabels("review", specDoc), []);
  assert.deepEqual(d.docStartLabels("ask", specDoc), []);
  assert.deepEqual(d.docStarts.map((s) => d.docStartTitle[s]), ["Build this", "Review this", "Ask about this"]);
});

test("The doc: label fits a session label: whole path parts, a file name's end, a title's start", () => {
  assert.equal(d.docLabel({ path: "README.md", title: "x" }), "doc:README.md");
  assert.equal(d.docLabel({ path: "docs/explanation/leases.md", title: "x" }), "doc:leases.md");
  assert.equal(d.docLabel({ path: "specs/a-very-long-file-name-here.md", title: "x" }), "doc:ng-file-name-here.md");
  assert.equal(d.docLabel({ title: "Payments: requirements and more" }), "doc:Payments: requiremen");
});

test("An item's body names docs by ref, by address and by a specs/ or docs/ path of its repo", () => {
  const body = `Spec: \`specs/3319-docs/spec.md\`, "A doc's page". See also docs/explanation/leases.md.
The page: #/docs/github%3Aalexec%2Fagents%2Fdoc%2FREADME.md and agents://docs/confluence:acme.atlassian.net/123.
Raw: github:alexec/agents/doc/specs/3265-work-plans/spec.md, notion:1f2e.
Not these: https://github.com/alexec/Agents/blob/main/specs/0001/spec.md, src/docs/x.md, specs/3319-docs/spec.md again.`;
  assert.deepEqual(d.linkedRefs(body, "github:alexec/agents#3322"), [
    "github:alexec/agents/doc/specs/3319-docs/spec.md",
    "github:alexec/agents/doc/docs/explanation/leases.md",
    "github:alexec/agents/doc/README.md",
    "confluence:acme.atlassian.net/123",
    "github:alexec/agents/doc/specs/3265-work-plans/spec.md",
    "notion:1f2e",
  ]);
  assert.deepEqual(d.linkedRefs("specs/a.md and notion:9", "linear:ENG-4"), ["notion:9"]);
  assert.equal(d.repoPrefix("gitlab:acme/web!12"), "gitlab:acme/web/doc/");
});

test("A title is searched by its longest uncommon words, and the docs most of them find come first", () => {
  assert.deepEqual(d.searchWords("Docs 3: Start Agent on a doc, and a Docs section on Work's issue and PR pages"),
    ["section", "start", "agent", "issue"]);
  const [a, b, c, linked] = ["a.md", "b.md", "c.md", "l.md"].map((p) => doc(p, "A doc", agents.id));
  const r = (x, n) => ({ doc: x, matches: Array.from({ length: n }, () => ({ line: 1, snippet: "x" })) });
  const got = d.relatedDocs([[r(a, 1), r(linked, 9)], [r(b, 5), r(a, 1)], [r(c, 1), r(b, 1)]], new Set([linked.ref]));
  assert.deepEqual(got.map((x) => x.ref), [b.ref, a.ref, c.ref]);
});
