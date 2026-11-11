// A release in the Work look (#4423), as WorkReleaseLookTests has it on the window (#4421): versions, the latest, the
// release before, the state line, its pull requests and its pipeline from lineage.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const w = await load("src/model/work.ts");
const r = await load("src/model/workRelease.ts");

const at = (iso) => (Date.parse(iso) - Date.parse("2001-01-01T00:00:00Z")) / 1000;
const ref = (tag, repo = "alexec/Agents") => `github:${repo}/release/${tag}`;
const cost = (usd) => ({ cost: usd ? { USD: usd } : {}, inputTokens: 0, outputTokens: 0, turns: 1, workingSeconds: 0, waitingSeconds: 0 });
const release = (tag, repo) => w.lineageRow({
  node: { kind: "release", ref: ref(tag, repo) }, cost: { own: cost(0), total: cost(0), waste: cost(0) }, sessions: 0, lastAt: at("2026-11-10T10:00:00Z"),
});

test("a version tag's numbers, and which is newer", () => {
  assert.deepEqual(w.version("v0.42.0"), [0, 42, 0]);
  assert.deepEqual(w.version("1.2"), [1, 2]);
  assert.equal(w.version("nightly"), undefined);
  assert.equal(w.newer("v0.42.0", "v0.9.0"), true);
  assert.equal(w.newer("v0.9.0", "v0.42.0"), false);
  assert.equal(w.newer("v1.0.0", "nightly"), true);
  assert.equal(w.newer("nightly", "v1.0.0"), false);
  assert.equal(w.newer("v1.0.0", "v1.0.0"), false);
});

test("a release's row is named by its tag and says when it was released", () => {
  const row = release("v0.42.0");
  assert.equal(row.title, "v0.42.0");
  const line = w.rowLine(row, Date.parse("2026-11-10T12:00:00Z"));
  assert.equal(line.wide, "released 2 hours ago");
  assert.equal(line.short, "2 h");
});

test("releases sort by version, the highest first, and open on Newest with no Last updated", () => {
  const rows = [release("v0.9.0"), release("v0.42.0"), release("v0.10.0")];
  assert.deepEqual(w.sortRows(rows, "newest").map((x) => x.title), ["v0.42.0", "v0.10.0", "v0.9.0"]);
  assert.equal(w.defaultSort("release"), "newest");
  assert.deepEqual(w.workSorts("release"), ["newest", "cost"]);
  assert.equal(w.defaultSort("issue"), "updated");
  assert.equal(w.workQuery(w.anyFilter, "newest", "release"), "");
  assert.equal(w.workQuery(w.anyFilter, "newest", "issue"), "sort=newest");
  assert.equal(w.parseWorkQuery("", "release").sort, "newest");
  assert.equal(w.parseWorkQuery("sort=updated", "release").sort, "newest");
});

test("an empty releases list", () => {
  assert.deepEqual(w.emptyWords("release", "open", false, []), { title: "No releases yet" });
  assert.deepEqual(w.emptyWords("release", "open", true, []), { title: "No releases match" });
});

test("the latest release of each repo, and the release before one", () => {
  const rows = [release("v0.41.0"), release("v0.42.0"), release("v0.40.0"), release("v2.0.0", "example/shop"), release("nightly")];
  assert.deepEqual([...r.latest(rows)].sort(), [ref("v0.42.0"), ref("v2.0.0", "example/shop")]);
  assert.equal(r.previous(ref("v0.42.0"), rows)?.title, "v0.41.0");
  assert.equal(r.previous(ref("v0.40.0"), rows), undefined);
  assert.equal(r.previous(ref("nightly"), rows), undefined);
});

test("the state line, the range and the compare page", () => {
  const now = new Date("2026-11-10T12:00:00Z");
  const released = new Date("2026-11-10T10:00:00Z");
  assert.equal(r.stateWords(released, 23, false, now), "released 2 hours ago · 23 pull requests");
  assert.equal(r.stateWords(released, 1, true, now), "2 h · 1 pull request");
  assert.equal(r.stateWords(undefined, undefined, false, now), "");
  assert.equal(r.rangeWords("v0.41.0", "v0.42.0"), "v0.41.0…v0.42.0");
  assert.equal(r.compareUrl(ref("v0.42.0"), "v0.41.0"), "https://github.com/alexec/Agents/compare/v0.41.0...v0.42.0");
  assert.equal(r.compareUrl("gitlab:acme/web/release/v1.0.0", "v0.9.0"), undefined);
  assert.equal(r.notesElsewhere(ref("v0.42.0")), "The release notes are on GitHub.");
});

test("its pull requests and its pipeline, from lineage", () => {
  const node = { kind: "release", ref: ref("v0.42.0") };
  const pr = (n) => ({ kind: "pr", ref: `github:alexec/Agents#${n}` });
  const link = (from, to, rel) => ({ from, to, rel, source: "forge", at: at("2026-11-10T09:00:00Z") });
  const g = {
    nodes: [],
    links: [
      link(pr(4), node, "part-of"), link(pr(12), node, "part-of"), link(pr(4), node, "part-of"),
      link(pr(9), { kind: "release", ref: ref("v0.41.0") }, "part-of"),
      link({ kind: "ci-run", ref: "github:alexec/Agents/actions/run/77" }, node, "builds"),
      link(node, { kind: "deploy", ref: "testflight:loops/42" }, "deployed-as"),
    ],
    resolved: { [pr(12).ref]: { title: "Releases on the web page", state: "merged", labels: ["enhancement"] } },
  };
  const pulls = r.pullRequests(node, g);
  assert.deepEqual(pulls.map((p) => p.title), ["Releases on the web page", "#4"]);
  assert.deepEqual(pulls[0].labels, [{ name: "enhancement" }]);
  assert.equal(pulls[1].state, "merged");
  assert.deepEqual(r.pipeline(node, g), [
    { words: "CI run", url: "https://github.com/alexec/Agents/actions/runs/77" },
    { words: "TestFlight 42", url: "https://appstoreconnect.apple.com/apps" },
  ]);
  assert.deepEqual(r.pipeline(node, { nodes: [], links: [] }), []);
});

test("lineage's figures on the panel", () => {
  const f = { node: { kind: "release", ref: ref("v0.42.0") }, cost: cost(18.4), sessions: 3, running: 1,
    runtimes: [{ runtimeID: "claude", sessions: 2 }, { runtimeID: "codex", sessions: 1 }], leadTimeSeconds: 7800 };
  assert.equal(r.figuresWords(f), "$18.40 · 3 sessions, 1 running · lead time 2h 10m");
  assert.equal(r.runtimesWords(f, (id) => id === "claude" ? "Claude" : "Codex"), "Claude 2 · Codex 1");
  assert.equal(r.figuresWords({ ...f, cost: cost(0), sessions: 0, running: 0, leadTimeSeconds: undefined }), undefined);
});
