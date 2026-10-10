// What an agent writes is drawn, never run (FR-031, research R9).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { renderMarkdown, isSafeLink } = await load("src/render/markdown.ts");

/** The nodes as HTML-ish text, escaped, so a test can read what would be drawn. */
function show(nodes) {
  return [nodes].flat(Infinity).map((node) => {
    if (node === null || node === undefined || node === false) return "";
    if (typeof node === "string" || typeof node === "number") {
      return String(node).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    const { children, ...props } = node.props;
    const attrs = Object.entries(props).map(([k, v]) => ` ${k}="${v}"`).join("");
    return `<${node.type}${attrs}>${show(children ?? [])}</${node.type}>`;
  }).join("");
}

const md = (text) => show(renderMarkdown(text));

test("a script tag is text", () => {
  const out = md("Hello <script>alert(1)</script>");
  assert.match(out, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.doesNotMatch(out, /<script/);
});

test("raw HTML blocks are text", () => {
  const out = md('<div onclick="x()">hi</div>\n\n<img src=x onerror=alert(1)>');
  assert.doesNotMatch(out, /<div onclick|<img/);
  assert.match(out, /&lt;div onclick=/);
});

test("a remote image is a placeholder, not a request", () => {
  const out = md("![a cat](https://example.com/cat.png)");
  assert.equal(out, '<p><span class="image-placeholder" title="https://example.com/cat.png">[image: a cat]</span></p>');
});

test("a javascript: link is not a link", () => {
  const out = md("[click](javascript:alert(1)) and <javascript:alert(1)>");
  assert.doesNotMatch(out, /<a /);
  assert.doesNotMatch(out, /href="javascript/);
});

test("a data: or file: link is not a link", () => {
  assert.doesNotMatch(md("[d](data:text/html,hi) [f](file:///etc/passwd)"), /<a /);
});

test("an https link opens in a new tab without the opener", () => {
  assert.equal(md("[docs](https://example.com/a)"),
    '<p><a href="https://example.com/a" target="_blank" rel="noopener noreferrer">docs</a></p>');
  assert.match(md("see https://example.com"), /<a href="https:\/\/example.com" target="_blank"/);
});

test("the usual Markdown is drawn", () => {
  assert.equal(md("# Title\n\n- **one**\n- `two`\n\n```swift\nlet x = 1 < 2\n```"),
    "<h1>Title</h1><ul><li><strong>one</strong></li><li><code>two</code></li></ul>"
    + '<pre data-language="swift"><code><span class="code-keyword">let</span> x <span class="code-operator">=</span> <span class="code-number">1</span> <span class="code-operator">&lt;</span> <span class="code-number">2</span>\n</code></pre>');
  assert.equal(md("3. three\n4. four"), '<ol start="3"><li>three</li><li>four</li></ol>');
  assert.equal(md("1. one\n2. two"), "<ol><li>one</li><li>two</li></ol>");
});

test("known fenced code is coloured as inert token spans; unknown fences stay plain", () => {
  const code = md('```swift\nlet answer = "yes" // ready\n```');
  assert.match(code, /class="code-keyword">let<\/span>/);
  assert.match(code, /class="code-string">"yes"<\/span>/);
  assert.match(code, /class="code-comment">\/\/ ready<\/span>/);
  assert.equal(md("```mystery\nlet answer\n```"), '<pre data-language="mystery"><code>let answer\n</code></pre>');
});

test("only http, https and mailto are safe", () => {
  assert.ok(isSafeLink("https://a.b") && isSafeLink("http://a.b") && isSafeLink("mailto:a@b.c"));
  assert.ok(!isSafeLink("javascript:x") && !isSafeLink("vbscript:x") && !isSafeLink("/relative") && !isSafeLink("data:x"));
});

const { textShownAs } = await load("src/views/files/paneState.ts");

test("an HTML file is its source, an SVG only a picture (FR-031)", () => {
  assert.equal(textShownAs("/w/page.html"), "source");
  assert.equal(textShownAs("/w/PAGE.HTM"), "source");
  assert.equal(textShownAs("/w/a.xhtml"), "source");
  assert.equal(textShownAs("/w/picture.svg"), "picture");
  assert.equal(textShownAs("/w/Picture.SVG"), "picture");
  assert.equal(textShownAs("/w/plan.md"), "page");
  assert.equal(textShownAs("/w/notes.txt"), "text");
  assert.equal(textShownAs("/w/.html"), "text");
});

test("a task list draws a box, ticked or not, and never a control (#252)", () => {
  assert.equal(md("- [ ] write it\n- [x] test it\n- plain"),
    '<ul><li class="task"><span class="task-box" role="img" aria-label="Not done">☐</span> write it</li>'
    + '<li class="task"><span class="task-box done" role="img" aria-label="Done">☑</span> test it</li><li>plain</li></ul>');
  assert.doesNotMatch(md("- [x] done"), /<input/);
  assert.equal(md("[ ] not in a list"), "<p>[ ] not in a list</p>");
});

test("Markdown in blocks draws as it does whole, at every length a reply grows through (#214)", async () => {
  const { markdownBlocks } = await load("src/render/markdown.ts");
  const texts = [
    "# Title\n\nA paragraph\nrunning on.\n\n- one\n- two\n\n  more of two\n\n- three\n\nAfter the list.\n\n1. a\n\n2. b\n\nText\n\n> quoted\n\n> again\n\nlazy\n\n    indented code\n\n    still code\n\nEnd.",
    "Before\n\n```js\nconst a = 1;\n\nconst b = 2;\n```\n\nAfter\n\n~~~\nx\n\n~~~~\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\nSetext\n===\n\nlast",
    "See [the docs][d].\n\nMore.\n\n[d]: https://example.com",
  ];
  for (const text of texts) {
    for (let at = 1; at <= text.length; at++) {
      const prefix = text.slice(0, at);
      const blocks = markdownBlocks(prefix);
      assert.equal(blocks.join(""), prefix);
      assert.equal(show(blocks.map((block) => renderMarkdown(block))), md(prefix), `at ${at}: ${JSON.stringify(prefix)}`);
    }
  }
  const long = Array.from({ length: 50 }, (_, i) => `Paragraph ${i}.`).join("\n\n");
  assert.equal(markdownBlocks(long).length, 50, "a reply of paragraphs is a block each");
  assert.equal(markdownBlocks(long + " more").slice(0, 49).join(""), markdownBlocks(long).slice(0, 49).join(""), "the finished ones stay");
});

test("a file: link opens the file where the page says how, and nowhere else (#548)", () => {
  const opened = [];
  const nodes = renderMarkdown("see [Main](file:///Users/a/My%20App/main.swift) and [x](file://elsewhere/etc/passwd)",
    undefined, (location) => opened.push(location.path));
  const out = show(nodes);
  assert.match(out, /<button type="button" class="link reading" title="\/Users\/a\/My App\/main.swift" onClick="[^"]*">Main<\/button>/);
  assert.doesNotMatch(out, /href="file:/);
  assert.doesNotMatch(out, /title="\/etc/);
  const button = nodes[0].props.children.find((child) => child?.type === "button");
  button.props.onClick();
  assert.deepEqual(opened, ["/Users/a/My App/main.swift"]);
});
