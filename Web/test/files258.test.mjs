// Files on the page, as the window has them (#258): a picture only from beside the
// document, a zoom that fits first, numbered lines, one watch shared by two panes,
// and what the conversation handed over.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const {
  pageImagePath, pictureFromReading, mediaType,
  fitMagnification, clampMagnification, stepMagnification, magnificationAfterDoubleClick,
} = await load("src/model/pageImage.ts");
const { splitLines, linePastEnd, lineLabel, gutterIsWide } = await load("src/model/fileLines.ts");
const { scopeRoot, WatchCounts, openFileShouldReread, absolutePath } = await load("src/model/fileWatch.ts");
const {
  artifactsIn, destinationOf, insideScope, missingInListing, bytesInWords,
} = await load("src/model/artifacts.ts");
const { textShownAs, fileToPin } = await load("src/views/files/paneState.ts");
const { renderMarkdown } = await load("src/render/markdown.ts");

const doc = "/docs/page.md";

test("a picture beside the document is the file there", () => {
  assert.equal(pageImagePath("cat.png", doc), "/docs/cat.png");
  assert.equal(pageImagePath("./cat.png", doc), "/docs/cat.png");
  assert.equal(pageImagePath("images/cat.png", doc), "/docs/images/cat.png");
  assert.equal(pageImagePath("  cat.PNG  ", doc), "/docs/cat.PNG");
  assert.equal(pageImagePath("file:///docs/cat.png", doc), "/docs/cat.png");
  assert.equal(pageImagePath("file://localhost/docs/cat.png", doc), "/docs/cat.png");
  assert.equal(pageImagePath("../sub/cat.png", "/docs/sub/page.md"), "/docs/sub/cat.png");
});

test("a picture from anywhere else stays unresolved", () => {
  assert.equal(pageImagePath("https://example.com/cat.png", doc), null);
  assert.equal(pageImagePath("http://example.com/cat.png", doc), null);
  assert.equal(pageImagePath("javascript:alert(1)", doc), null);
  assert.equal(pageImagePath("data:image/png,xx", doc), null);
  assert.equal(pageImagePath("file:///etc/passwd.png", doc), null);
  assert.equal(pageImagePath("/etc/passwd.png", doc), null);
  assert.equal(pageImagePath("../docs-secret/a.png", doc), null);
  assert.equal(pageImagePath("../cat.png", "/docs/sub/page.md"), null);
  assert.equal(pageImagePath("%2e%2e/secret.png", doc), null);
  assert.equal(pageImagePath("notes.txt", doc), null);
  assert.equal(pageImagePath("cat.png?x=1", doc), null);
  assert.equal(pageImagePath("cat.png#x", doc), null);
  assert.equal(pageImagePath("cat\\png.png", doc), null);
  assert.equal(pageImagePath("cat.png", "page.md"), null);
  assert.equal(pageImagePath("", doc), null);
});

test("only a picture the host handed back is drawn", () => {
  const stamp = { size: 4, modifiedAt: 0 };
  const png = pictureFromReading("/docs/cat.png", { kind: "image", stamp, bytes: "aGVsbG8=", describedAs: "cat" });
  assert.equal(png.type, "image/png");
  assert.equal(png.bytes.length, 5);
  const svg = pictureFromReading("/docs/icon.svg", { kind: "text", stamp, text: "<svg></svg>", isTruncated: false, size: 11 });
  assert.equal(svg.type, "image/svg+xml");
  assert.ok(svg.bytes.length > 0);
  assert.equal(pictureFromReading("/docs/cat.png", { kind: "text", stamp, text: "not a picture", isTruncated: false, size: 1 }), null);
  assert.equal(pictureFromReading("/docs/notes.txt", { kind: "image", stamp, bytes: "aGVsbG8=", describedAs: "text" }), null);
  assert.equal(mediaType("/docs/photo.JPEG"), "image/jpeg");
  assert.equal(mediaType("/docs/notes.txt"), null);
});

test("zoom fits the whole picture and never blows a small one up", () => {
  assert.equal(fitMagnification(100, 100, 200, 200), 1);
  assert.equal(fitMagnification(400, 200, 200, 200), 0.5);
  assert.equal(fitMagnification(0, 10, 10, 10), 1);
  assert.equal(clampMagnification(10, 0.5), 8);
  assert.equal(clampMagnification(0.1, 0.5), 0.5);
  assert.equal(stepMagnification(1, 0.5, 1), 1.5);
  assert.equal(stepMagnification(1.5, 0.5, -1), 1);
  assert.equal(magnificationAfterDoubleClick(0.5, 0.5), 1);
  assert.equal(magnificationAfterDoubleClick(1, 1), 2);
  assert.equal(magnificationAfterDoubleClick(4, 0.5), 0.5);
});

test("lines are numbered, and a line past the end is said", () => {
  assert.deepEqual(splitLines("a\nb\n"), ["a", "b", ""]);
  assert.equal(linePastEnd(5, 3), "Line 5 is past what is shown here.");
  assert.equal(linePastEnd(3, 3), null);
  assert.equal(linePastEnd(undefined, 3), null);
  assert.equal(lineLabel(12, "hi"), "Line 12: hi");
  assert.equal(lineLabel(12, "  "), "Line 12, blank");
  assert.equal(gutterIsWide(999), false);
  assert.equal(gutterIsWide(1000), true);
});

test("two panes share one watch, and the first to leave does not stop it", () => {
  assert.equal(scopeRoot("/proj", [], "/proj/src/a"), "/proj");
  assert.equal(scopeRoot("/proj", ["/other"], "/other/a"), "/other");
  assert.equal(scopeRoot("/proj", ["/proj/vendor"], "/proj/vendor/a"), "/proj/vendor");
  assert.equal(scopeRoot("/", [], "/tmp/a"), "/");
  assert.equal(scopeRoot("/proj", [], "/elsewhere/a"), "/elsewhere/a");
  assert.equal(scopeRoot("file:///proj", [], "/proj/a"), "/proj");
  assert.equal(scopeRoot("/proj/", [], "/proj"), "/proj");
  assert.equal(absolutePath("file:///proj/"), "/proj");

  const watches = new WatchCounts();
  assert.equal(watches.watch("root"), true);
  assert.equal(watches.watch("root"), false);
  assert.equal(watches.unwatch("root"), false);
  assert.equal(watches.unwatch("root"), true);
  assert.equal(watches.unwatch("root"), false);
  assert.equal(openFileShouldReread(null, "a"), false);
  assert.equal(openFileShouldReread({ agentID: "b" }, "a"), false);
  assert.equal(openFileShouldReread({ agentID: "a" }, "a"), true);
});

test("markdown and html open as a page or its source, and either can be pinned from Files", () => {
  assert.equal(textShownAs("/w/notes.mdown"), "page");
  assert.equal(textShownAs("/w/notes.mkd"), "page");
  assert.equal(textShownAs("/w/notes.markdown"), "page");
  assert.equal(textShownAs("/w/page.html"), "source");
  assert.equal(fileToPin({ tab: "files", file: "/w/page.html" }), "/w/page.html");
  assert.equal(fileToPin({ tab: "page", page: "/w/notes.md" }), "/w/notes.md");
  assert.equal(fileToPin({ tab: "exchanged", file: "/w/page.html" }), undefined);
  assert.equal(fileToPin({ tab: "files" }), undefined);
});

function message(id, blocks, at = 1000) {
  return { id, at, kind: { agentMessage: { text: "", blocks } } };
}

function prompt(id, blocks, at = 1000) {
  return { id, at, kind: { userMessage: { _0: "", blocks } } };
}

const link = { type: "resource_link", uri: "file:///tmp/report.md", name: "report.md", mimeType: "text/markdown", size: 400 };

test("what was exchanged is the two blocks that hand something over, newest first", () => {
  const attached = artifactsIn([prompt("u", [{ type: "text", text: "have a look" }, link])]);
  assert.equal(attached[0].id, "u:1");
  assert.equal(attached.length, 1);
  assert.equal(attached[0].name, "report.md");
  assert.equal(attached[0].entryID, "u");

  const one = artifactsIn([message("m", [link])]);
  assert.equal(one[0].mimeType, "text/markdown");
  assert.equal(one[0].size, 400);
  assert.deepEqual(destinationOf(one[0]), { kind: "file", path: "/tmp/report.md" });

  const embedded = artifactsIn([message("e", [{
    type: "resource", resource: { uri: "file:///tmp/notes.txt", text: "hello", mimeType: "text/plain" },
  }])]);
  assert.equal(embedded[0].embedded, true);
  assert.equal(embedded[0].text, "hello");
  assert.equal(embedded[0].name, "notes.txt");
  assert.equal(embedded[0].size, 5);
  assert.deepEqual(destinationOf(embedded[0]), { kind: "inPlace" });

  const blob = artifactsIn([message("b", [{
    type: "resource", resource: { uri: "file:///tmp/pic.png", blob: "aGVsbG8=" },
  }])]);
  assert.equal(blob[0].size, 5);
  assert.deepEqual(destinationOf(blob[0]), { kind: "file", path: "/tmp/pic.png" });
  const carried = artifactsIn([message("bt", [{
    type: "resource", resource: { uri: "file:///tmp/pic.png", blob: "aGVsbG8=", text: "no" },
  }])]);
  assert.equal(carried[0].size, 5);
  assert.deepEqual(destinationOf(carried[0]), { kind: "inPlace" });

  assert.equal(artifactsIn([
    message("t", []),
    { id: "thought", at: 1, kind: { agentThought: { text: "thinking" } } },
    { id: "call", at: 1, kind: { toolCall: { _0: { title: "Edit" } } } },
    message("pic", [
      { type: "image", mimeType: "image/png", data: "qq==" },
      { type: "audio", mimeType: "audio/wav", data: "qq==" },
      { type: "text", text: "here is your report" },
    ]),
  ]).length, 0);

  const ordered = artifactsIn([
    message("old", [{ type: "resource_link", uri: "file:///tmp/old.md", name: "old.md" }], 1000),
    message("new", [{ type: "resource_link", uri: "file:///tmp/new.md", name: "new.md" }], 2000),
  ]);
  assert.deepEqual(ordered.map((item) => item.name), ["new.md", "old.md"]);

  const tied = artifactsIn([
    message("a", [{ type: "resource_link", uri: "file:///tmp/a.md", name: "a.md" }], 5),
    message("b", [{ type: "resource_link", uri: "file:///tmp/b.md", name: "b.md" }], 5),
  ]);
  assert.deepEqual(tied.map((item) => item.name), ["a.md", "b.md"]);

  const both = message("both", [
    { type: "text", text: "see" },
    link,
    { type: "resource_link", uri: "file:///tmp/second.md", name: "second.md" },
  ]);
  const pair = artifactsIn([both]);
  assert.deepEqual(pair.map((item) => item.id), ["both:1", "both:2"]);

  assert.equal(artifactsIn([message("hide", [{ ...link, annotations: { audience: ["assistant"] } }])]).length, 0);
  assert.equal(artifactsIn([message("hide", [{ ...link, annotations: { audience: [] } }])]).length, 0);
  assert.equal(artifactsIn([message("keep", [{ ...link, annotations: { audience: ["user", "assistant"] } }])]).length, 1);
  assert.equal(artifactsIn([message("plain", [link])]).length, 1);

  const page = artifactsIn([message("web", [{ type: "resource_link", uri: "https://example.com/report", name: "report" }])]);
  assert.deepEqual(destinationOf(page[0]), { kind: "web", href: "https://example.com/report" });
  const odd = artifactsIn([message("odd", [{ type: "resource_link", uri: "gopher://example.com/x", name: "x" }])]);
  assert.deepEqual(destinationOf(odd[0]), { kind: "nowhere" });
  const summed = artifactsIn([{
    id: "sum", at: 3, kind: { compaction: { status: "completed", summary: [link] } },
  }]);
  assert.equal(summed[0].name, "report.md");
});

test("a file is inside the agent's folders, or it is not, and a cut-short listing does not call it gone", () => {
  assert.equal(insideScope("/proj/a.md", ["/proj"]), true);
  assert.equal(insideScope("/proj", ["/proj"]), true);
  assert.equal(insideScope("/proj-secret/a.md", ["/proj"]), false);
  assert.equal(insideScope("/project/a.md", ["/proj"]), false);
  assert.equal(insideScope("/tmp/a", ["/"]), true);
  assert.equal(insideScope("/proj/a.md", ["/proj/"]), true);
  assert.equal(insideScope("/tmp/a", []), false);

  assert.equal(missingInListing(null, "a.md"), false);
  assert.equal(missingInListing({ entries: [], omitted: 2 }, "a.md"), false);
  assert.equal(missingInListing({ entries: [{ name: "b.md" }], omitted: 0 }, "a.md"), true);
  assert.equal(missingInListing({ entries: [{ name: "a.md" }], omitted: 0 }, "a.md"), false);
  assert.equal(bytesInWords(0), "0 bytes");
  assert.equal(bytesInWords(1), "1 byte");
  assert.equal(bytesInWords(1500), "1.5 KB");
  assert.equal(bytesInWords(1_000_000), "1 MB");
  assert.equal(bytesInWords(-1), "");
});

function find(node, pred, found = []) {
  if (node == null || typeof node !== "object") return found;
  if (Array.isArray(node)) {
    for (const child of node) find(child, pred, found);
    return found;
  }
  if (pred(node)) found.push(node);
  if (node.props?.children !== undefined) find(node.props.children, pred, found);
  return found;
}

const page = (document) => ({ document, revision: 1, read: async () => null });

test("a chat draws no picture, and a page draws one only from beside itself", () => {
  const chat = renderMarkdown("![cat](cat.png)");
  assert.equal(find(chat, (node) => node.type?.name === "LocalPicture").length, 0);
  assert.equal(find(chat, (node) => node.props?.class === "image-placeholder").length, 1);

  const beside = renderMarkdown("![cat](cat.png)", page(doc));
  const pictures = find(beside, (node) => node.type?.name === "LocalPicture");
  assert.equal(pictures.length, 1);
  assert.equal(pictures[0].props.path, "/docs/cat.png");
  assert.equal(pictures[0].props.alt, "cat");

  const remote = renderMarkdown("![a cat](https://example.com/cat.png)", page(doc));
  assert.equal(find(remote, (node) => node.type?.name === "LocalPicture").length, 0);
  const held = find(remote, (node) => node.props?.class === "image-placeholder");
  assert.equal(held.length, 1);
  assert.equal(held[0].props.title, "https://example.com/cat.png");

  const climbed = renderMarkdown("![x](../secret.png)", page(doc));
  assert.equal(find(climbed, (node) => node.type?.name === "LocalPicture").length, 0);
});
