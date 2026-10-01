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
    + '<pre data-language="swift"><code>let x = 1 &lt; 2\n</code></pre>');
  assert.equal(md("3. three\n4. four"), '<ol start="3"><li>three</li><li>four</li></ol>');
  assert.equal(md("1. one\n2. two"), "<ol><li>one</li><li>two</li></ol>");
});

test("only http, https and mailto are safe", () => {
  assert.ok(isSafeLink("https://a.b") && isSafeLink("http://a.b") && isSafeLink("mailto:a@b.c"));
  assert.ok(!isSafeLink("javascript:x") && !isSafeLink("vbscript:x") && !isSafeLink("/relative") && !isSafeLink("data:x"));
});
