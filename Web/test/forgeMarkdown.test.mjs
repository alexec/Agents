// An issue's words are drawn as the forge draws them: its comments hidden, its few HTML tags as
// Markdown, its line breaks kept, and its title's code spans as code. ForgeMarkdownTests.swift
// holds the same cases for the Mac window and the Remote.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { forgeMarkdown, titleParts } = await load("src/model/forgeMarkdown.ts");

test("an HTML comment is hidden, also when it runs over lines", () => {
  assert.equal(forgeMarkdown("<!-- agent -->\nFixed in #12."), "Fixed in #12.");
  assert.equal(forgeMarkdown("One <!-- note --> two"), "One  two");
  assert.equal(forgeMarkdown("Before\n\n<!--\nhidden\n-->\n\nAfter"), "Before\n\n\nAfter");
});

test("a comment in code is code", () => {
  assert.equal(forgeMarkdown("Start with `<!-- agent -->`."), "Start with `<!-- agent -->`.");
  assert.equal(forgeMarkdown("```html\n<!-- kept -->\n<br>\n```"), "```html\n<!-- kept -->\n<br>\n```");
});

test("details and summary are a bold line and what follows", () => {
  assert.equal(forgeMarkdown("<details>\n<summary>Logs</summary>\n\nline\n</details>"), "**Logs**\n\nline");
  assert.equal(forgeMarkdown("<details open><summary>Logs</summary>"), "**Logs**");
});

test("br is a hard break, and a space in a table row", () => {
  assert.equal(forgeMarkdown("one<br>two"), "one  \ntwo");
  assert.equal(forgeMarkdown("| a<br/>b | c |"), "| a b | c |");
});

test("img and a are Markdown images and links", () => {
  assert.equal(forgeMarkdown('<img width="300" alt="Mac [list]" src="https://x.test/a.png" />'), "![Mac \\[list\\]](<https://x.test/a.png>)");
  assert.equal(forgeMarkdown("<a href='https://x.test'>site</a>"), "[site](<https://x.test>)");
  assert.equal(forgeMarkdown("<img alt=none>"), "");
});

test("inline marks are Markdown marks", () => {
  assert.equal(forgeMarkdown("<b>Note:</b> <i>this</i> <code>x</code> <kbd>⌘K</kbd> <del>old</del>"), "**Note:** *this* `x` `⌘K` ~~old~~");
  assert.equal(forgeMarkdown('<p align="center">centred</p>'), "centred");
  assert.equal(forgeMarkdown("<h3>Heading</h3>"), "### Heading");
});

test("any other tag stays as it was written", () => {
  assert.equal(forgeMarkdown("<script>alert(1)</script>"), "<script>alert(1)</script>");
});

test("a single line break in a paragraph is kept", () => {
  assert.equal(forgeMarkdown("one\ntwo\nthree"), "one  \ntwo  \nthree");
  assert.equal(forgeMarkdown("- a\n- b"), "- a\n- b");
  assert.equal(forgeMarkdown("Title\n---"), "Title\n---");
  assert.equal(forgeMarkdown("| a | b |\n|---|---|"), "| a | b |\n|---|---|");
  assert.equal(forgeMarkdown("text\n# Heading"), "text\n# Heading");
  assert.equal(forgeMarkdown("```\nx\ny\n```"), "```\nx\ny\n```");
});

test("a title's code spans are code", () => {
  assert.deepEqual(titleParts("Fix `make.sh` on `main`"), [
    { text: "Fix ", code: false }, { text: "make.sh", code: true }, { text: " on ", code: false }, { text: "main", code: true },
  ]);
  assert.deepEqual(titleParts("`` `a` ``"), [{ text: "`a`", code: true }]);
  assert.deepEqual(titleParts("No `end"), [{ text: "No `end", code: false }]);
  assert.deepEqual(titleParts("**bold** stays"), [{ text: "**bold** stays", code: false }]);
});
