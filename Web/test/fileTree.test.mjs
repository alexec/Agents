// Files as a tree (#133), held to the window's FilesPane.treeLines and FileTree rules.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const t = await load("src/model/fileTree.ts");
const entry = (folder, name, isDirectory = false) => ({ url: `file:///private${folder}/${name}${isDirectory ? "/" : ""}`, name, isDirectory });
const listing = (folder, ...entries) => [folder, t.sorted({ url: `file://${folder}`, entries, omitted: 0 })];
const tree = new Map([
  listing("/w", entry("/w", "b.txt"), entry("/w", "Sources", true), entry("/w", "a.txt"), entry("/w", "Docs", true)),
  listing("/w/Sources", entry("/w/Sources", "App", true), entry("/w/Sources", "main.swift")),
  listing("/w/Sources/App", entry("/w/Sources/App", "deep.swift")),
]);
const shape = (lines) => lines.map((l) => (l.kind === "entry" ? `${"  ".repeat(l.depth)}${l.entry.name}` : `${"  ".repeat(l.depth)}(${l.words})`));

test("folders first, each open folder's entries one step in, keyed in the top's spelling", () => {
  const lines = t.flatten("/w", tree, new Set(["/w/Sources", "/w/Sources/App"]));
  assert.deepEqual(shape(lines), ["Docs", "Sources", "  App", "    deep.swift", "  main.swift", "a.txt", "b.txt"]);
  assert.equal(lines[3].path, "/w/Sources/App/deep.swift");
});

test("a shut folder hides what is in it and keeps what is open under it", () => {
  const expanded = new Set(["/w/Sources/App"]);
  assert.deepEqual(shape(t.flatten("/w", tree, expanded)), ["Docs", "Sources", "a.txt", "b.txt"]);
  assert.deepEqual(shape(t.flatten("/w", tree, new Set([...expanded, "/w/Sources"]))).length, 7);
});

test("an open folder not yet read says so, and is the one left to read", () => {
  const expanded = new Set(["/w/Docs"]);
  assert.deepEqual(shape(t.flatten("/w", tree, expanded)).slice(0, 2), ["Docs", "  (Reading…)"]);
  assert.deepEqual(t.unread("/w", expanded, tree, new Map(), new Set()), ["/w/Docs"]);
  assert.deepEqual(t.unread("/w", expanded, tree, new Map(), new Set(["/w/Docs"])), []);
  // A folder inside a shut one is not on screen, so it is not read.
  assert.deepEqual(t.unread("/w", new Set(["/w/Sources/App/x"]), tree, new Map(), new Set()), []);
});

test("reveal opens every folder between the top and a file's", () => {
  assert.deepEqual([...t.reveal("/w", "/w/Sources/App", new Set(["/w/Docs"]))].sort(), ["/w/Docs", "/w/Sources", "/w/Sources/App"]);
  assert.equal(t.reveal("/w", "/elsewhere", new Set()).size, 0);
});

test("the keys: up and down move, right opens then steps in, left shuts then steps out, Return opens", () => {
  const expanded = new Set(["/w/Sources"]);
  const lines = t.flatten("/w", tree, expanded);
  const key = (at, k, open = expanded) => t.keyAction(lines, at, k, open, "/w");
  assert.deepEqual(key(undefined, "ArrowDown"), { kind: "select", id: "/w/Docs" });
  assert.deepEqual(key("/w/Docs", "ArrowDown"), { kind: "select", id: "/w/Sources" });
  assert.deepEqual(key("/w/Docs", "ArrowUp"), { kind: "select", id: "/w/Docs" });
  assert.deepEqual(key("/w/Docs", "ArrowRight"), { kind: "expand", path: "/w/Docs" });
  assert.deepEqual(key("/w/Sources", "ArrowRight"), { kind: "select", id: "/w/Sources/App" });
  assert.deepEqual(key("/w/Sources", "ArrowLeft"), { kind: "collapse", path: "/w/Sources" });
  assert.deepEqual(key("/w/Sources/main.swift", "ArrowLeft"), { kind: "select", id: "/w/Sources" });
  assert.deepEqual(key("/w/a.txt", "ArrowLeft"), { kind: "none" });
  assert.equal(key("/w/a.txt", "Enter").line.path, "/w/a.txt");
  assert.deepEqual(key("/w/a.txt", "End"), { kind: "select", id: "/w/b.txt" });
});

test("only the rows in view are drawn, and a few either side", () => {
  assert.deepEqual(t.windowOf(10_000, 26, 26 * 5000, 26 * 30, 8), { start: 4992, end: 5038 });
  assert.deepEqual(t.windowOf(3, 26, 0, 600, 8), { start: 0, end: 3 });
});
