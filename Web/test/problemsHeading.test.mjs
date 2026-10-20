// No problems, a server that is starting and a failed request each say what they are (#1687).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

test("the problems list's first line", async () => {
  globalThis.window ??= { devicePixelRatio: 1 };
  globalThis.document ??= { hidden: false };
  const { problemsHeading } = await load("src/views/files/SourceEditor.tsx");
  assert.equal(problemsHeading({ diagnostics: [], server: "gopls" }), "No problems · gopls");
  assert.equal(problemsHeading({ diagnostics: [], server: "gopls", reason: "Starting gopls…" }), "Starting gopls…");
  assert.equal(problemsHeading({ diagnostics: [], server: "gopls", reason: "Couldn't ask gopls: gone" }), "Couldn't ask gopls: gone");
  const one = { line: 1, column: 1, severity: "error", message: "x" };
  assert.equal(problemsHeading({ diagnostics: [one], server: "gopls" }), "1 problem · gopls");
  assert.equal(problemsHeading({ diagnostics: [one, one], server: "gopls" }), "2 problems · gopls");
});
