// A tool's argument and return as they read (#3569): text as it came, the rest as YAML.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { readable } = await load("src/render/structured.ts");

test("an object reads as YAML, keys sorted, with no braces or trailing line", () => {
  const { text, structured } = readable({ until_minutes: 60, events: ["pr.merged", "checks.failed"], where: { pr: 3569 } });
  assert.equal(structured, true);
  assert.equal(text, "events:\n- pr.merged\n- checks.failed\nuntil_minutes: 60\nwhere:\n  pr: 3569");
});

test("text that YAML would read as something else stays quoted", () => {
  const { text } = readable({ a: "true", b: "12", c: "", d: null });
  assert.equal(text, 'a: "true"\nb: "12"\nc: ""\nd: null');
});

test("text of several lines is a block", () => {
  const { text } = readable([{ type: "text", text: "pr.merged at 10:02\nYou can carry on.\n" }]);
  assert.equal(text, "- text: |\n    pr.merged at 10:02\n    You can carry on.\n  type: text");
});

test("text and a list of bytes stay as text", () => {
  assert.deepEqual(readable("a: b"), { text: "a: b", structured: false });
  assert.deepEqual(readable([104, 105]), { text: "hi", structured: false });
});

test("YAML is coloured by key and value, and a block's lines are text", async () => {
  const { highlightCode } = await load("src/render/codeHighlight.ts");
  const kinds = (yaml) => highlightCode(yaml, "yaml").filter((n) => typeof n === "object").map((n) => `${n.props.class}=${n.props.children}`);
  assert.deepEqual(kinds("title: Scratch change\npr: 42\nmerged: true\nevents:\n- pr.merged\nmessage: |-\n  You can carry on.\nnext: x"), [
    "code-punctuation=:", "code-string=Scratch change", "code-punctuation=:", "code-number=42", "code-punctuation=:", "code-keyword=true",
    "code-punctuation=:", "code-punctuation=- ", "code-string=pr.merged", "code-punctuation=:", "code-operator=|-",
    "code-string=  You can carry on.", "code-punctuation=:", "code-string=x",
  ]);
  const text = highlightCode("a:\n- b: 1\n  c: '2'", "yaml").map((n) => typeof n === "object" ? n.props.children : n).join("");
  assert.equal(text, "a:\n- b: 1\n  c: '2'");
});
