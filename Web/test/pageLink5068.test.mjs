// A relative link on a Markdown page opens the file it names (#5068), as on the Mac and the Remote (#5067).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { pageLinkTarget, pathInFolder, isPageFile } = await load("src/model/pageLink.ts");
const { renderMarkdown } = await load("src/render/markdown.ts");

/** The first node of `type` among the nodes, at any depth. */
function find(nodes, type) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node || typeof node !== "object") continue;
    if (node.type === type) return node;
    const inner = find(node.props?.children, type);
    if (inner) return inner;
  }
  return undefined;
}

test("a relative link is read against the page's own file", () => {
  const page = "/Users/a/p/docs/plan.md";
  assert.deepEqual(pageLinkTarget("other.md", page), { kind: "file", path: "/Users/a/p/docs/other.md" });
  assert.deepEqual(pageLinkTarget("./other.md", page), { kind: "file", path: "/Users/a/p/docs/other.md" });
  assert.deepEqual(pageLinkTarget("../README.md", page), { kind: "file", path: "/Users/a/p/README.md" });
  assert.deepEqual(pageLinkTarget("sub/a%20b.md#part", page), { kind: "file", path: "/Users/a/p/docs/sub/a b.md" });
  assert.deepEqual(pageLinkTarget("a.md?x=1", page), { kind: "file", path: "/Users/a/p/docs/a.md" });
});

test("a page in a folder gets a path in the same folder, and never one above it", () => {
  assert.deepEqual(pageLinkTarget("../README.md", "docs/plan.md"), { kind: "file", path: "README.md" });
  assert.deepEqual(pageLinkTarget("other.md", "plan.md"), { kind: "file", path: "other.md" });
  assert.equal(pageLinkTarget("../../x.md", "docs/plan.md"), null);
  assert.equal(pageLinkTarget("../../../../../x.md", "/a/plan.md"), null);
});

test("a fragment stays on the page, and a link with a scheme or a full path is not relative", () => {
  assert.deepEqual(pageLinkTarget("#usage", "/a/plan.md"), { kind: "samePage" });
  for (const href of ["https://example.com/a.md", "mailto:a@b.c", "file:///a/b.md", "/a/b.md", "//elsewhere/a.md", "javascript:alert(1)", "", "a\\b.md"]) {
    assert.equal(pageLinkTarget(href, "/a/plan.md"), null, href);
  }
});

test("a path in a folder, and the files a pinned page opens in its place", () => {
  assert.equal(pathInFolder("/Users/a/p/docs/a.md", "/Users/a/p"), "docs/a.md");
  assert.equal(pathInFolder("/Users/a/p/docs/a.md", "/Users/a/p/"), "docs/a.md");
  assert.equal(pathInFolder("/Users/a/other/a.md", "/Users/a/p"), null);
  assert.equal(pathInFolder("/Users/a/pp/a.md", "/Users/a/p"), null);
  assert.equal(pathInFolder("docs/a.md", "/Users/a/p"), "docs/a.md");
  assert.equal(isPageFile("docs/a.md"), true);
  assert.equal(isPageFile("index.HTML"), true);
  assert.equal(isPageFile("main.go"), false);
});

test("on a page, a relative link is a button that opens the file, and does not start editing the passage", () => {
  const opened = [];
  const links = { document: "/Users/a/p/docs/plan.md", open: (path) => opened.push(path) };
  const button = find(renderMarkdown("See [the other](other.md).", undefined, undefined, undefined, links), "button");
  assert.ok(button, "a link to a file beside the page is a button");
  assert.equal(button.props.title, "/Users/a/p/docs/other.md");
  let stopped = false;
  button.props.onClick({ stopPropagation: () => { stopped = true; } });
  assert.deepEqual(opened, ["/Users/a/p/docs/other.md"]);
  assert.equal(stopped, true, "the passage under the link does not open for editing");
});

test("a full path on a page opens too, and a file the page does not take stays words", () => {
  const opened = [];
  const links = { document: "docs/plan.md", open: (path) => opened.push(path), takes: (path) => path.endsWith(".md") };
  assert.ok(find(renderMarkdown("[x](/Users/a/p/x.md)", undefined, undefined, undefined, links), "button"));
  assert.equal(find(renderMarkdown("[x](main.go)", undefined, undefined, undefined, links), "button"), undefined);
  assert.ok(find(renderMarkdown("[x](main.go)", undefined, undefined, undefined, links), "span"));
});

test("a fragment, and any relative link off a page, stays words", () => {
  const links = { document: "/a/plan.md", open: () => assert.fail("nothing opens") };
  assert.equal(find(renderMarkdown("[up](#usage)", undefined, undefined, undefined, links), "button"), undefined);
  assert.equal(find(renderMarkdown("[x](other.md)"), "button"), undefined);
  assert.equal(find(renderMarkdown("[x](other.md)", undefined, () => assert.fail("a chat has no page")), "button"), undefined);
  const web = find(renderMarkdown("[x](https://example.com)", undefined, undefined, undefined, links), "a");
  assert.equal(web.props.href, "https://example.com");
});
