// Changes as a tree (#63), held to ChangeTreeTests.swift's rules.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const t = await load("src/model/changeTree.ts");
const file = (relativePath, state = "modified", added = 1, removed = 0) => ({
  path: "/work/" + relativePath, relativePath, state, added, removed, source: "reported", editCount: 1,
  beyondReported: false, inProgress: false, outsideFolder: false,
});
const shape = (nodes) => nodes.map((n) => n.kind === "folder" ? { [n.name]: shape(n.children), totals: n.totals } : n.file.relativePath);

test("folders come first, a chain of one folder is one line, and each folder totals what is under it", () => {
  const tree = t.build([file("README.md"), file("Sources/App/main.swift", "added", 10), file("Sources/App/util.swift", "modified", 2, 3)]);
  assert.deepEqual(shape(tree), [
    { "Sources/App": ["Sources/App/main.swift", "Sources/App/util.swift"], totals: { added: 12, removed: 3, files: 2 } },
    "README.md",
  ]);
});

test("a closed folder hides what is in it", () => {
  const tree = t.build([file("a/x.txt"), file("a/y.txt"), file("b.txt")]);
  assert.equal(t.lines(tree, new Set()).length, 4);
  assert.deepEqual(t.lines(tree, new Set(["a"])).map((l) => l.depth), [0, 0]);
});

test("the Files pane's index totals every folder above a change", () => {
  const { files, folders } = t.index([file("Sources/App/main.swift", "added", 4), file("Sources/b.swift", "deleted", 0, 2)]);
  assert.equal(files.get("/work/Sources/App/main.swift").state, "added");
  assert.deepEqual(folders.get("/work/Sources"), { added: 4, removed: 2, files: 2 });
  assert.deepEqual(folders.get("/work"), { added: 4, removed: 2, files: 2 });
  // A listing's /private/tmp is the changes' /tmp.
  const tmp = t.index([{ ...file("notes.md"), path: "/tmp/w/notes.md" }]);
  assert.ok(tmp.files.has(t.canonical("/private/tmp/w/notes.md")));
  assert.equal(t.canonical("/private/tmpfile"), "/private/tmpfile");
});

test("a status is said in words, a rename with where it was", () => {
  assert.equal(t.statusPhrase(file("x", "untracked")), "untracked, not in git");
  assert.equal(t.statusPhrase({ ...file("new.txt", "renamed"), oldPath: "/work/old.txt" }), "renamed from old.txt");
});

test("Show in Changes finds an edit's file by the path Changes lists it under (#153)", () => {
  assert.ok(t.sameFile("/private/tmp/work/a.txt", "/tmp/work/a.txt"));
  assert.ok(t.sameFile("/work/a.txt", "/work/a.txt"));
  assert.ok(!t.sameFile("/work/a.txt", "/work/b.txt"));
});
